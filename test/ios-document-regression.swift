import Foundation

@main
struct DocumentRegression {
  static func check(_ condition: Bool, _ message: String) {
    guard condition else {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(1)
    }
  }

  static func main() async throws {
    let runtime = try MobileDocumentRuntime()
    let source = """
      #+TITLE: Recipes
      * Breakfast
      Toast.
      * Pour over
      :PROPERTIES:
      :ID: coffee
      :END:
      - Coffee: 14 g
      - Water: 225 g
      ** Grind
      Fine, setting 15.
      * Tea
      Steep 3 minutes.
      """
    let entries = try runtime.index(source: source, path: "notes/recipes.org", sequences: [])
    let coffee = entries.first { $0.nodeID == "coffee" }!
    check(coffee.line == 4, "The native bridge must preserve source lines")
    let rendered = try runtime.render(source: "\n" + source, path: coffee.path, entry: coffee, sequences: [])
    check(rendered.html.contains("225 g") && rendered.html.contains("setting 15"), "Entry rendering lost recipe content")
    check(!rendered.html.contains("Steep 3 minutes"), "Entry rendering included a sibling")
    let full = try runtime.render(source: source, path: coffee.path, entry: nil, sequences: [])
    check(full.html.contains("Steep 3 minutes"), "Full-note rendering lost a sibling")
    do {
      _ = try runtime.render(source: "* Removed", path: coffee.path, entry: coffee, sequences: [])
      check(false, "A removed entry must fail visibly")
    } catch { }
    check(try runtime.index(source: "* READY Coffee", path: "test.org", sequences: ["READY | FINISHED"])[1].title == "Coffee", "Corpus TODO definitions were lost")
    let start = Date()
    for n in 0..<300 {
      _ = try runtime.index(source: source, path: "notes/\(n).org", sequences: [])
    }
    let elapsed = Date().timeIntervalSince(start)
    check(elapsed < 10, "Native indexing of 300 small documents exceeded 10s: \(elapsed)")
    print("iOS JavaScriptCore bridge passed; indexed 300 recipe documents in \(elapsed)s")

    let linkedSource = """
      :PROPERTIES:
      :ID: document-id
      :END:
      #+TITLE: Link tests
      * Coffee ☕
      :PROPERTIES:
      :ID: coffee-id
      :CUSTOM_ID: coffee
      :END:
      Pour 225 g.
      ** Next pour
      Add water.
      * Tea
      Steep.
      """
    for selector in ["id:coffee-id", "#coffee", "*Coffee ☕", "6", "10"] {
      let entry = try runtime.resolveEntry(source: linkedSource, path: "notes/recipes.org", selector: selector, sequences: [])
      check(entry?.nodeID == "coffee-id", "Entry selector failed: \(selector)")
      let html = try runtime.render(source: linkedSource, path: "notes/recipes.org", entry: entry, sequences: []).html
      check(html.contains("225 g") && !html.contains("Steep."), "Entry link must render only its subtree")
    }
    let moved = "#+AUTHOR: Example\n" + linkedSource
    let movedEntry = try runtime.resolveEntry(source: moved, path: "notes/recipes.org", selector: "id:coffee-id", sequences: [])
    check(movedEntry?.line == 6, "Stable ID failed after lines moved")
    let documentEntry = try runtime.resolveEntry(source: linkedSource, path: "notes/recipes.org", selector: "id:document-id", sequences: [])
    check(documentEntry == nil, "Document ID should open full note")
    let linkedIndex = try runtime.index(source: linkedSource, path: "notes/recipes.org", sequences: [])
    check(linkedIndex.first?.nodeID == "document-id", "File IDs must be indexed")
    for selector in ["id:missing", "#missing", "*Missing", "999"] {
      do {
        _ = try runtime.resolveEntry(source: linkedSource, path: "notes/recipes.org", selector: selector, sequences: [])
        check(false, "Missing link silently opened the wrong entry: \(selector)")
      } catch { }
    }
    do {
      _ = try runtime.resolveEntry(source: "* Duplicate\n* Duplicate", path: "test.org", selector: "*Duplicate", sequences: [])
      check(false, "Ambiguous heading links must fail")
    } catch { }
    let linkedHTML = try runtime.render(source: "* Links\n[[id:coffee-id][Coffee]] [[file:recipes.org::*Coffee ☕][Recipe]]", path: "links.org", entry: nil, sequences: []).html
    check(linkedHTML.contains("org2-workspace://open-link?target=id%3Acoffee-id"), "ID link missing from rendered HTML")
    check(linkedHTML.contains("target=file%3Arecipes.org%3A%3A*Coffee"), "Entry link missing from rendered HTML")
    print("Entry link IDs, headings, custom IDs, line selectors, moved/missing entries and HTML passed")

    let longProse = "* Long note\n" + String(repeating: "Text. ", count: 150_000)
    let proseStart = Date()
    let proseEntries = try runtime.index(source: longProse, path: "long.org", sequences: [])
    let proseElapsed = Date().timeIntervalSince(proseStart)
    check(proseEntries[1].body == String(repeating: "Text. ", count: 150_000).trimmingCharacters(in: .whitespacesAndNewlines), "Long prose changed during indexing")
    check(proseElapsed < 2, "Long prose indexing exceeded 2s: \(proseElapsed)")
    print("900 KB plain-prose indexing: \(proseElapsed)s")

    let renderer = MobileDocumentRenderer()
    renderer.prewarm()
    let warmState = await renderer.stateForTesting()
    check(warmState.hasRuntime && warmState.initializations == 1, "Prewarm must create exactly one engine")
    let coldStart = Date()
    for _ in 0..<10 {
      _ = try MobileDocumentRuntime().render(source: source, path: coffee.path, entry: coffee, sequences: [])
    }
    let coldElapsed = Date().timeIntervalSince(coldStart)
    let warmStart = Date()
    for _ in 0..<10 {
      let value = try await renderer.render(source: source, path: coffee.path, entry: coffee, sequences: [], corpusID: "a")
      check(value.html.contains("225 g"), "Warmed renderer lost content")
    }
    let warmElapsed = Date().timeIntervalSince(warmStart)
    check(warmElapsed < 1, "Ten warmed note renders exceeded the 1s regression budget")
    print("Ten note renders: fresh engines \(coldElapsed)s, warmed renderer \(warmElapsed)s")

    let changed = try await renderer.render(source: source.replacingOccurrences(of: "225 g", with: "250 g"), path: coffee.path, entry: coffee, sequences: [], corpusID: "a")
    check(changed.html.contains("250 g") && !changed.html.contains("225 g"), "A source edit reused stale HTML")
    let whole = try await renderer.render(source: source, path: coffee.path, entry: nil, sequences: [], corpusID: "a")
    check(whole.html.contains("Steep 3 minutes"), "Full note reused entry HTML")
    let changedWorkflow = try await renderer.render(source: "* READY Coffee", path: "workflow.org", entry: nil, sequences: ["READY | FINISHED"], corpusID: "b")
    check(changedWorkflow.html.contains("org2-todo"), "Changed corpus workflow was lost")
    let noWorkflow = try await renderer.render(source: "* READY Coffee", path: "workflow.org", entry: nil, sequences: [], corpusID: "b")
    check(noWorkflow.html != changedWorkflow.html, "Changed TODO definitions reused stale HTML")
    do {
      _ = try await renderer.render(source: "* Removed", path: coffee.path, entry: coffee, sequences: [], corpusID: "a")
      check(false, "Missing entries must still fail with a warm engine")
    } catch { }
    let recovered = try await renderer.render(source: source, path: coffee.path, entry: coffee, sequences: [], corpusID: "a")
    check(recovered.html.contains("225 g"), "A failed render poisoned the reusable engine")
    let beforeRelease = await renderer.stateForTesting()
    check(beforeRelease.initializations == 1, "Navigation rebuilt the JavaScript engine")
    renderer.releaseResources()
    let released = await renderer.stateForTesting()
    check(!released.hasRuntime && !released.hasCachedDocument, "Memory/background release retained notes or engine")
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await renderer.render(source: source, path: coffee.path, entry: coffee, sequences: [], corpusID: "a")
    }
    do {
      _ = try await cancelled.value
      check(false, "Cancelled rendering should throw")
    } catch is CancellationError { }
    let afterCancel = await renderer.stateForTesting()
    check(!afterCancel.hasRuntime, "A cancelled request must not start an engine")
    let shortLived = MobileDocumentRenderer(idleSeconds: 0.03)
    shortLived.prewarm()
    _ = await shortLived.stateForTesting()
    try await Task.sleep(for: .milliseconds(100))
    let idle = await shortLived.stateForTesting()
    check(!idle.hasRuntime, "Idle renderer did not release resources")
    let large = "* Large\n#+begin_src text\n" + String(repeating: "Text. ", count: 400_000) + "\n#+end_src\n"
    _ = try await renderer.render(source: large, path: "large.org", entry: nil, sequences: [], corpusID: "a")
    let oversized = await renderer.stateForTesting()
    check(!oversized.hasCachedDocument, "Oversized notes must not occupy the render cache")
    renderer.releaseResources()

    print("Mobile renderer reuse, invalidation, cancellation, memory bounds, and idle release passed")
  }
}
