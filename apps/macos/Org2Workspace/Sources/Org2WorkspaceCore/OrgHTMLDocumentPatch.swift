import Foundation

/// Updates a rendered document in place when the file on screen re-renders.
///
/// Marking one entry DONE, rescheduling it, or moving a list item rewrites
/// the file and produces a new page. Loading that page replaced the whole
/// document: folded sections reopened, table filters reset, and every
/// decoration was rebuilt. The page instead compares the new render with the
/// last one it showed and changes only the entries that differ. Entries that
/// only moved to new source lines keep their nodes and get new line numbers.
///
/// A new page whose `<head>` differs (other scripts or stylesheets) cannot be
/// patched and is loaded normally.
enum OrgHTMLDocumentPatch {
  enum Outcome: String {
    case patched
    case unchanged
    case reload
  }

  /// Attribute that marks an entry the page changed provisionally (an entry
  /// effect or an outline drag). The next render replaces it outright.
  static let provisionalAttribute = "data-org2-provisional"

  /// The part of a page that must match for an in-place update: everything
  /// up to and including the `<body>` tag, without the layout and theme
  /// styles, which the view updates in place on its own.
  static func documentShell(of html: String) -> Substring? {
    guard let headEnd = html.range(of: "</head>", options: .caseInsensitive),
          let bodyStart = html.range(of: "<body", options: .caseInsensitive, range: headEnd.upperBound..<html.endIndex),
          let bodyTagEnd = html.range(of: ">", range: bodyStart.upperBound..<html.endIndex)
    else { return nil }
    return html[html.startIndex..<bodyTagEnd.upperBound]
  }

  static func sharesDocumentShell(_ previous: String, _ next: String) -> Bool {
    guard let lhs = documentShell(of: previous), let rhs = documentShell(of: next) else { return false }
    return removingViewStyles(lhs) == removingViewStyles(rhs)
  }

  private static func removingViewStyles(_ shell: Substring) -> String {
    var result = String(shell)
    for id in [OrgHTMLDocumentLayout.styleElementID, WorkspaceThemeDocumentStyle.styleElementID] {
      let open = "<style id=\"\(id)\">"
      while let start = result.range(of: open),
            let end = result.range(of: "</style>", range: start.upperBound..<result.endIndex) {
        result.removeSubrange(start.lowerBound..<end.upperBound)
      }
    }
    return result
  }

  static let invocation = "return window.__org2PatchDocument ? window.__org2PatchDocument(html) : 'reload';"

