import AppKit
import Observation
import SwiftUI
import WebKit

/// One document owns wrapping, list layout, hit testing and the selection range.
/// There are no event monitors or independently measured selection rectangles.
struct AIChatDocumentBody: View {
  @Environment(\.aiChatMediaCorpusRoot) private var corpusRoot
  @Environment(\.openOrgFileReference) private var openFileReference
  @Environment(\.openWorkspaceWebLink) private var openWebLink
  @Environment(\.orgRoamLinkResolver) private var linkResolver
  @Environment(\.aiChatRecognizedMentions) private var recognizedMentions
  @State private var html: String?
  @State private var renderedText: String?
  @State private var height: CGFloat = 24
  let text: String
  let formatted: Bool
  private struct RenderKey: Equatable { let text: String; let sourcePath: String; let formatted: Bool }

  var body: some View {
    AIChatDocumentWebView(
      html: renderedText == text ? (html ?? AIChatDocumentHTML.plain(text)) : AIChatDocumentHTML.plain(text),
      sourcePath: sourcePath,
      corpusRoot: corpusRoot,
      linkResolver: linkResolver,
      recognizedMentions: recognizedMentions,
      height: $height,
      openFileReference: openFileReference,
      openWebLink: openWebLink
    )
    .frame(height: height)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: RenderKey(text: text, sourcePath: sourcePath, formatted: formatted)) {
      guard formatted else { html = nil; renderedText = nil; return }
      do {
        // Coalesce streaming updates. Completed messages share a bounded render cache.
        try await Task.sleep(for: .milliseconds(120))
        let result = try await AIChatDocumentRenderCache.shared.render(text, sourcePath: sourcePath)
        try Task.checkCancellation()
        html = result
        renderedText = text
      } catch is CancellationError {
      } catch {
        // Keep a fully selectable plain document if the compiler is unavailable.
        html = nil
        renderedText = text
      }
    }
  }

  private var sourcePath: String {
    (corpusRoot ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("chat-message.org").path
  }
}

actor AIChatDocumentRenderCache {
  static let shared = AIChatDocumentRenderCache()
  private struct Key: Hashable { let text: String; let sourcePath: String }
  private var cache: [Key: String] = [:]
  private var order: [Key] = []
  private var pending: [Key: Task<String, Error>] = [:]
  private var tail: Task<String, Error>?

  func render(_ text: String, sourcePath: String) async throws -> String {
    let key = Key(text: text, sourcePath: sourcePath)
    if let cached = cache[key] { return cached }
    if let task = pending[key] { return try await task.value }
    let previous = tail
    let task = Task {
      _ = try? await previous?.value
      try Task.checkCancellation()
      let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
      return try await cli.renderAppHTML(text, sourcePath: sourcePath)
    }
    pending[key] = task
    tail = task
    do {
      let html = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      pending[key] = nil
      cache[key] = html
      order.append(key)
      while order.count > 32 { cache[order.removeFirst()] = nil }
      return html
    } catch {
      pending[key] = nil
      throw error
    }
  }
}

/// Chat pages block page scripts, so the host installs the renderer's shared
/// chart interaction script itself (hover tooltips, crosshair, keyboard
/// navigation, and legend toggling) instead of duplicating it in Swift.
enum AIChatChartInteraction {
  static let scriptElementOpen = "<script id=\"org2-chart-interaction\">"
  static let installFunction = "window.__org2InstallCharts"

  /// The chart interaction script from compiler output, or `nil` when the
  /// message has no charts. App-profile output escapes message HTML, so only
  /// the renderer itself emits this element.
  static func script(inRenderedHTML html: String) -> String? {
    guard let open = html.range(of: scriptElementOpen),
          let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
    else { return nil }
    let script = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return script.contains(installFunction) ? script : nil
  }
}

/// Marks `@mention` tokens that address a configured agent so they read as
/// recognized references rather than literal text. Swift decides which tokens
/// are recognized (`AIChatDestinationRouting.recognizedMentionTokens`); the page
/// only wraps them. Mentions inside code, verbatim, links, and preformatted text
/// stay literal, matching how agent hand-offs ignore them.
enum AIChatMentionHighlight {
  static let className = "chat-mention"

