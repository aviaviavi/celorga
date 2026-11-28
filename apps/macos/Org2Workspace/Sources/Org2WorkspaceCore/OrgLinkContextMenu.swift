import AppKit
import WebKit

/// Right-click on a link in a rendered document or chat reply: Open Link,
/// Open Link in New Tab, and Copy Link. The page reports the clicked link
/// through a script message; the host builds a native menu, so the actions
/// reuse the same routing as a click and a ⌘-click.
enum OrgLinkContextMenu {
  static let messageHandlerName = "org2LinkContextMenu"

  /// What a link opens. Only these kinds get the link menu; any other link
  /// keeps the surrounding menu (or WebKit's default).
  enum Destination: Equatable {
    /// An Org link target such as `id:…`, `file:…`, or a roam title.
    case orgTarget(String)
    /// A workspace file reference with an optional line.
    case fileReference(AIChatFileReference)
    /// A Celorga chat thread.
    case chatThread(UUID)
    /// A web page or mail address.
    case web(URL)

    var opensInNewTab: Bool {
      switch self {
      case .orgTarget, .fileReference: true
      case .chatThread: false
      case .web(let url): ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      }
    }

    /// The text Copy Link puts on the pasteboard: the Org target for an
    /// Org link, the path (and line) for a file, and the URL otherwise.
    var copyText: String {
      switch self {
      case .orgTarget(let target): target
      case .fileReference(let reference): reference.line.map { "\(reference.path)::\($0)" } ?? reference.path
      case .chatThread(let id): AIChatThreadLinks.url(for: id.uuidString)
      case .web(let url): url.scheme?.lowercased() == "mailto"
        ? String(url.absoluteString.dropFirst("mailto:".count))
        : url.absoluteString
      }
    }
  }

  static func destination(forHref rawHref: String?) -> Destination? {
    guard let href = rawHref?.trimmingCharacters(in: .whitespacesAndNewlines),
          !href.isEmpty,
          let url = URL(string: href),
          let scheme = url.scheme?.lowercased()
    else { return nil }
    switch scheme {
    case AIChatFileReference.deepLinkScheme:
      if let id = AIChatThreadLinks.threadID(from: url) { return .chatThread(id) }
      if let reference = AIChatFileReference.fromDeepLinkURL(url) { return .fileReference(reference) }
      if url.host == "open-link",
         let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?.first(where: { $0.name == "target" })?.value?
           .trimmingCharacters(in: .whitespacesAndNewlines),
         !target.isEmpty {
        return .orgTarget(target)
      }
      return nil
    case "http", "https", "mailto":
      return .web(url)
    default:
      return nil
    }
  }

  enum Action: Equatable {
    case open
    case openInNewTab
    case copy
  }

  struct Item: Equatable {
    let title: String
    let symbol: String
    let action: Action
  }

  /// The link section of the menu, in order. New Tab appears only when the
  /// destination opens in a tab and the view can open tabs.
  static func items(for destination: Destination, canOpenInNewTab: Bool) -> [Item] {
    var items = [Item(title: "Open Link", symbol: "arrow.up.forward.square", action: .open)]
    if canOpenInNewTab, destination.opensInNewTab {
      items.append(Item(title: "Open Link in New Tab", symbol: "plus.square.on.square", action: .openInNewTab))
    }
    items.append(Item(title: "Copy Link", symbol: "link", action: .copy))
    return items
  }

  static func copy(_ destination: Destination, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(destination.copyText, forType: .string)
  }

  /// Native menu items that call `perform` with the chosen action. The
  /// returned handler must stay alive while the menu is open.
  @MainActor
  static func menuItems(
    for destination: Destination,
    canOpenInNewTab: Bool,
    perform: @escaping @MainActor (Action) -> Void
  ) -> (items: [NSMenuItem], handler: MenuHandler) {
    let handler = MenuHandler(perform: perform)
    let menuItems = items(for: destination, canOpenInNewTab: canOpenInNewTab).map { item in
      let menuItem = NSMenuItem(
        title: item.title,
        action: #selector(MenuHandler.performItem(_:)),
        keyEquivalent: ""
      )
      menuItem.target = handler
      menuItem.representedObject = item
      menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
      return menuItem
    }
    return (menuItems, handler)
  }

  @MainActor
  final class MenuHandler: NSObject {
    let perform: @MainActor (Action) -> Void

    init(perform: @escaping @MainActor (Action) -> Void) {
      self.perform = perform
    }

    @objc func performItem(_ sender: NSMenuItem) {
      guard let item = sender.representedObject as? Item else { return }
      perform(item.action)
    }
  }

  /// The click location in the web view's coordinates, from the window's
  /// current mouse position, or the page coordinates when there is no window.
  @MainActor
  static func menuLocation(in webView: WKWebView, pageX x: Double, pageY y: Double) -> NSPoint {
    if let window = webView.window {
      return webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    return NSPoint(x: x, y: webView.isFlipped ? y : Double(webView.bounds.height) - y)
  }

  /// Reports a right-click on an openable link with its resolved `href`, the
  /// enclosing entry's start line (0 outside an entry), and the click point.
  /// It runs before the document's entry menu handler and stops it, so the
  /// host can show one menu with the link actions above the entry actions.
  /// A right-click inside a text selection keeps the default menu.
  static let installationScript = """
  (() => {
    if (window.__org2LinkContextMenuInstalled) return;
    window.__org2LinkContextMenuInstalled = true;
    const schemes = new Set(['\(AIChatFileReference.deepLinkScheme):', 'http:', 'https:', 'mailto:']);
    document.addEventListener('contextmenu', (event) => {
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed && selection.toString().trim()) return;
      const target = event.target instanceof Element ? event.target : event.target?.parentElement;
      const link = target?.closest('a[href]');
      if (!link) return;
      let href = '';
      try { href = new URL(link.getAttribute('href'), document.baseURI).href; } catch (_) { return; }
      if (!schemes.has(new URL(href).protocol)) return;
      const entry = link.closest('details.org2-headline[data-org2-start-line]');
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit.messageHandlers.\(messageHandlerName).postMessage({
        href,
        line: entry ? Number(entry.dataset.org2StartLine || 0) : 0,
        x: event.clientX,
        y: event.clientY
      });
    }, true);
  })();
  """

  struct Request: Equatable {
    let href: String
    let destination: Destination
    let line: Int
    let x: Double
    let y: Double
  }

  static func request(fromMessageBody body: Any) -> Request? {
    guard let payload = body as? [String: Any],
          let href = payload["href"] as? String,
          let destination = destination(forHref: href)
    else { return nil }
    return Request(
      href: href,
      destination: destination,
      line: max(0, (payload["line"] as? NSNumber)?.intValue ?? 0),
      x: (payload["x"] as? NSNumber)?.doubleValue ?? 0,
      y: (payload["y"] as? NSNumber)?.doubleValue ?? 0
    )
  }
}
