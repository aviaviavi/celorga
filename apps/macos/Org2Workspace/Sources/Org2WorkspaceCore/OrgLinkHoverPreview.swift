import Foundation

/// A short, read-only excerpt shown when hovering a link in a rendered
/// document. Internal targets are excerpted from the target file on demand
/// (cached in memory per file revision); web links show the URL and the
/// link's own description and are never fetched.
struct OrgLinkHoverPreview: Equatable, Sendable {
  let title: String
  let location: String
  let excerpt: String

  static let maximumExcerptLines = 8
  static let maximumExcerptCharacters = 520
  /// Files larger than this are not read for a hover preview.
  static let maximumFileBytes = 4 * 1024 * 1024

  /// Builds a preview starting at `line` (1-based). For an Org heading the
  /// heading text becomes the title and its body (minus drawers and planning
  /// lines) becomes the excerpt, stopping at the next heading of the same or a
  /// higher level. For other lines, the following lines are excerpted.
  static func make(text: String, line requestedLine: Int?, fileName: String, relativePath: String) -> OrgLinkHoverPreview {
    let lines = text.components(separatedBy: "\n")
    var start = max(0, (requestedLine ?? 1) - 1)
    if start >= lines.count { start = 0 }

    var title = fileName
    var bodyStart = start
    var headingLevel: Int?
    if let level = headingDepth(lines[start]) {
      headingLevel = level
      title = headingTitle(lines[start], level: level)
      bodyStart = start + 1
    } else if start == 0 {
      // File-level link: prefer #+title, and skip the leading keyword block.
      var index = 0
      while index < lines.count, lines[index].hasPrefix("#+") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        let lower = lines[index].lowercased()
        if lower.hasPrefix("#+title:") {
          let value = lines[index].dropFirst("#+title:".count).trimmingCharacters(in: .whitespaces)
          if !value.isEmpty { title = value }
        }
        index += 1
        if index > 40 { break }
      }
      // Skip a file-level property drawer.
      bodyStart = index
    }