  static let style = """
  .chat-mention { color:var(--org2-link, light-dark(#1d64c4,#7db4ff)); background:color-mix(in srgb, var(--org2-link, light-dark(#1d64c4,#7db4ff)) 13%, transparent); border-radius:4px; padding:0 2px; font-weight:600; }
  """

  static let script = #"""
  (() => {
    const pattern = /(^|[^A-Za-z0-9_])@([A-Za-z0-9][A-Za-z0-9_-]*)(?![A-Za-z0-9_-])/g;
    const literal = 'code, pre, kbd, samp, a, .chat-mention, .chat-code';
    window.__chatHighlightMentions = (doc, root, tokens) => {
      if (!root || !Array.isArray(tokens) || !tokens.length) return;
      const recognized = new Set(tokens.map(t => String(t).toLowerCase()));
      const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: node => node.nodeValue.includes('@') && !node.parentElement?.closest(literal)
          ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
      });
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      for (const node of nodes) {
        const text = node.nodeValue, parts = [];
        let last = 0;
        for (const match of text.matchAll(pattern)) {
          if (!recognized.has(match[2].toLowerCase())) continue;
          const start = match.index + match[1].length, end = start + match[2].length + 1;
          if (start > last) parts.push(doc.createTextNode(text.slice(last, start)));
          const span = doc.createElement('span');
          span.className = 'chat-mention';
          span.textContent = text.slice(start, end);
          parts.push(span);
          last = end;
        }
        if (!parts.length) continue;
        if (last < text.length) parts.push(doc.createTextNode(text.slice(last)));
        node.replaceWith(...parts);
      }
    };
  })();
  """#
}

enum AIChatDocumentHTML {
  static func plain(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body><main class=\"org2-document\"><div class=\"chat-plain\">\(escaped)</div></main></body></html>"
  }

  static let style = """
  :root { color-scheme: light dark; }
  html, body { margin:0!important; padding:0!important; min-height:0!important; height:auto!important; background:transparent!important; }
  body { font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; color: light-dark(#202020,#e7e7e7); overflow-wrap:anywhere; -webkit-user-select:text; }
  main.org2-document { width:100%!important; max-width:none!important; margin:0!important; padding:0!important; }
  main.org2-document > :first-child { margin-top:0; }
  main.org2-document > :last-child { margin-bottom:0; }
  .org2-document-header { display:none; }
  .chat-plain { white-space:pre-wrap; }
  \(AIChatMentionHighlight.style)
  li > p:first-child { margin-top:0; }
  li > p:last-child { margin-bottom:0; }
  pre { white-space:pre; overflow-x:auto; }
  .chat-code { position:relative; }
  .chat-code pre { padding-top:32px; }
  .chat-copy-code { position:absolute; top:5px; right:6px; font:11px -apple-system; color:inherit; background:transparent; border:0; border-radius:4px; padding:3px 6px; cursor:pointer; -webkit-user-select:none; }
  .chat-copy-code:hover { background:rgba(128,128,128,.16); }
  img { max-width:100%; height:auto; }
  /* The shared renderer sizes headings for full documents. In a 13px chat
     bubble they should only step slightly above body text. */
  main.org2-document h1 { font-size:15px; }
  main.org2-document h2 { font-size:14px; }
  main.org2-document h3, main.org2-document h4, main.org2-document h5, main.org2-document h6 { font-size:13px; }
  main.org2-document .org2-headline-summary { margin:0.7em 0 0.25em; }
  /* A heading with nothing under it has nothing to fold. */
  main.org2-document .org2-headline-empty > .org2-headline-summary { cursor:auto; }
  main.org2-document .org2-headline-empty > .org2-headline-summary::before { content:none; }
  """

  static let updateScript = #"""
  (() => {
    let pending = null;
    const selected = () => { const s = getSelection(); return s && !s.isCollapsed; };
    const measure = () => requestAnimationFrame(() => {
      const root = document.querySelector('main') || document.body;
      const height = Math.ceil(root.getBoundingClientRect().height);
      window.webkit.messageHandlers.chatHeight.postMessage(Math.max(24, height));
    });
    let mentions = [];
    window.__chatUpdate = (html, recognized) => {
      if (Array.isArray(recognized)) mentions = recognized;
      if (selected()) { pending = html; return; }
      const next = new DOMParser().parseFromString(html, 'text/html');
      const styles = next.querySelectorAll('style');
      document.querySelectorAll('style[data-chat-renderer]').forEach(s => s.remove());
      for (const style of styles) {
        const copy = document.createElement('style'); copy.dataset.chatRenderer = '1';
        copy.textContent = style.textContent; document.head.prepend(copy);
      }
      // Message HTML is compiler output. Imported scripts are deliberately not executed
      // in the chat page; live HTML previews run only inside their sandboxed frames.
      next.querySelectorAll('script, .org2-document-header').forEach(s => s.remove());
      window.__org2PrepareSandboxFrames?.(next);
      // A heading without a body would still render a fold toggle that hides
      // nothing. Replace its <details> with a static block of the same shape.
      for (const details of next.querySelectorAll('details.org2-headline')) {
        if (details.querySelector(':scope > .org2-headline-body')) continue;
        const summary = details.querySelector(':scope > summary');
        if (!summary) continue;
        const block = next.createElement('div');
        block.className = details.className + ' org2-headline-empty';
        for (const attribute of details.attributes) {
          if (attribute.name !== 'class' && attribute.name !== 'open') block.setAttribute(attribute.name, attribute.value);
        }
        const heading = next.createElement('div');
        heading.className = summary.className;
        heading.append(...summary.childNodes);
        block.append(heading, ...[...details.childNodes].filter(node => node !== summary));
        details.replaceWith(block);
      }
      for (const pre of next.querySelectorAll('pre')) {
        const wrapper=next.createElement('div'); wrapper.className='chat-code';
        pre.replaceWith(wrapper); wrapper.append(pre);
        const button=next.createElement('button'); button.className='chat-copy-code';
        button.textContent='Copy code'; button.setAttribute('aria-label','Copy code');
        button.addEventListener('click', () => {
          window.webkit.messageHandlers.chatCopyCode.postMessage(pre.textContent.replace(/\n$/, ''));
        });
        wrapper.append(button);
      }
      window.__chatHighlightMentions?.(next, next.body, mentions);
      document.body.replaceChildren(...next.body.childNodes);
      // Charts share the document renderer's interaction script (installed by the host).
      if (window.__org2InstallCharts) window.__org2InstallCharts(document);
      pending = null;
      measure();
    };
    document.addEventListener('selectionchange', () => {
      if (!selected() && pending !== null) window.__chatUpdate(pending);
    });
    new ResizeObserver(measure).observe(document.body);
    document.addEventListener('load', measure, true);
    measure();
  })();
  """#
}

struct AIChatDocumentWebView: NSViewRepresentable {
  let html: String
  let sourcePath: String
  let corpusRoot: URL?
  let linkResolver: OrgRoamLinkResolver
  var recognizedMentions: [String] = []
  @Binding var height: CGFloat
  let openFileReference: (AIChatFileReference) -> Void
  var openWebLink = OpenWorkspaceWebLinkAction()

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(context.coordinator, name: "chatHeight")
    configuration.userContentController.add(context.coordinator, name: "chatCopyCode")
    configuration.userContentController.addUserScript(WKUserScript(
      source: AIChatSandboxFrames.script + "\n" + AIChatMentionHighlight.script + "\n" + AIChatDocumentHTML.updateScript + "\n" + OrgHTMLRichCopy.installationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true
    ))
    configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
    configuration.setURLSchemeHandler(context.coordinator.frames, forURLScheme: AIChatSandboxFrames.scheme)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.underPageBackgroundColor = .clear
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("Chat message document")
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onHeight = { next in if abs(height - next) > 0.5 { height = next } }
    coordinator.openFileReference = openFileReference
    coordinator.openWebLink = openWebLink
    coordinator.linkResolver = linkResolver
    coordinator.sourcePath = sourcePath
    coordinator.corpusRoot = corpusRoot
    let mentionsChanged = coordinator.recognizedMentions != recognizedMentions
    coordinator.recognizedMentions = recognizedMentions
    coordinator.resources.configure(source: EntrySource(file: sourcePath, startLine: 1,
      endLineExclusive: 1, text: "", isSubtree: false), corpusRoot: corpusRoot)
    guard coordinator.html != html || mentionsChanged else { return }
    coordinator.html = html
    if !coordinator.loaded {
      if !coordinator.loading {
        coordinator.loading = true
        view.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; frame-src about: org2-frame:; img-src https: http: data: org2-resource:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'\"><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>",
          baseURL: URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
      }
    } else {
      coordinator.update(view)
    }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.linkTask?.cancel()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chatHeight")
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chatCopyCode")
    view.stopLoading()
  }

  class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let resources = OrgHTMLLocalResourceSchemeHandler()
    let frames = AIChatSandboxFrameSchemeHandler()
    var html: String?
    var loaded = false
    var loading = false
    var onHeight: ((CGFloat) -> Void)?
    var openFileReference: ((AIChatFileReference) -> Void)?
    var openWebLink = OpenWorkspaceWebLinkAction()
    var linkResolver = OrgRoamLinkResolver.empty
    var sourcePath = ""
    var corpusRoot: URL?
    var linkTask: Task<Void, Never>?
    var recognizedMentions: [String] = []

    var installedChartScript: String?

    func update(_ view: WKWebView) {
      guard let html else { return }
      if let chartScript = AIChatChartInteraction.script(inRenderedHTML: html), chartScript != installedChartScript {
        installedChartScript = chartScript
        view.evaluateJavaScript(chartScript)
      }
      let rewritten = OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html)
      view.callAsyncJavaScript(
        "window.__chatUpdate(html, mentions)",
        arguments: ["html": rewritten, "mentions": recognizedMentions],
        in: nil,
        in: .page
      )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      applyTheme(to: webView)
      update(webView)
    }

    private(set) var themeStylesheet = ""
    private var isObservingTheme = false

    /// Apply the active theme pair and keep the loaded page in step with it.
    @MainActor
    func applyTheme(to view: WKWebView) {
      themeStylesheet = WorkspaceThemeCenter.shared.trackedChatStylesheet()
      view.evaluateJavaScript(WorkspaceThemeDocumentStyle.replacementScript(themeStylesheet))
      observeThemeChanges(of: view)
    }

    @MainActor
    private func observeThemeChanges(of view: WKWebView) {
      guard !isObservingTheme else { return }
      isObservingTheme = true
      withObservationTracking {
        _ = WorkspaceThemeCenter.shared.trackedChatStylesheet()
      } onChange: { [weak self, weak view] in
        Task { @MainActor [weak self, weak view] in
          guard let self else { return }
          self.isObservingTheme = false
          guard let view else { return }
          if WorkspaceThemeCenter.shared.trackedChatStylesheet() != self.themeStylesheet {
            self.applyTheme(to: view)
          } else {
            self.observeThemeChanges(of: view)
          }
        }
      }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.frameInfo.isMainFrame else { return }
      if message.name == "chatCopyCode", let text = message.body as? String {
        AIChatMessageClipboard.write(text)
        return
      }
      guard let value = message.body as? Double,
        value.isFinite, value >= 0 else { return }
      onHeight?(CGFloat(value))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      guard navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url else { decisionHandler(.allow); return }
      decisionHandler(.cancel)
      if url.scheme == AIChatFileReference.deepLinkScheme, url.host == "open-link",
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
        if let resolved = linkResolver.resolve(target: target) {
          openFileReference?(resolved.fileReference)
        } else if let external = OrgHTMLDocumentLinkRouting.externalURL(for: target, linkResolver: linkResolver) {
          openWebLink(external, inNewTab: navigationAction.modifierFlags.contains(.command))
        } else {
          linkTask?.cancel()
          linkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await OrgHTMLLinkTarget.resolve(target, relativeTo: sourcePath, corpusRoot: corpusRoot)
            guard !Task.isCancelled, let resolved else { return }
            openFileReference?(AIChatFileReference(path: resolved.url.path, line: resolved.line))
          }
        }
      } else if let reference = AIChatFileReference.fromDeepLinkURL(url) {
        openFileReference?(reference)
      } else if url.isFileURL {
        openFileReference?(AIChatFileReference(path: url.path, line: nil))
      } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
        openWebLink(url, inNewTab: navigationAction.modifierFlags.contains(.command))
      }
    }
  }
}
