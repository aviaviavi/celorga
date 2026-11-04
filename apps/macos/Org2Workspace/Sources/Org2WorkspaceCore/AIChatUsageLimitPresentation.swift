import AppKit
import Foundation

extension AIChatTranscriptHTML {
  /// The usage-limit state a failed message shows in place of a generic
  /// error, with the agents the person may resend it to.
  struct UsageLimit: Codable, Equatable {
    struct ResendOption: Codable, Equatable {
      let id: String
      let title: String
    }

    let title: String
    let detail: String
    let resend: [ResendOption]

    init?(
      failure: String?,
      resendDestinations: [AIChatDestinationConfiguration],
      now: Date = Date(),
      timeZone: TimeZone = .current,
      locale: Locale = .current
    ) {
      guard let limit = failure.flatMap(AIChatUsageLimit.init(failureText:)) else { return nil }
      title = limit.headline(now: now, timeZone: timeZone, locale: locale)
      detail = limit.detail
      resend = resendDestinations.map { ResendOption(id: $0.id, title: $0.title) }
    }
  }
}

/// The native menu behind "Resend to…" when more than one other agent is
/// enabled. Choosing an item is the person's explicit request.
@MainActor
final class AIChatResendMenu: NSObject {
  private let choose: (String) -> Void

  private init(choose: @escaping (String) -> Void) {
    self.choose = choose
  }

  static func makeMenu(
    options: [AIChatTranscriptHTML.UsageLimit.ResendOption],
    choose: @escaping (String) -> Void
  ) -> NSMenu {
    let handler = AIChatResendMenu(choose: choose)
    let menu = NSMenu(title: "Resend to")
    menu.autoenablesItems = false
    for option in options {
      let item = NSMenuItem(
        title: "Resend to \(option.title)",
        action: #selector(AIChatResendMenu.chooseItem(_:)),
        keyEquivalent: ""
      )
      item.target = handler
      item.representedObject = option.id
      menu.addItem(item)
    }
    // Menu items hold their targets weakly; the menu keeps the handler alive.
    objc_setAssociatedObject(menu, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return menu
  }

  @objc private func chooseItem(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    choose(id)
  }

  nonisolated(unsafe) private static var handlerKey: UInt8 = 0
}