    var excerptLines: [String] = []
    var characterCount = 0
    var inDrawer = false
    var index = bodyStart
    while index < lines.count, excerptLines.count < maximumExcerptLines, characterCount < maximumExcerptCharacters {
      let raw = lines[index]
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      index += 1
      if let depth = headingDepth(raw) {
        if let headingLevel, depth <= headingLevel { break }
        if headingLevel == nil, excerptLines.isEmpty, start == 0 {
          // A file whose body starts with headings: show the outline.
          excerptLines.append(String(repeating: "  ", count: max(0, depth - 1)) + "• " + headingTitle(raw, level: depth))
          characterCount += raw.count
          continue
        }
        excerptLines.append(String(repeating: "  ", count: max(0, depth - (headingLevel ?? 1) - 1)) + "• " + headingTitle(raw, level: depth))
        characterCount += raw.count
        continue
      }
      let upper = trimmed.uppercased()
      if upper == ":PROPERTIES:" || upper == ":LOGBOOK:" { inDrawer = true; continue }
      if inDrawer { if upper == ":END:" { inDrawer = false }; continue }
      if upper.hasPrefix("SCHEDULED:") || upper.hasPrefix("DEADLINE:") || upper.hasPrefix("CLOSED:") { continue }
      if trimmed.hasPrefix("#+") { continue }
      if trimmed.isEmpty {
        if let last = excerptLines.last, !last.isEmpty { excerptLines.append("") }
        continue
      }
      excerptLines.append(trimmed)
      characterCount += trimmed.count
    }
    while excerptLines.last?.isEmpty == true { excerptLines.removeLast() }
    var excerpt = excerptLines.joined(separator: "\n")
    if excerpt.count > maximumExcerptCharacters {
      excerpt = String(excerpt.prefix(maximumExcerptCharacters - 1)) + "…"
    }
    let location = requestedLine.map { $0 > 1 ? "\(relativePath):\($0)" : relativePath } ?? relativePath
    return OrgLinkHoverPreview(
      title: title,
      location: location,
      excerpt: excerpt.isEmpty ? "No text under this heading yet." : excerpt
    )
  }

  /// Preview for an `http`/`https` link. Uses only what the document already
  /// knows (the link description); the page is not fetched.
  static func external(url rawURL: String, label rawLabel: String?) -> OrgLinkHoverPreview? {
    let urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty
    else { return nil }
    let label = (rawLabel ?? "")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let comparableLabel = label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let labelIsURL = comparableLabel == urlString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      || comparableLabel == host.lowercased()
    let displayHost = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let title = label.isEmpty || labelIsURL ? displayHost : String(label.prefix(160))
    return OrgLinkHoverPreview(
      title: title,
      location: urlString.count > 300 ? String(urlString.prefix(299)) + "…" : urlString,
      excerpt: "Web link on \(displayHost). Celorga doesn't load the page for previews."
    )
  }

  /// File-preview cache keyed by path and line, valid while the file's size
  /// and modification date are unchanged.
  final class Cache: @unchecked Sendable {
    struct Key: Hashable { let path: String; let line: Int?; let relativePath: String }
    struct Revision: Equatable { let size: Int; let modified: Date? }
    private struct Entry { let revision: Revision; let preview: OrgLinkHoverPreview }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    func preview(for key: Key, revision: Revision) -> OrgLinkHoverPreview? {
      lock.lock(); defer { lock.unlock() }
      guard let entry = entries[key] else { return nil }
      guard entry.revision == revision else {
        entries[key] = nil
        order.removeAll { $0 == key }
        return nil
      }
      order.removeAll { $0 == key }
      order.append(key)
      return entry.preview
    }

    func store(_ preview: OrgLinkHoverPreview, for key: Key, revision: Revision) {
      lock.lock(); defer { lock.unlock() }
      if entries[key] == nil, entries.count >= capacity, let oldest = order.first {
        entries[oldest] = nil
        order.removeFirst()
      }
      entries[key] = Entry(revision: revision, preview: preview)
      order.removeAll { $0 == key }
      order.append(key)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
  }

  static let sharedCache = Cache()

  static func load(path: String, line: Int?, relativePath: String, cache: Cache = sharedCache) async -> OrgLinkHoverPreview? {
    await Task.detached(priority: .userInitiated) {
      let url = URL(fileURLWithPath: path)
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
      if size > maximumFileBytes { return nil }
      let key = Cache.Key(path: url.standardizedFileURL.path, line: line, relativePath: relativePath)
      let revision = Cache.Revision(size: size, modified: attributes?[.modificationDate] as? Date)
      if let cached = cache.preview(for: key, revision: revision) { return cached }
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let text = String(data: data, encoding: .utf8)
      else { return nil }
      let preview = make(text: text, line: line, fileName: url.deletingPathExtension().lastPathComponent, relativePath: relativePath)
      cache.store(preview, for: key, revision: revision)
      return preview
    }.value
  }

  private static func headingDepth(_ line: String) -> Int? {
    var depth = 0
    for character in line {
      if character == "*" { depth += 1; continue }
      return depth > 0 && character == " " ? depth : nil
    }
    return nil
  }

  private static let todoKeywords: Set<String> = ["TODO", "DONE", "NEXT", "WAITING", "CANCELED", "CANCELLED", "IN-PROGRESS", "HOLD", "STARTED"]

  private static func headingTitle(_ line: String, level: Int) -> String {
    var title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
    if let first = title.split(separator: " ", maxSplits: 1).first, todoKeywords.contains(String(first)) {
      title = String(title.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
    }
    if title.hasPrefix("[#"), title.count >= 4, title[title.index(title.startIndex, offsetBy: 3)] == "]" {
      title = String(title.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }
    // Drop trailing :tags:
    if let range = title.range(of: #"\s+:[\w@#%:]+:$"#, options: .regularExpression) {
      title.removeSubrange(range)
    }
    return title.isEmpty ? "Untitled heading" : title
  }

  /// JSON payload consumed by `installationScript`'s `__org2ShowLinkPreview`.
  var scriptPayload: String {
    let object: [String: String] = ["title": title, "location": location, "excerpt": excerpt]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8)
    else { return "null" }
    return json
  }

  static let messageHandlerName = "org2LinkHover"

  /// Hover a workspace link for ~450 ms to request a preview; leaving the link
  /// or scrolling hides it. The popover is plain DOM text, never HTML.
  static let installationScript = """
  (() => {
    if (window.__org2LinkPreviewInstalled) return;
    window.__org2LinkPreviewInstalled = true;
    let timer = null;
    let token = 0;
    let anchor = null;
    let pop = null;
    const style = document.createElement('style');
    style.textContent = `
      .org2-link-preview { position: absolute; z-index: 2147483000; max-width: 420px; min-width: 220px;
        padding: 10px 12px; border-radius: 10px; font: 12px/1.45 -apple-system, system-ui, sans-serif;
        background: color-mix(in srgb, Canvas 96%, CanvasText 4%); color: CanvasText;
        border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
        box-shadow: 0 8px 28px rgba(0,0,0,.18); pointer-events: none; opacity: 0; transition: opacity .12s ease; }
      .org2-link-preview.visible { opacity: 1; }
      .org2-link-preview .t { font-weight: 600; font-size: 13px; margin-bottom: 2px; }
      .org2-link-preview .l { opacity: .6; font-size: 11px; margin-bottom: 6px; font-family: ui-monospace, monospace; }
      .org2-link-preview .x { white-space: pre-wrap; opacity: .9; }
      .org2-link-preview .h { opacity: .5; font-size: 10.5px; margin-top: 8px; }`;
    document.documentElement.appendChild(style);
    const hide = () => {
      clearTimeout(timer); timer = null; token += 1;
      if (anchor && anchor.dataset.org2Title !== undefined) {
        anchor.setAttribute('title', anchor.dataset.org2Title);
        delete anchor.dataset.org2Title;
      }
      anchor = null;
      if (pop) { pop.remove(); pop = null; }
    };
    const previewLink = (target) => {
      const element = target instanceof Element ? target : target?.parentElement;
      const link = element?.closest('a[href^="org2-workspace://open-link"], a[href^="http://"], a[href^="https://"]');
      return link || null;
    };
    document.addEventListener('mouseover', (event) => {
      const link = previewLink(event.target);
      if (!link || link === anchor) return;
      hide();
      anchor = link;
      const external = !link.href.startsWith('org2-workspace:');
      if (external && link.hasAttribute('title')) {
        // The popover replaces the native tooltip for web links.
        link.dataset.org2Title = link.getAttribute('title');
        link.removeAttribute('title');
      }
      const current = token;
      timer = setTimeout(() => {
        if (current !== token) return;
        let target = '';
        if (external) {
          target = link.href;
        } else {
          try { target = new URL(link.href).searchParams.get('target') || ''; } catch (_) { return; }
        }
        if (!target) return;
        const label = external ? (link.textContent || '').slice(0, 300) : '';
        window.webkit.messageHandlers.org2LinkHover.postMessage({ target, token: current, label });
      }, 450);
    }, true);
    document.addEventListener('mouseout', (event) => {
      if (!anchor) return;
      const next = event.relatedTarget;
      if (next instanceof Node && anchor.contains(next)) return;
      hide();
    }, true);
    window.addEventListener('scroll', hide, { passive: true });
    document.addEventListener('mousedown', hide, true);
    window.__org2ShowLinkPreview = (requestToken, preview) => {
      if (requestToken !== token || !anchor || !preview) return;
      if (pop) pop.remove();
      pop = document.createElement('div');
      pop.className = 'org2-link-preview';
      const title = document.createElement('div'); title.className = 't'; title.textContent = preview.title;
      const location = document.createElement('div'); location.className = 'l'; location.textContent = preview.location;
      const excerpt = document.createElement('div'); excerpt.className = 'x'; excerpt.textContent = preview.excerpt;
      const hint = document.createElement('div'); hint.className = 'h'; hint.textContent = anchor.href.startsWith('org2-workspace:') ? 'Click to open · ⌘-click to open in a new tab' : 'Click to open';
      pop.append(title, location, excerpt, hint);
      document.body.appendChild(pop);
      const rect = anchor.getBoundingClientRect();
      const width = pop.offsetWidth, height = pop.offsetHeight;
      let left = rect.left + window.scrollX;
      left = Math.max(window.scrollX + 8, Math.min(left, window.scrollX + window.innerWidth - width - 12));
      let top = rect.bottom + window.scrollY + 6;
      if (rect.bottom + height + 12 > window.innerHeight) top = rect.top + window.scrollY - height - 6;
      pop.style.left = left + 'px';
      pop.style.top = Math.max(window.scrollY + 4, top) + 'px';
      requestAnimationFrame(() => pop && pop.classList.add('visible'));
    };
  })();
  """
}
