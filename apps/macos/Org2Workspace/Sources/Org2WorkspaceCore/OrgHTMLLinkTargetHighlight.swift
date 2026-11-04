import Foundation

/// Briefly flashes the rendered element at a cited source line after an
/// explicit link click scrolls to it, so the line is easy to find. Link
/// resolution decides the line; this only marks it once it is on screen.
enum OrgHTMLLinkTargetHighlight {
  /// How long the flash stays visible, in seconds.
  static let duration: TimeInterval = 1

  /// The line to flash for `request`, or nil unless the request came from a
  /// link click and the page showing is the linked file, fully loaded.
  static func line(
    for request: DetailScrollRequest,
    loadedSourceFile: String?,
    isPageReady: Bool
  ) -> Int? {
    guard isPageReady,
          case .sourceLine(let line) = request.target,
          let highlightedFile = request.highlightedFile,
          let loadedSourceFile,
          standardizedPath(highlightedFile) == standardizedPath(loadedSourceFile)
    else { return nil }
    return line
  }

  /// Marks the smallest rendered element that contains `line` (a heading's
  /// title rather than its whole section). Returns whether a target exists.
  static func script(line: Int, reduceMotion: Bool) -> String {
    """
    (() => {
      const line = \(max(1, line));
      if (!document.querySelector('style[data-org2-link-target]')) {
        const style = document.createElement('style');
        style.setAttribute('data-org2-link-target', '');
        style.textContent = \(jsStringLiteral(stylesheet));
        (document.head || document.documentElement).appendChild(style);
      }
      const span = (element) =>
        Number(element.dataset.org2EndLine || element.dataset.org2StartLine || 0)
          - Number(element.dataset.org2StartLine || 0);
      const elements = Array.from(document.querySelectorAll('[data-org2-start-line]'));
      const containing = elements
        .filter((element) => {
          const start = Number(element.dataset.org2StartLine || 0);
          const end = Number(element.dataset.org2EndLine || start);
          return start <= line && end >= line;
        })
        .sort((lhs, rhs) => span(lhs) - span(rhs))[0];
      let target = containing || elements
        .filter((element) => Number(element.dataset.org2StartLine || 0) >= line)
        .sort((lhs, rhs) => Number(lhs.dataset.org2StartLine || 0) - Number(rhs.dataset.org2StartLine || 0))[0];
      if (!target) return false;
      if (target.matches('details.org2-headline, section.org2-headline')
          && Number(target.dataset.org2StartLine || 0) === line) {
        target = target.querySelector(
          ':scope > summary > :is(h1, h2, h3, h4, h5, h6), :scope > :is(h1, h2, h3, h4, h5, h6)'
        ) || target;
      }
      const flash = () => {
        clearTimeout(target.__org2LinkTargetTimer);
        target.classList.remove('org2-link-target', 'org2-link-target-still');
        void target.offsetWidth;
        target.classList.add('org2-link-target');
        if (\(reduceMotion ? "true" : "false")) target.classList.add('org2-link-target-still');
        target.__org2LinkTargetTimer = setTimeout(() => {
          target.classList.remove('org2-link-target', 'org2-link-target-still');
          if (!target.getAttribute('class')) target.removeAttribute('class');
        }, \(Int(duration * 1_000)));
      };
      // After the reveal scroll has started; timers also run off screen.
      setTimeout(flash, 50);
      return true;
    })();
    """
  }

  static let stylesheet = """
  .org2-link-target { border-radius: 4px; animation: org2-link-target 1s ease-out; }
  .org2-link-target.org2-link-target-still {
    animation: none;
    background-color: color-mix(in srgb, var(--org2-accent, #3b82f6) 22%, transparent);
  }
  @keyframes org2-link-target {
    0%, 30% { background-color: color-mix(in srgb, var(--org2-accent, #3b82f6) 26%, transparent); }
    100% { background-color: transparent; }
  }
  @media (prefers-reduced-motion: reduce) {
    .org2-link-target {
      animation: none;
      background-color: color-mix(in srgb, var(--org2-accent, #3b82f6) 22%, transparent);
    }
  }
  """

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
  }

  private static func jsStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return String(array.dropFirst().dropLast())
  }
}
