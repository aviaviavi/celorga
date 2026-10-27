import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatTranscriptDocumentTests: XCTestCase {
  private func entry(
    _ id: String,
    _ html: String,
    role: String = "assistant",
    preparing: Bool = false,
    attachments: [AIChatTranscriptHTML.Attachment] = [],
    failure: String? = nil,
    trace: AIChatTranscriptHTML.Trace? = nil,
    changeSummary: AIChatTranscriptHTML.ChangeSummary? = nil
  ) -> AIChatTranscriptHTML.Entry {
    .init(id: id, role: role, title: role == "user" ? "You" : "Assistant", timestamp: "Today",
      html: html, plainText: nil, preparing: preparing, contexts: [], attachments: attachments, failure: failure, queued: false, canSteer: false,
      isRoomResponse: false, copied: false, isTruncated: false,
      responseTrace: trace, changeSummary: changeSummary)
  }
  private func payload(_ entries: [AIChatTranscriptHTML.Entry], thread: String = "thread", search: String? = nil,
    generation: Int = 0, position: Double = 0, sending: Bool = false,
    live: AIChatTranscriptHTML.Live? = nil) -> AIChatTranscriptHTML.Payload {
    .init(thread: thread, entries: entries, earlier: "Show earlier messages", sending: sending,
      status: "", search: search, searchGeneration: generation, initialPosition: position, compact: false,
      live: live)
  }
  private func document(attachments: [AIChatAttachment] = []) async throws -> WKWebView {
    let resources = OrgHTMLLocalResourceSchemeHandler()
    resources.configure(
      source: EntrySource(
        file: "/tmp/chat-message.org",
        startLine: 1,
        endLineExclusive: 1,
        text: "",
        isSubtree: false
      ),
      corpusRoot: nil
    )
    resources.configureChatAttachments(attachments)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(
      resources,
      forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme
    )
    configuration.setURLSchemeHandler(AIChatSandboxFrameSchemeHandler(), forURLScheme: AIChatSandboxFrames.scheme)
    let view = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 460, height: 320),
      configuration: configuration
    )
    view.loadHTMLString(AIChatTranscriptHTML.shell, baseURL: nil)
    for _ in 0..<150 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await view.evaluateJavaScript("window.events=[]; window.webkit={messageHandlers:{transcript:{postMessage:x=>events.push(x)},chatCopyCode:{postMessage:x=>events.push({code:x})}}}; null;")
    try await view.evaluateJavaScript(AIChatSandboxFrames.script)
    try await view.evaluateJavaScript(AIChatTranscriptHTML.script)
    return view
  }
  private func update(_ view: WKWebView, _ payload: AIChatTranscriptHTML.Payload) async throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
    view.callAsyncJavaScript("window.__transcriptUpdate(data)", arguments: ["data": object], in: nil, in: .page)
    try await Task.sleep(for: .milliseconds(80))
  }

  private func pinkPixelCount(_ view: WKWebView) async throws -> Int {
    let image = try await view.takeSnapshot(configuration: nil)
    let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    var pinkPixels = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
           color.redComponent > 0.85, color.greenComponent < 0.25,
           color.blueComponent > 0.3, color.blueComponent < 0.8 { pinkPixels += 1 }
      }
    }
    return pinkPixels
  }

  private func waitForFrameMessages(_ view: WKWebView, count: Int) async throws {
    for _ in 0..<100 {
      if let seen = try await view.evaluateJavaScript("window.frameMessages.length") as? Int, seen >= count { return }
      try await Task.sleep(for: .milliseconds(30))
    }
  }

  func testHTMLSnippetRunsScriptsInsideIsolatedSandboxWithSourceDisclosure() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML("""
    #+begin_src html
    <style>body { margin:0 }</style>
    <div id="board" style="height:40px">Waiting</div>
    <script>
      const board = document.getElementById('board');
      board.style.height = '600px';
      board.textContent = 'Diagram → rendered by script ' + (6 * 7);
      document.body.style.background = 'rgb(255,0,128)';
      let isolated = false;
      try { parent.document.body.dataset.escaped = 'yes'; } catch { isolated = true; }
      parent.postMessage({type: 'probe', value: 6 * 7, isolated}, '*');
    </script>
    #+end_src
    """, sourcePath: "/tmp/chat-html.org")
    let view = try await document()
    view.setFrameSize(NSSize(width: 460, height: 900))
    try await view.evaluateJavaScript("""
      window.violations=[]; window.frameMessages=[];
      document.addEventListener('securitypolicyviolation',e=>violations.push({directive:e.effectiveDirective,blocked:e.blockedURI}));
      addEventListener('message',e=>{ if(e.data && e.data.type==='probe') frameMessages.push(e.data); });
      null
      """)
    try await update(view, payload([entry("html", html)]))
    try await waitForFrameMessages(view, count: 1)
    try await Task.sleep(for: .milliseconds(400))
    let result = try await view.evaluateJavaScript("""
      (() => {
        const frame=document.querySelector('.org2-html-preview iframe');
        let isolated=false;
        try { void frame.contentWindow.document; } catch { isolated=true; }
        return {violations:window.violations.length, frame:!!frame, sandbox:frame?.getAttribute('sandbox'), isolated,
          src:frame?.getAttribute('src') || '', srcdoc:frame?.hasAttribute('srcdoc'),
          messages:JSON.stringify(window.frameMessages),
          escaped:document.body.dataset.escaped || '',
          source:document.querySelector('.org2-html-source')?.textContent,
          height:frame?.getBoundingClientRect().height};
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["violations"] as? Int, 0)
    XCTAssertEqual(result?["frame"] as? Bool, true)
    XCTAssertEqual(result?["sandbox"] as? String, "allow-scripts allow-forms allow-popups")
    XCTAssertTrue((result?["src"] as? String)?.hasPrefix("org2-frame://frame/?document=") == true)
    XCTAssertEqual(result?["srcdoc"] as? Bool, false)
    XCTAssertEqual(result?["isolated"] as? Bool, true)
    XCTAssertEqual(result?["escaped"] as? String, "")
    XCTAssertEqual(result?["messages"] as? String, #"[{"type":"probe","value":42,"isolated":true}]"#)
    XCTAssertTrue((result?["source"] as? String)?.contains("Diagram → rendered") == true)
    let height = try XCTUnwrap(result?["height"] as? Double)
    XCTAssertGreaterThan(height, 595, "the frame grows to the height its script produced")
    XCTAssertLessThan(height, 640)
    let pinkPixels = try await pinkPixelCount(view)
    XCTAssertGreaterThan(pinkPixels, 100, "script output must actually paint inside the production chat shell")
  }

  func testHTMLSnippetHeightIsFixedOrBoundedForViewportSizedContent() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML("""
    #+begin_src html :height 180
    <div style="height:900px">Tall but fixed</div>
    #+end_src

    #+begin_src html
    <div style="height:100vh">Viewport sized</div>
    <script>parent.postMessage({type: 'probe'}, '*')</script>
    #+end_src

    #+begin_src html
    <p>Short</p>
    <script>parent.postMessage({type: 'probe'}, '*')</script>
    #+end_src
    """, sourcePath: "/tmp/chat-html.org")
    let view = try await document()
    view.setFrameSize(NSSize(width: 460, height: 900))
    try await view.evaluateJavaScript("window.frameMessages=[]; addEventListener('message',e=>{ if(e.data && e.data.type==='probe') frameMessages.push(1); }); null")
    try await update(view, payload([entry("html", html)]))
    try await waitForFrameMessages(view, count: 2)
    try await Task.sleep(for: .milliseconds(800))
    let heights = try await view.evaluateJavaScript(
      "[...document.querySelectorAll('.org2-html-preview iframe')].map(f=>f.getBoundingClientRect().height)"
    ) as? [Double]
    XCTAssertEqual(heights?.count, 3)
    XCTAssertEqual(heights?[0] ?? 0, 180, accuracy: 0.5)
    XCTAssertLessThan(heights?[1] ?? .infinity, 500, "viewport-sized content must not grow without bound")
    XCTAssertLessThan(heights?[2] ?? .infinity, 120, "short content shrinks the frame")
    XCTAssertGreaterThan(heights?[2] ?? 0, 30)
  }

  func testScriptedPluginFramesRunButSameOriginFramesKeepTheChatPolicy() async throws {
    func frame(_ sandbox: String, _ body: String) -> String {
      let document = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'\"></head><body>\(body)</body></html>"
      let escaped = document.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
      return "<iframe sandbox=\"\(sandbox)\" srcdoc=\"\(escaped)\"></iframe>"
    }
    let html = """
    <main class="org2-document"><figure class="org2-plugin-render">\(frame("allow-scripts", "<script>parent.postMessage({type:'probe', from:'plugin'}, '*')</script>"))</figure>
    <section class="org2-live-embed">\(frame("allow-same-origin", "<script>parent.postMessage({type:'probe', from:'embed'}, '*')</script>"))</section></main>
    """
    let view = try await document()
    try await view.evaluateJavaScript("window.frameMessages=[]; addEventListener('message',e=>{ if(e.data && e.data.type==='probe') frameMessages.push(e.data.from); }); null")
    try await update(view, payload([entry("plugin", html)]))
    try await waitForFrameMessages(view, count: 1)
    try await Task.sleep(for: .milliseconds(500))
    let result = try await view.evaluateJavaScript("""
      ({messages: frameMessages.join(','),
        embedSrcdoc: document.querySelector('.org2-live-embed iframe').hasAttribute('srcdoc'),
        pluginSrc: document.querySelector('.org2-plugin-render iframe').getAttribute('src') || ''})
      """) as? [String: Any]
    XCTAssertEqual(result?["messages"] as? String, "plugin")
    XCTAssertEqual(result?["embedSrcdoc"] as? Bool, true)
    XCTAssertTrue((result?["pluginSrc"] as? String)?.hasPrefix("org2-frame:") == true)
  }

  func testSelectableTranscriptDoesNotSuppressLiveActivityInSharedRooms() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/AIChatTranscriptDocument.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private var liveInput: LiveInput?"))
    let end = try XCTUnwrap(source.range(
      of: "var body: some View",
      range: start.upperBound..<source.endIndex
    ))
    let liveInputSource = source[start.lowerBound..<end.lowerBound]

    XCTAssertTrue(liveInputSource.contains("store.isSendingAIChatMessage"))
    XCTAssertTrue(liveInputSource.contains("store.selectedAIChatActiveDestinationID"))
    XCTAssertFalse(liveInputSource.contains("!store.selectedAIChatIsSharedRoom"))
  }

  func testNativeSelectionCrossesMessagesAndSurvivesIncomingUpdates() async throws {
    let view = try await document()
    let first = entry("first", "<main><p>Start in the first message.</p></main>", role: "user")
    let second = entry("second", "<main><ul><li>Continue into the second message.</li></ul><pre>let answer = 42</pre></main>")
    try await update(view, payload([first, second]))
    let selected = try await view.evaluateJavaScript("""
      const range=document.createRange();
      range.setStart(document.querySelector('#message-first p').firstChild, 6);
      range.setEnd(document.querySelector('#message-second li').firstChild, 24);
      getSelection().removeAllRanges(); getSelection().addRange(range); getSelection().toString();
      """) as? String
    XCTAssertTrue(selected?.contains("in the first message.") == true)
    XCTAssertTrue(selected?.contains("Continue into the second") == true)
    let third = entry("third", "<main><p>A newly arrived response.</p></main>")
    try await update(view, payload([first, second, third]))
    let retained = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(selected, retained)
    let held = try await view.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(held, 2)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange')); null;")
    try await Task.sleep(for: .milliseconds(80))
    let applied = try await view.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(applied, 3)
  }

  func testSwitchingThreadsClearsOldSelectionAndContents() async throws {
    let view = try await document()
    try await update(view, payload([entry("old", "<main><p>Old thread text.</p></main>")]))
    try await view.evaluateJavaScript("const r=document.createRange(); r.selectNodeContents(document.querySelector('article')); getSelection().addRange(r); null;")
    try await update(view, payload([entry("new", "<main><p>New thread text.</p></main>")], thread: "new-thread"))
    let old = try await view.evaluateJavaScript("!!document.getElementById('message-old')") as? Bool
    let selected = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(old, false)
    XCTAssertEqual(selected, "")
  }

  func testWarmThreadSwitchReusesRenderedMessageDOM() async throws {
    let view = try await document()
    let first = entry("warm", "<main><p><strong>Already rendered.</strong></p></main>")
    let second = entry("other", "<main><p>Another thread.</p></main>")
    try await update(view, payload([first], thread: "first-thread"))
    try await view.evaluateJavaScript(
      "window.firstWarmMessageNode=document.getElementById('message-warm'); null;"
    )

    try await update(view, payload([second], thread: "second-thread"))
    try await update(view, payload([first], thread: "first-thread"))

    let reused = try await view.evaluateJavaScript(
      "document.getElementById('message-warm')===window.firstWarmMessageNode"
    ) as? Bool
    XCTAssertEqual(reused, true)
  }

  func testWarmRenderedBodyCacheValidatesMessageRevisionAndCorpus() {
    AIChatTranscriptRenderedBodyCache.removeAllForTesting()
    let messageID = UUID()
    let body = AIChatTranscriptRenderedBody(
      source: "* Already rendered",
      expanded: false,
      html: "<main><strong>Already rendered</strong></main>",
      plainText: nil,
      contexts: []
    )
    AIChatTranscriptRenderedBodyCache.install(
      body,
      messageID: messageID,
      sourcePath: "/tmp/first/chat-message.org"
    )

    XCTAssertEqual(
      AIChatTranscriptRenderedBodyCache.body(
        messageID: messageID,
        source: body.source,
        expanded: false,
        sourcePath: "/tmp/first/chat-message.org"
      ),
      body
    )
    XCTAssertNil(AIChatTranscriptRenderedBodyCache.body(
      messageID: messageID,
      source: "* Edited message",
      expanded: false,
      sourcePath: "/tmp/first/chat-message.org"
    ))
    XCTAssertNil(AIChatTranscriptRenderedBodyCache.body(
      messageID: messageID,
      source: body.source,
      expanded: false,
      sourcePath: "/tmp/second/chat-message.org"
    ))
  }

  func testOnlyTheTranscriptScrollsVerticallyIncludingOverCode() async throws {
    let view = try await document()
    let prose = String(repeating: "<p>A paragraph that contributes to the full transcript height.</p>", count: 30)
    let code = (0..<90).map { "line \($0) " + String(repeating: "x", count: 160) }.joined(separator: "\n")
    try await update(view, payload([entry("long", "<main>\(prose)<pre>\(code)</pre></main>")]))
    let result = try await view.evaluateJavaScript("""
      (()=>({height:document.documentElement.scrollHeight,
        nested:[...document.querySelectorAll('body *')].filter(e=>['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.scrollHeight>e.clientHeight+1).map(e=>e.tagName),
        codeHorizontal:document.querySelector('pre').scrollWidth>document.querySelector('pre').clientWidth}))()
      """) as? [String: Any]
    XCTAssertGreaterThan(result?["height"] as? Double ?? 0, 1000)
    XCTAssertEqual(result?["nested"] as? [String], [])
    XCTAssertEqual(result?["codeHorizontal"] as? Bool, true)
    try await view.evaluateJavaScript("window.scrollBy(0,500); null;")
    try await Task.sleep(for: .milliseconds(80))
    let offset = try await view.evaluateJavaScript("window.scrollY") as? Double
    XCTAssertGreaterThan(offset ?? 0, 400)
    let inner = try await view.evaluateJavaScript("document.querySelector('pre').scrollTop") as? Double
    XCTAssertEqual(inner, 0)
  }

  func testSearchAndPrependingHistoryPreserveTheReadingLocation() async throws {
    let view = try await document()
    let entries = (0..<8).map { entry("m\($0)", "<main>" + String(repeating: "<p>Message \($0) text.</p>", count: 8) + "</main>") }
    try await update(view, payload(entries, position: 1))
    try await update(view, payload(entries, search: "m3", generation: 1))
    let before = try await view.evaluateJavaScript("document.getElementById('message-m3').getBoundingClientRect().top") as? Double
    let earlier = entry("earlier", "<main>" + String(repeating: "<p>Earlier text.</p>", count: 15) + "</main>")
    try await update(view, payload([earlier] + entries, search: "m3", generation: 1))
    let after = try await view.evaluateJavaScript("document.getElementById('message-m3').getBoundingClientRect().top") as? Double
    XCTAssertEqual(before ?? -10000, after ?? 10000, accuracy: 2)
    let highlighted = try await view.evaluateJavaScript("document.querySelector('article.match').id") as? String
    XCTAssertEqual(highlighted, "message-m3")
  }

  func testMessageAndCodeCopyButtonsKeepTheirOwnTargets() async throws {
    let view = try await document()
    try await update(view, payload([entry("copy-me", "<main><pre>first line\nsecond line\n</pre></main>")]))
    try await view.evaluateJavaScript("document.querySelector('.message-header button').click(); document.querySelector('.chat-copy-code').click(); null;")
    let result = try await view.evaluateJavaScript("events") as? [[String: Any]] ?? []
    XCTAssertTrue(result.contains { $0["action"] as? String == "copy" && $0["id"] as? String == "copy-me" })
    XCTAssertTrue(result.contains { $0["code"] as? String == "first line\nsecond line" })
  }

  func testReplyButtonFollowsCopyAndRepliesShowAsReplyPills() async throws {
    let reply = AIChatContextPresentation(AIChatContextPresentation.replyContext(
      author: "Codex", messageID: UUID(), content: "The build is green."
    ) + "\n\nShip it")
    let replyEntry = AIChatTranscriptHTML.Entry(
      id: "user-reply", role: "user", title: "You", timestamp: "Today",
      html: "<main><p>Ship it</p></main>", plainText: nil, preparing: false,
      contexts: reply.contexts.map(AIChatTranscriptHTML.Context.init), attachments: [], failure: nil,
      queued: false, canSteer: false, isRoomResponse: false, copied: false, isTruncated: false,
      responseTrace: nil, changeSummary: nil
    )
    let view = try await document()
    try await update(view, payload([entry("answer", "<main><p>The build is green.</p></main>"), replyEntry]))
    let result = try await view.evaluateJavaScript("""
      (()=>{
        const buttons=[...document.querySelectorAll('#message-answer .message-header button')];
        buttons[1].click();
        const pill=document.querySelector('#message-user-reply .context-pill');
        return {labels:buttons.map(b=>b.getAttribute('aria-label')), pill:pill.textContent, reply:pill.classList.contains('reply-pill')};
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["labels"] as? [String], ["Copy message", "Reply to this message"])
    XCTAssertEqual(result?["pill"] as? String, "↩ Codex: The build is green.")
    XCTAssertEqual(result?["reply"] as? Bool, true)
    let events = try await view.evaluateJavaScript("events") as? [[String: Any]] ?? []
    XCTAssertTrue(events.contains { $0["action"] as? String == "reply" && $0["id"] as? String == "answer" })
  }

  func testImageAttachmentsRenderInlinePreviews() async throws {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 8,
      pixelsHigh: 8,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let attachment = AIChatAttachment(
      fileName: "Screenshot.png",
      mimeType: "image/png",
      data: imageData
    )
    let view = try await document(attachments: [attachment])
    try await update(view, payload([
      entry(
        "image",
        "<main><p>See attached.</p></main>",
        role: "user",
        attachments: [AIChatTranscriptHTML.Attachment(attachment)]
      )
    ]))

    var result: [String: Any] = [:]
    for _ in 0..<150 {
      result = try await view.evaluateJavaScript("""
        (()=>{
          const image=document.querySelector('.attachment-preview img');
          return { count:document.querySelectorAll('.attachment-preview img').length,
            width:image?.naturalWidth||0, source:image?.getAttribute('src')||'' };
        })()
        """) as? [String: Any] ?? [:]
      if result["width"] as? Int == 8 { break }
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(result["count"] as? Int, 1)
    XCTAssertEqual(result["width"] as? Int, 8)
    XCTAssertTrue(
      (result["source"] as? String)?.hasPrefix("org2-resource://attachment/") == true
    )
  }

  func testEstablishedMessageChromeAndInlineSummariesRemainVisible() async throws {
    let trace = AIChatTranscriptHTML.Trace(AIChatResponseTrace(
      reasoning: "Checked the existing renderer before changing the transcript.",
      activities: [AIChatRunActivity(
        id: "tool-1", runID: "run", kind: .tool, title: "Read source",
        detail: "/tmp/ContentView.swift", status: .succeeded
      )],
      usage: AIChatTokenUsage(
        inputTokens: 120,
        cachedInputTokens: 80,
        outputTokens: 30,
        totalTokens: 150
      ),
      context: OpenOrgContextTelemetry(
        mode: .delta,
        staticTokens: 10,
        projectTokens: 5
      )
    ))
    let changeSummary = AIChatTranscriptHTML.ChangeSummary(AIChatCorpusChangeSummary(files: [
      AIChatCorpusFileChange(relativePath: "ContentView.swift", status: .modified, insertions: 4, deletions: 2)
    ]))
    let view = try await document()
    try await update(view, payload([entry(
      "summaries", "<main><p>Finished the change.</p></main>",
      trace: trace, changeSummary: changeSummary
    )]))
    let result = try await view.evaluateJavaScript("""
      ({copyText:document.querySelector('.message-header button').textContent,
        copyLabel:document.querySelector('.message-header button').getAttribute('aria-label'),
        trace:document.querySelector('.trace').innerText,
        changes:document.querySelector('.change-summary').innerText,
        details:[...document.querySelectorAll('button')].some(b=>b.textContent==='Message details')})
      """) as? [String: Any]
    XCTAssertEqual(result?["copyText"] as? String, "")
    XCTAssertEqual(result?["copyLabel"] as? String, "Copy message")
    XCTAssertTrue((result?["trace"] as? String)?.contains("Approach") == true)
    XCTAssertTrue((result?["trace"] as? String)?.contains("Read source") == true)
    XCTAssertTrue((result?["trace"] as? String)?.contains("Provider tokens") == true)
    XCTAssertTrue((result?["trace"] as? String)?.contains("Celorga context") == true)
    XCTAssertTrue((result?["changes"] as? String)?.contains("ContentView.swift") == true)
    XCTAssertEqual(result?["details"] as? Bool, false)
  }

  func testPreparingMessageUsesAVisualSkeletonWithoutVisiblePlaceholderCopy() async throws {
    let view = try await document()
    try await update(view, payload([
      entry("pending", AIChatDocumentHTML.plain(""), role: "user", preparing: true)
    ]))

    let result = try await view.evaluateJavaScript("""
      (()=>{
        const placeholder=document.querySelector('#message-pending .message-placeholder');
        return {
          exists:!!placeholder,
          label:placeholder?.getAttribute('aria-label'),
          lines:placeholder?.querySelectorAll('.message-placeholder-line').length,
          visibleCopy:document.querySelector('#message-pending .message-card').innerText
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["exists"] as? Bool, true)
    XCTAssertEqual(result?["label"] as? String, "Preparing message")
    XCTAssertEqual(result?["lines"] as? Int, 2)
    XCTAssertFalse((result?["visibleCopy"] as? String ?? "").contains("Preparing message"))
    XCTAssertTrue(AIChatTranscriptHTML.style.contains("@keyframes placeholder-pulse"))
    XCTAssertTrue(AIChatTranscriptHTML.style.contains(".message-placeholder-pulse,.message-placeholder-line { animation:none; }"))
  }

  func testLoadedUserMessageReusesItsWarmSafePresentation() {
    AIChatMessagePresentationCache.removeAllForTesting()
    let message = AIChatMessage(
      role: .user,
      content: """
      Use selected file “Private” at notes/private.org as context.
      #+begin_org2_ai_context
      PRIVATE-AUTOMATIC-PROMPT
      #+end_org2_ai_context

      Visible user message.
      """
    )
    XCTAssertNil(AIChatTranscriptHTML.cachedPreparedBody(for: message, expanded: false))

    AIChatMessagePresentationCache.install(
      AIChatMessagePresentationBuilder.prepare(AIChatMessagePresentationInput(message))
    )
    let warm = AIChatTranscriptHTML.cachedPreparedBody(for: message, expanded: false)

    XCTAssertNotNil(warm)
    XCTAssertTrue(warm?.html.contains("Visible user message.") == true)
    XCTAssertFalse(warm?.html.contains("PRIVATE-AUTOMATIC-PROMPT") == true)
    XCTAssertEqual(warm?.contexts.map(\.title), ["Private"])
    XCTAssertNil(AIChatTranscriptHTML.cachedPreparedBody(for: message, expanded: true))
  }

  func testPlainAssistantMessageReusesWarmPresentationWithoutRichRendering() {
    AIChatMessagePresentationCache.removeAllForTesting()
    let plain = AIChatMessage(
      role: .assistant,
      content: "A local plain-text response with no Org syntax."
    )
    let structured = AIChatMessage(
      role: .assistant,
      content: "* Result\n\n- One item"
    )
    AIChatMessagePresentationCache.install([
      AIChatMessagePresentationBuilder.prepare(AIChatMessagePresentationInput(plain)),
      AIChatMessagePresentationBuilder.prepare(AIChatMessagePresentationInput(structured)),
    ])

    let body = AIChatTranscriptHTML.cachedPreparedBody(for: plain, expanded: false)
    XCTAssertTrue(body?.html.contains("A local plain-text response") == true)
    XCTAssertEqual(body?.plainText, plain.content)
    XCTAssertNil(AIChatTranscriptHTML.cachedPreparedBody(for: structured, expanded: false))
  }

  func testAuxiliaryControlsKeepIconsTextAndActionsAlignedAtNarrowWidths() async throws {
    let activities = (0..<4).map { index in
      AIChatRunActivity(
        id: "tool-\(index)", runID: "run", kind: .tool, title: "Activity \(index)",
        detail: "A useful detail", status: .succeeded
      )
    }
    let trace = try XCTUnwrap(AIChatTranscriptHTML.Trace(AIChatResponseTrace(
      reasoning: "Checked the transcript layout before updating it.",
      activities: activities
    )))
    let view = try await document()
    view.frame.size.width = 300
    try await update(view, payload([
      entry(
        "failure", "<main><p>Request body.</p></main>", role: "user",
        failure: "Codex turn failed: Selected model is at capacity. Please try a different model."
      ),
      entry("trace", "<main><p>Response body.</p></main>", trace: trace),
    ], sending: true))

    let result = try await view.evaluateJavaScript("""
      (()=>{
        const retry=document.querySelector('.failure button');
        const toggle=document.querySelector('.disclosure-button');
        toggle.click();
        const toggleIcon=toggle.querySelector('.glyph').getBoundingClientRect();
        const toggleLabel=toggle.querySelector('span:last-child').getBoundingClientRect();
        const status=document.getElementById('status');
        const style=e=>getComputedStyle(e);
        return {
          failureDisplay:style(document.querySelector('.failure')).display,
          retryWhiteSpace:style(retry).whiteSpace,
          retryFits:retry.scrollWidth<=retry.clientWidth,
          toggleDisplay:style(toggle).display,
          toggleWhiteSpace:style(toggle).whiteSpace,
          toggleText:toggle.textContent,
          toggleCenterDelta:Math.abs((toggleIcon.top+toggleIcon.height/2)-(toggleLabel.top+toggleLabel.height/2)),
          statusDisplay:style(status).display,
          statusAlignment:style(status).alignItems,
          statusText:status.innerText
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["failureDisplay"] as? String, "grid")
    XCTAssertEqual(result?["retryWhiteSpace"] as? String, "nowrap")
    XCTAssertEqual(result?["retryFits"] as? Bool, true)
    XCTAssertEqual(result?["toggleDisplay"] as? String, "flex")
    XCTAssertEqual(result?["toggleWhiteSpace"] as? String, "nowrap")
    XCTAssertEqual(result?["toggleText"] as? String, "Show less")
    XCTAssertLessThan(result?["toggleCenterDelta"] as? Double ?? 100, 1)
    XCTAssertEqual(result?["statusDisplay"] as? String, "flex")
    XCTAssertEqual(result?["statusAlignment"] as? String, "center")
    XCTAssertEqual(result?["statusText"] as? String, "Working…Stop")
  }

  func testLiveAgentUpdatesAndAnimationRemainInsideTheSelectableDocument() async throws {
    func activity(_ title: String, status: AIChatRunActivity.Status) -> AIChatTranscriptHTML.Activity {
      AIChatTranscriptHTML.Activity(AIChatActivityFeedItem(
        id: title, title: title, detail: "Started", latestDetail: "Still working",
        status: status, count: 1, updatedAt: Date()
      ))
    }
    func live(_ text: String) -> AIChatTranscriptHTML.Live {
      .init(
        title: "Codex is thinking", detail: nil,
        quietTitle: "Waiting for Codex", quietDetail: "No new activity for 2m. It may still be working.",
        stalledTitle: "Codex may be stalled",
        stalledDetail: "No new activity for 10m. The run is saved; the connection or agent may be stalled.",
        startedAtMilliseconds: Date().addingTimeInterval(-65).timeIntervalSince1970 * 1_000,
        lastEventAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
        usesLivenessThresholds: true, animates: true, text: text,
        hasEarlierText: true, textExpanded: false, reasoning: "Inspecting the relevant implementation.",
        activities: [activity("Read source", status: .succeeded), activity("Run tests", status: .running)],
        activityExpanded: false
      )
    }
    let message = entry("message", "<main><p>Select this message while a live update arrives.</p></main>")
    let firstLive = live("I found the missing live-state bridge.")
    let view = try await document()
    try await update(view, payload([message], sending: true, live: firstLive))

    let visible = try await view.evaluateJavaScript("""
      (()=>({
        hidden:document.getElementById('live').hidden,
        title:document.querySelector('.live-title').textContent,
        text:document.querySelector('.live-text').textContent,
        activities:document.querySelectorAll('.live-feed .activity-row').length,
        activityTitle:document.querySelector('.live-feed .activity-title').textContent,
        animating:document.getElementById('live').classList.contains('animating'),
        elapsed:document.querySelector('.live-elapsed').textContent,
        fallback:document.getElementById('status').innerText
      }))()
      """) as? [String: Any]
    XCTAssertEqual(visible?["hidden"] as? Bool, false)
    XCTAssertEqual(visible?["title"] as? String, "Codex is thinking")
    XCTAssertEqual(visible?["text"] as? String, firstLive.text)
    XCTAssertEqual(visible?["activities"] as? Int, 1)
    XCTAssertEqual(visible?["activityTitle"] as? String, "Run tests")
    XCTAssertEqual(visible?["animating"] as? Bool, true)
    XCTAssertTrue(AIChatTranscriptHTML.style.contains("@keyframes shimmer"))
    XCTAssertTrue((visible?["elapsed"] as? String)?.hasPrefix("1m ") == true)
    XCTAssertEqual(visible?["fallback"] as? String, "")

    try await view.evaluateJavaScript("document.querySelector('.live-stop').click(); document.querySelector('.live-activity-toggle').click(); null;")
    let actions = try await view.evaluateJavaScript("events.map(x=>x.action)") as? [String] ?? []
    XCTAssertTrue(actions.contains("stop"))
    XCTAssertTrue(actions.contains("liveActivityToggle"))

    try await view.evaluateJavaScript("""
      const range=document.createRange(); range.selectNodeContents(document.querySelector('#message-message p'));
      getSelection().removeAllRanges(); getSelection().addRange(range); null;
      """)
    let secondLive = live("The streamed update changed without replacing the selection.")
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(secondLive), encoding: .utf8))
    try await view.evaluateJavaScript("window.__transcriptLiveUpdate(\(json)); null;")
    let heldText = try await view.evaluateJavaScript("document.querySelector('.live-text').textContent") as? String
    XCTAssertEqual(heldText, firstLive.text)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange')); null;")
    let updatedText = try await view.evaluateJavaScript("document.querySelector('.live-text').textContent") as? String
    XCTAssertEqual(updatedText, secondLive.text)
    XCTAssertTrue(AIChatTranscriptWebView.documentPayloadMatches(
      payload([message], sending: true, live: firstLive),
      payload([message], sending: true, live: secondLive)
    ))
  }

  func testLiveReasoningUpdatesItsExistingTrailNodeInPlace() async throws {
    func live(reasoning: String, reasoningHTML: String) -> AIChatTranscriptHTML.Live {
      AIChatTranscriptHTML.Live(
        title: "Codex is thinking", detail: nil,
        quietTitle: "Waiting for Codex", quietDetail: "Quiet",
        stalledTitle: "Codex may be stalled", stalledDetail: "Stalled",
        startedAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
        lastEventAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
        usesLivenessThresholds: false, animates: true,
        text: nil, textHTML: nil,
        hasEarlierText: false, textExpanded: false,
        reasoning: reasoning, reasoningHTML: reasoningHTML,
        activities: [], activityExpanded: true
      )
    }
    let first = live(
      reasoning: "Check =first=.",
      reasoningHTML: "<main><p>Check <code>first</code>.</p></main>"
    )
    let second = live(
      reasoning: "Check =second=.",
      reasoningHTML: "<main><p>Check <code>second</code>.</p></main>"
    )
    let view = try await document()
    try await update(view, payload([], sending: true, live: first))
    try await view.evaluateJavaScript("""
      window.liveReasoningRow=document.querySelector('.live-feed > .reasoning-row');
      window.liveReasoningValue=document.querySelector('.live-feed .reasoning-text');
      null;
      """)

    let json = try XCTUnwrap(String(data: JSONEncoder().encode(second), encoding: .utf8))
    try await view.evaluateJavaScript("window.__transcriptLiveUpdate(\(json)); null;")
    let result = try await view.evaluateJavaScript("""
      ({
        sameRow:document.querySelector('.live-feed > .reasoning-row')===window.liveReasoningRow,
        sameValue:document.querySelector('.live-feed .reasoning-text')===window.liveReasoningValue,
        code:document.querySelector('.live-feed .reasoning-text code')?.textContent,
        rows:document.querySelectorAll('.live-feed > .reasoning-row').length
      })
      """) as? [String: Any]
    XCTAssertEqual(result?["sameRow"] as? Bool, true)
    XCTAssertEqual(result?["sameValue"] as? Bool, true)
    XCTAssertEqual(result?["code"] as? String, "second")
    XCTAssertEqual(result?["rows"] as? Int, 1)
  }

  func testQuietOpenCodeRunIsNotLabelledStalledInTheHTMLTranscript() async throws {
    let openCode = AIChatTypingIndicatorView.livenessThresholdPresentation(
      runtime: .openCode,
      displayTitle: "OpenCode on press.local"
    )
    XCTAssertEqual(openCode.stalledTitle, "Waiting for OpenCode on press.local")
    XCTAssertFalse(openCode.stalledTitle.contains("stalled"))
    XCTAssertTrue(openCode.stalledAnimates)
    let codex = AIChatTypingIndicatorView.livenessThresholdPresentation(runtime: .codex, displayTitle: "Codex")
    XCTAssertEqual(codex.stalledTitle, "Codex may be stalled")
    XCTAssertFalse(codex.stalledAnimates)

    func live(_ thresholds: AIChatTypingIndicatorView.LivenessThresholdPresentation) -> AIChatTranscriptHTML.Live {
      AIChatTranscriptHTML.Live(
        title: "Working", detail: nil,
        quietTitle: thresholds.quietTitle, quietDetail: thresholds.quietDetail,
        stalledTitle: thresholds.stalledTitle, stalledDetail: thresholds.stalledDetail,
        stalledAnimates: thresholds.stalledAnimates,
        startedAtMilliseconds: Date().addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1_000,
        lastEventAtMilliseconds: Date().addingTimeInterval(-12 * 60).timeIntervalSince1970 * 1_000,
        usesLivenessThresholds: true, animates: true,
        text: nil, hasEarlierText: false, textExpanded: false,
        reasoning: nil, activities: [], activityExpanded: false
      )
    }
    let script = """
      ({
        title:document.querySelector('.live-title').textContent,
        animating:document.getElementById('live').classList.contains('animating')
      })
      """
    let view = try await document()
    try await update(view, payload([], sending: true, live: live(openCode)))
    let quietOpenCode = try await view.evaluateJavaScript(script) as? [String: Any]
    XCTAssertEqual(quietOpenCode?["title"] as? String, "Waiting for OpenCode on press.local")
    XCTAssertEqual(quietOpenCode?["animating"] as? Bool, true)

    try await update(view, payload([], sending: true, live: live(codex)))
    let quietCodex = try await view.evaluateJavaScript(script) as? [String: Any]
    XCTAssertEqual(quietCodex?["title"] as? String, "Codex may be stalled")
    XCTAssertEqual(quietCodex?["animating"] as? Bool, false)
  }

  func testLiveAndSavedReasoningUseOrgRendering() async throws {
    let commentary = "I’m fixing =main=; see [[https://example.com/docs][the docs]]."
    let reasoning = "Reuse the =Org2= renderer for *reasoning*, too."
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let commentaryHTML = try await cli.renderAppHTML(
      AIChatMessageOrgNormalizer.normalized(commentary),
      sourcePath: "/tmp/chat-message.org"
    )
    let reasoningHTML = try await cli.renderAppHTML(
      AIChatMessageOrgNormalizer.normalized(reasoning),
      sourcePath: "/tmp/chat-message.org"
    )
    let trace = try XCTUnwrap(AIChatTranscriptHTML.Trace(
      AIChatResponseTrace(reasoning: reasoning),
      reasoningHTML: reasoningHTML
    ))
    let live = AIChatTranscriptHTML.Live(
      title: "Codex is thinking", detail: nil,
      quietTitle: "Waiting for Codex", quietDetail: "Quiet",
      stalledTitle: "Codex may be stalled", stalledDetail: "Stalled",
      startedAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
      lastEventAtMilliseconds: Date().timeIntervalSince1970 * 1_000,
      usesLivenessThresholds: false, animates: true,
      text: commentary, textHTML: commentaryHTML,
      hasEarlierText: false, textExpanded: false,
      reasoning: reasoning, reasoningHTML: reasoningHTML,
      activities: [], activityExpanded: true
    )
    let view = try await document()
    try await update(view, payload([
      entry("rendered-reasoning", "<main><p>Finished.</p></main>", trace: trace)
    ], sending: true, live: live))

    let result = try await view.evaluateJavaScript("""
      ({
        liveCode:document.querySelector('.live-text code')?.textContent,
        liveLink:document.querySelector('.live-text a')?.textContent,
        liveLiteral:document.querySelector('.live-text').innerText.includes('=main='),
        traceCode:document.querySelector('.trace .reasoning-text code')?.textContent,
        traceStrong:document.querySelector('.trace .reasoning-text strong')?.textContent,
        liveReasoningCode:document.querySelector('.live-feed .reasoning-text code')?.textContent
      })
      """) as? [String: Any]
    XCTAssertEqual(result?["liveCode"] as? String, "main")
    XCTAssertEqual(result?["liveLink"] as? String, "the docs")
    XCTAssertEqual(result?["liveLiteral"] as? Bool, false)
    XCTAssertEqual(result?["traceCode"] as? String, "Org2")
    XCTAssertEqual(result?["traceStrong"] as? String, "reasoning")
    XCTAssertEqual(result?["liveReasoningCode"] as? String, "Org2")
  }

  func testOrgAndLegacyCitationsRenderAsLinksWithExactLineTargets() async throws {
    let raw = "Org [[file:/tmp/note.org::16][project notes]], legacy [source](/tmp/file.swift:42), web [site](https://example.com)."
    let normalized = AIChatMessageOrgNormalizer.normalized(raw)
    XCTAssertTrue(normalized.contains("[[file:/tmp/file.swift::42][source]]"))
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(normalized, sourcePath: "/tmp/chat-message.org")
    let view = try await document()
    try await update(view, payload([entry("links", html)]))
    let links = try await view.evaluateJavaScript("[...document.querySelectorAll('main a')].map(a=>({label:a.textContent,href:a.getAttribute('href')}))") as? [[String:String]] ?? []
    XCTAssertEqual(links.map { $0["label"] ?? "" }, ["project notes", "source", "site"])
    XCTAssertTrue(links.contains { ($0["href"]?.removingPercentEncoding ?? "").contains("file:/tmp/file.swift::42") })
    let resolved = await OrgHTMLLinkTarget.resolve("file:/tmp/file.swift::42", relativeTo: "/tmp/chat-message.org", corpusRoot: nil)
    XCTAssertEqual(resolved?.url.path, "/tmp/file.swift")
    XCTAssertEqual(resolved?.line, 42)
  }

  func testCitationCompatibilityLeavesCodeAndExistingOrgLinksLiteral() {
    let literal = "=[example](/tmp/file.org:2)= and ~[example](/tmp/file.org:2)~"
    XCTAssertEqual(AIChatCitationNormalizer.normalized(literal), literal)
    let block = "#+begin_src text\n[example](/tmp/file.org:2)\n#+end_src"
    XCTAssertEqual(AIChatCitationNormalizer.normalized(block), block)
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[[file:/tmp/file.org::2][source]]"), "[[file:/tmp/file.org::2][source]]")
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[source](</tmp/My Note (draft).org:16>)"), "[[file:/tmp/My Note (draft).org::16][source]]")
    XCTAssertEqual(AIChatCitationNormalizer.normalized("[source](/tmp/note.org#L16-L20)"), "[[file:/tmp/note.org::16][source]]")
  }

  func testAllRuntimePromptsRequestOrgCitations() {
    let context = AIChatWorkspaceContext(localCorpusRoot: "/tmp/corpus", remoteCorpusRoot: "/tmp/corpus",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil, backlinks: nil,
      agenda: nil, searchQuery: "", searchResults: [])
    // Codex receives the standing instructions once, as thread developer
    // instructions, so its per-turn prompt does not repeat them.
    let prompts = [
      context.systemPrompt(),
      CodexAppServerClient.developerInstructions(for: .clientWorkspaceTools),
      CodexAppServerClient.developerInstructions(for: .runtimeFilesystem),
      context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code"),
    ]
    for prompt in prompts {
      XCTAssertTrue(prompt.contains("[[file:/absolute/path/note.org::42][source]]"))
      XCTAssertFalse(prompt.contains("use Markdown links"))
      XCTAssertFalse(prompt.contains("Markdown chat transport exception"))
    }
  }

}