  /// Runs at document start in every page. It records the page as parsed,
  /// before any script decorates it, and defines
  /// `window.__org2PatchDocument(html)`, which returns `patched`,
  /// `unchanged`, or `reload`.
  static let installationScript = #"""
  (() => {
    if (window.__org2DocumentPatchInstalled) return;
    window.__org2DocumentPatchInstalled = true;

    const PROVISIONAL = 'data-org2-provisional';
    const LINE_ATTRIBUTES = ['data-org2-start-line', 'data-org2-end-line'];
    const XHTML = 'http://www.w3.org/1999/xhtml';
    // Children of these may be inserted, removed, or reordered one by one.
    const BLOCK_CONTAINERS = new Set([
      'BODY', 'MAIN', 'DIV', 'SECTION', 'ARTICLE', 'ASIDE', 'HEADER', 'FOOTER', 'NAV',
      'UL', 'OL', 'DL', 'DETAILS', 'BLOCKQUOTE'
    ]);
    // Scripts rebuild the inside of these, so they are replaced whole.
    const ATOMIC = new Set([
      'TABLE', 'PRE', 'FIGURE', 'IFRAME', 'VIDEO', 'AUDIO', 'CANVAS', 'SCRIPT', 'STYLE',
      'TEMPLATE', 'SELECT', 'TEXTAREA', 'OBJECT', 'EMBED'
    ]);

    // The last authoritative render, parsed but never shown, and the live
    // node that shows each of its elements.
    let pristine = null;
    let live = new WeakMap();

    const mapTrees = (source, target) => {
      live.set(source, target);
      const from = source.children;
      const to = target.children;
      const count = Math.min(from.length, to.length);
      for (let index = 0; index < count; index += 1) mapTrees(from[index], to[index]);
    };

    const capture = () => {
      if (!document.body) return;
      pristine = document.body.cloneNode(true);
      live = new WeakMap();
      mapTrees(pristine, document.body);
    };
    // Registered before the page's own scripts, so this runs before they
    // add buttons, grips, and table controls.
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', capture, { once: true });
    } else {
      capture();
    }

    const isLineAttribute = (name) => name === LINE_ATTRIBUTES[0] || name === LINE_ATTRIBUTES[1];

    const sameIgnoringLines = (a, b) => {
      if (a.nodeType !== b.nodeType) return false;
      if (a.nodeType !== Node.ELEMENT_NODE) return a.nodeValue === b.nodeValue;
      if (a.tagName !== b.tagName || a.namespaceURI !== b.namespaceURI) return false;
      let count = 0;
      for (const attribute of a.attributes) {
        if (isLineAttribute(attribute.name)) continue;
        count += 1;
        if (b.getAttribute(attribute.name) !== attribute.value) return false;
      }
      for (const attribute of b.attributes) {
        if (!isLineAttribute(attribute.name)) count -= 1;
      }
      if (count !== 0) return false;
      const left = a.childNodes;
      const right = b.childNodes;
      if (left.length !== right.length) return false;
      for (let index = 0; index < left.length; index += 1) {
        if (!sameIgnoringLines(left[index], right[index])) return false;
      }
      return true;
    };

    // Element positions and the non-blank text between them.
    const signature = (element) => {
      let result = '';
      for (const node of element.childNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) result += '\u0001';
        else if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim()) result += '\u0002' + node.nodeValue;
      }
      return result;
    };
    const hasText = (element) => {
      for (const node of element.childNodes) {
        if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim()) return true;
      }
      return false;
    };
    const isAtomic = (element) =>
      element.namespaceURI !== XHTML
      || ATOMIC.has(element.tagName)
      || element.classList.contains('org2-table-scroll');

    // Same content, new source lines: renumber the live nodes and keep them.
    const renumber = (before, after, target) => {
      live.set(after, target);
      for (const name of LINE_ATTRIBUTES) {
        const value = after.getAttribute(name);
        if (before.getAttribute(name) === value) continue;
        if (value === null) target.removeAttribute(name); else target.setAttribute(name, value);
      }
      const from = before.children;
      const to = after.children;
      for (let index = 0; index < from.length && index < to.length; index += 1) {
        const child = live.get(from[index]);
        if (child) renumber(from[index], to[index], child);
      }
    };

    const syncClasses = (before, after, target) => {
      const was = new Set((before || '').split(/\s+/).filter(Boolean));
      const now = new Set((after || '').split(/\s+/).filter(Boolean));
      was.forEach((name) => { if (!now.has(name)) target.classList.remove(name); });
      now.forEach((name) => { if (!was.has(name)) target.classList.add(name); });
      if (!target.getAttribute('class')) target.removeAttribute('class');
    };

    // Applies only what changed between the two renders, so state the page
    // added (an opened section, an enabled checkbox, a decoration class)
    // survives.
    const syncAttributes = (before, after, target) => {
      for (const attribute of after.attributes) {
        const previous = before.getAttribute(attribute.name);
        if (previous === attribute.value) continue;
        if (attribute.name === 'class') syncClasses(previous, attribute.value, target);
        else target.setAttribute(attribute.name, attribute.value);
        if (attribute.name === 'checked' && 'checked' in target) target.checked = true;
      }
      for (const attribute of before.attributes) {
        if (after.hasAttribute(attribute.name)) continue;
        if (attribute.name === 'class') syncClasses(attribute.value, '', target);
        else target.removeAttribute(attribute.name);
        if (attribute.name === 'checked' && 'checked' in target) target.checked = false;
      }
    };

    const detailsIn = (root) => {
      const found = root.tagName === 'DETAILS' ? [root] : [];
      return found.concat(Array.from(root.querySelectorAll('details')));
    };

    const replace = (after, target) => {
      const fresh = document.importNode(after, true);
      // Keep sections the reader opened or folded.
      const was = detailsIn(target);
      const now = detailsIn(fresh);
      if (was.length === now.length) {
        now.forEach((details, index) => { details.open = was[index].open; });
      }
      target.replaceWith(fresh);
      mapTrees(after, fresh);
    };

    let dirty = new Set();
    let provisional = new Set();

    const patchNode = (before, after, target) => {
      if (provisional.has(target) || before.tagName !== after.tagName) return replace(after, target);
      if (!dirty.has(target) && sameIgnoringLines(before, after)) return renumber(before, after, target);
      if (isAtomic(before) || !patchChildren(before, after, target)) return replace(after, target);
      syncAttributes(before, after, target);
      live.set(after, target);
    };

    // Returns false, without changing anything, when the children cannot be
    // matched; the caller then replaces the whole element.
    const patchChildren = (before, after, target) => {
      const was = Array.from(before.children);
      const now = Array.from(after.children);
      const shown = was.map((child) => live.get(child));
      const isList = BLOCK_CONTAINERS.has(before.tagName) && !hasText(before) && !hasText(after);
      if (!isList && signature(before) !== signature(after)) return false;

      const inPlace = (index) => Boolean(shown[index]) && shown[index].parentNode === target;
      const matches = (wasIndex, nowIndex) =>
        inPlace(wasIndex) && !dirty.has(shown[wasIndex]) && sameIgnoringLines(was[wasIndex], now[nowIndex]);

      let start = 0;
      while (start < was.length && start < now.length && matches(start, start)) start += 1;
      let wasEnd = was.length;
      let nowEnd = now.length;
      while (wasEnd > start && nowEnd > start && matches(wasEnd - 1, nowEnd - 1)) {
        wasEnd -= 1;
        nowEnd -= 1;
      }

      let pairwise = wasEnd - start === nowEnd - start;
      for (let index = start; pairwise && index < wasEnd; index += 1) {
        if (!inPlace(index)) pairwise = false;
      }
      if (!pairwise && !isList) return false;

      for (let index = 0; index < start; index += 1) renumber(was[index], now[index], shown[index]);
      for (let offset = 0; offset < was.length - wasEnd; offset += 1) {
        renumber(was[wasEnd + offset], now[nowEnd + offset], shown[wasEnd + offset]);
      }

      if (pairwise) {
        for (let index = start; index < wasEnd; index += 1) patchNode(was[index], now[index], shown[index]);
        return true;
      }

      // Insert, remove, or reorder: swap the changed run of children.
      const marker = document.createComment('');
      if (wasEnd < was.length) {
        target.insertBefore(marker, shown[wasEnd]);
      } else if (start > 0) {
        target.insertBefore(marker, shown[start - 1].nextSibling);
      } else {
        let first = null;
        for (let index = start; index < wasEnd && !first; index += 1) {
          if (inPlace(index)) first = shown[index];
        }
        target.insertBefore(marker, first);
      }
      for (let index = start; index < wasEnd; index += 1) {
        // A dragged entry may already sit under another parent.
        if (shown[index] && shown[index].parentNode) shown[index].remove();
      }
      for (let index = start; index < nowEnd; index += 1) {
        const fresh = document.importNode(now[index], true);
        target.insertBefore(fresh, marker);
        mapTrees(now[index], fresh);
      }
      marker.remove();
      return true;
    };

    const collectProvisional = () => {
      provisional = new Set(document.querySelectorAll('[' + PROVISIONAL + ']'));
      dirty = new Set();
      for (const element of provisional) {
        for (let node = element; node && !dirty.has(node); node = node.parentElement) dirty.add(node);
      }
    };

    const redecorate = () => {
      window.__org2InstallHeadingActions?.();
      window.__org2InstallTables?.(document);
      window.__org2InstallCharts?.(document);
    };

    window.__org2PatchDocument = (html) => {
      if (!pristine || !document.body) return 'reload';
      try {
        const next = new DOMParser().parseFromString(html, 'text/html').body;
        if (!next) return 'reload';
        collectProvisional();
        if (provisional.size === 0 && pristine.isEqualNode(next)) return 'unchanged';
        if (!patchChildren(pristine, next, document.body)) return 'reload';
        syncAttributes(pristine, next, document.body);
        live.set(next, document.body);
        pristine = next;
        redecorate();
        return 'patched';
      } catch (error) {
        return 'reload';
      } finally {
        dirty = new Set();
        provisional = new Set();
      }
    };
  })();
  """#
}
