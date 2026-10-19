import AppKit
import Observation
import SwiftUI

/// The appearance a theme is designed for. Themes are chosen per appearance,
/// following the light/dark pair convention used by Zed (`theme.light` /
/// `theme.dark`), VS Code (`preferredLightColorTheme` /
/// `preferredDarkColorTheme`), and Ghostty (`theme = light:X,dark:Y`). The
/// existing System / Light / Dark appearance mode decides which half of the
/// pair is active.
public enum WorkspaceThemeAppearance: String, CaseIterable, Identifiable, Sendable {
  case light
  case dark

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  public var colorScheme: ColorScheme {
    switch self {
    case .light: .light
    case .dark: .dark
    }
  }

  var nsAppearance: NSAppearance? {
    NSAppearance(named: self == .dark ? .darkAqua : .aqua)
  }
}

/// Semantic colors a theme supplies. Workspace chrome, the rendered document,
/// and the Org source editor read these roles rather than fixed system colors.
public enum WorkspaceThemeRole: String, CaseIterable, Sendable {
  case canvas
  case document
  case hairline
  case text
  case secondaryText
  case tertiaryText
  case structural
  case signal
  case sourceText
  case keyword
  case planning
  case priority
  case todo
  case done
  case tag
  case link
  case code
  case timestamp
  case comment
  case heading1
  case heading2
  case heading3
  /// Background behind panes that historically used the window color, such
  /// as the AI chat transcript. OpenOrg defaults keep the system color.
  case pane
}

public struct WorkspaceThemePalette: @unchecked Sendable {
  public var canvas: NSColor
  public var document: NSColor
  public var hairline: NSColor
  public var text: NSColor
  public var secondaryText: NSColor
  public var tertiaryText: NSColor
  public var structural: NSColor
  public var signal: NSColor
  /// Control tint. `nil` keeps the macOS accent color.
  public var accent: NSColor?
  public var sourceText: NSColor
  public var keyword: NSColor
  public var planning: NSColor
  public var priority: NSColor
  public var todo: NSColor
  public var done: NSColor
  public var tag: NSColor
  public var link: NSColor
  /// Tint behind inline code; applied at low opacity.
  public var code: NSColor
  /// Tint behind timestamps; applied at low opacity.
  public var timestamp: NSColor
  public var comment: NSColor
  /// Heading title colors. `nil` inherits the body text color.
  public var heading1: NSColor?
  public var heading2: NSColor?
  public var heading3: NSColor?
  /// Whether SwiftUI body text should adopt `text` instead of the system label color.
  public var overridesBodyText: Bool

  public func color(_ role: WorkspaceThemeRole) -> NSColor {
    switch role {
    case .canvas: canvas
    case .document: document
    case .hairline: hairline
    case .text: text
    case .secondaryText: secondaryText
    case .tertiaryText: tertiaryText
    case .structural: structural
    case .signal: signal
    case .sourceText: sourceText
    case .keyword: keyword
    case .planning: planning
    case .priority: priority
    case .todo: todo
    case .done: done
    case .tag: tag
    case .link: link
    case .code: code
    case .timestamp: timestamp
    case .comment: comment
    case .heading1: heading1 ?? text
    case .heading2: heading2 ?? text
    case .heading3: heading3 ?? text
    case .pane: overridesBodyText ? canvas : .windowBackgroundColor
    }
  }
}

public struct WorkspaceTheme: Identifiable, Sendable {
  public let id: String
  public let name: String
  /// Where the palette comes from, for example `Emacs · modus-themes`.
  public let origin: String
  public let appearance: WorkspaceThemeAppearance
  public let palette: WorkspaceThemePalette

  /// Resolve a role to a concrete sRGB color in this theme's own appearance,
  /// independent of the window it is drawn in. Used for picker previews.
  public func resolvedColor(_ role: WorkspaceThemeRole) -> NSColor {
    Self.resolve(palette.color(role), appearance: appearance)
  }

  public func resolvedAccent() -> NSColor {
    Self.resolve(palette.accent ?? .controlAccentColor, appearance: appearance)
  }

  static func resolve(_ color: NSColor, appearance: WorkspaceThemeAppearance) -> NSColor {
    var resolved = color
    (appearance.nsAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
  }
}

// MARK: - Catalog

public enum WorkspaceThemeCatalog {
  public static let defaultLightID = "openorg-paper"
  public static let defaultDarkID = "openorg-night"

  public static func themes(for appearance: WorkspaceThemeAppearance) -> [WorkspaceTheme] {
    all.filter { $0.appearance == appearance }
  }

  public static func theme(id: String) -> WorkspaceTheme? {
    all.first { $0.id == id }
  }

  /// Resolve a persisted ID for one appearance slot, falling back to the
  /// OpenOrg default when the ID is unknown or belongs to the other appearance.
  public static func theme(id: String?, for appearance: WorkspaceThemeAppearance) -> WorkspaceTheme {
    if let id, let theme = theme(id: id), theme.appearance == appearance {
      return theme
    }
    let fallbackID = appearance == .dark ? defaultDarkID : defaultLightID
    return theme(id: fallbackID)!
  }

  public static let all: [WorkspaceTheme] = [
    openOrgPaper,
    openOrgNight,
    // Light Emacs themes
    emacs(
      id: "modus-operandi", name: "Modus Operandi", origin: "Emacs · modus-themes", appearance: .light,
      bg: 0xffffff, canvas: 0xf2f2f2, fg: 0x000000, dim: 0x595959, faint: 0x7f7f7f, border: 0xc4c4c4,
      accent: 0x0031a9, signal: 0xa60000, heading: (0x000000, 0x624416, 0x193668),
      keyword: 0x531ab6, todo: 0xa60000, done: 0x006800, priority: 0x6f5500, planning: 0x8f0075,
      tag: 0x7f7f7f, link: 0x3548cf, code: 0x005e8b, timestamp: 0x0031a9, comment: 0x595959
    ),
    emacs(
      id: "leuven", name: "Leuven", origin: "Emacs · leuven-theme", appearance: .light,
      bg: 0xffffff, canvas: 0xf5f5f5, fg: 0x333333, dim: 0x6f6f6f, faint: 0x8d8d84, border: 0xdadada,
      accent: 0x006daf, signal: 0xea6300, heading: (0x3c3c3c, 0x123555, 0x005522),
      keyword: 0x0000ff, todo: 0xc0392b, done: 0x5c9a5c, priority: 0xea6300, planning: 0x006daf,
      tag: 0x9a9fa4, link: 0x006daf, code: 0x007300, timestamp: 0x8b8989, comment: 0x8d8d84
    ),
    emacs(
      id: "solarized-light", name: "Solarized Light", origin: "Emacs · solarized-theme", appearance: .light,
      bg: 0xfdf6e3, canvas: 0xeee8d5, fg: 0x586e75, dim: 0x657b83, faint: 0x93a1a1, border: 0xe0d9c4,
      accent: 0x268bd2, signal: 0xcb4b16, heading: (0xcb4b16, 0x859900, 0x268bd2),
      keyword: 0x859900, todo: 0xdc322f, done: 0x859900, priority: 0xb58900, planning: 0xd33682,
      tag: 0x93a1a1, link: 0x6c71c4, code: 0x2aa198, timestamp: 0x6c71c4, comment: 0x93a1a1
    ),
    emacs(
      id: "gruvbox-light", name: "Gruvbox Light", origin: "Emacs · gruvbox-theme", appearance: .light,
      bg: 0xfbf1c7, canvas: 0xf2e5bc, fg: 0x3c3836, dim: 0x665c54, faint: 0x928374, border: 0xe5d5ad,
      accent: 0x076678, signal: 0xaf3a03, heading: (0x076678, 0xb57614, 0x8f3f71),
      keyword: 0x9d0006, todo: 0x9d0006, done: 0x79740e, priority: 0xaf3a03, planning: 0x8f3f71,
      tag: 0x928374, link: 0x427b58, code: 0x79740e, timestamp: 0x076678, comment: 0x928374
    ),
    emacs(
      id: "spacemacs-light", name: "Spacemacs Light", origin: "Emacs · spacemacs-theme", appearance: .light,
      bg: 0xfbf8ef, canvas: 0xefeae9, fg: 0x655370, dim: 0x7e6f86, faint: 0xa094a2, border: 0xe0dad6,
      accent: 0x3a81c3, signal: 0xdc752f, heading: (0x3a81c3, 0x2d9574, 0x67b11d),
      keyword: 0x3a81c3, todo: 0xdc752f, done: 0x2d9574, priority: 0xba2f59, planning: 0x6c3163,
      tag: 0xa094a2, link: 0x3a81c3, code: 0x6c3163, timestamp: 0x2d9574, comment: 0x2aa1ae
    ),
    emacs(
      id: "doom-one-light", name: "Doom One Light", origin: "Emacs · doom-themes", appearance: .light,
      bg: 0xfafafa, canvas: 0xf0f0f0, fg: 0x383a42, dim: 0x696c77, faint: 0x9ca0a4, border: 0xdfdfdf,
      accent: 0x4078f2, signal: 0xe45649, heading: (0x4078f2, 0xa626a4, 0xb751b6),
      keyword: 0xe45649, todo: 0x50a14f, done: 0x9ca0a4, priority: 0x986801, planning: 0xa626a4,
      tag: 0x9ca0a4, link: 0x4078f2, code: 0x0184bc, timestamp: 0x4078f2, comment: 0x9ca0a4
    ),
    emacs(
      id: "catppuccin-latte", name: "Catppuccin Latte", origin: "Emacs · catppuccin-theme", appearance: .light,
      bg: 0xeff1f5, canvas: 0xe6e9ef, fg: 0x4c4f69, dim: 0x6c6f85, faint: 0x9ca0b0, border: 0xccd0da,
      accent: 0x1e66f5, signal: 0xfe640b, heading: (0xd20f39, 0xfe640b, 0xdf8e1d),
      keyword: 0x8839ef, todo: 0xd20f39, done: 0x40a02b, priority: 0xfe640b, planning: 0x8839ef,
      tag: 0x9ca0b0, link: 0x1e66f5, code: 0x179299, timestamp: 0x7287fd, comment: 0x9ca0b0
    ),
    // Dark Emacs themes
    emacs(
      id: "modus-vivendi", name: "Modus Vivendi", origin: "Emacs · modus-themes", appearance: .dark,
      bg: 0x000000, canvas: 0x1e1e1e, fg: 0xffffff, dim: 0x989898, faint: 0x7a7a7a, border: 0x303030,
      accent: 0x2fafff, signal: 0xff5f59, heading: (0xffffff, 0xd0bc00, 0x9ac8e0),
      keyword: 0xb6a0ff, todo: 0xff5f59, done: 0x44bc44, priority: 0xd0bc00, planning: 0xfeacd0,
      tag: 0x989898, link: 0x79a8ff, code: 0x00d3d0, timestamp: 0x2fafff, comment: 0x989898
    ),
    emacs(
      id: "dracula", name: "Dracula", origin: "Emacs · dracula-theme", appearance: .dark,
      bg: 0x282a36, canvas: 0x21222c, fg: 0xf8f8f2, dim: 0xb6b8c6, faint: 0x6272a4, border: 0x44475a,
      accent: 0xbd93f9, signal: 0xff79c6, heading: (0xff79c6, 0xbd93f9, 0x50fa7b),
      keyword: 0xff79c6, todo: 0xffb86c, done: 0x50fa7b, priority: 0xf1fa8c, planning: 0x8be9fd,
      tag: 0x6272a4, link: 0x8be9fd, code: 0x50fa7b, timestamp: 0xbd93f9, comment: 0x6272a4
    ),
    emacs(
      id: "nord", name: "Nord", origin: "Emacs · nord-theme", appearance: .dark,
      bg: 0x2e3440, canvas: 0x272c36, fg: 0xd8dee9, dim: 0xa5adba, faint: 0x616e88, border: 0x3b4252,
      accent: 0x88c0d0, signal: 0xd08770, heading: (0x88c0d0, 0x81a1c1, 0x8fbcbb),
      keyword: 0x81a1c1, todo: 0x88c0d0, done: 0xa3be8c, priority: 0xebcb8b, planning: 0xb48ead,
      tag: 0x616e88, link: 0x88c0d0, code: 0xa3be8c, timestamp: 0x5e81ac, comment: 0x616e88
    ),
    emacs(
      id: "gruvbox-dark", name: "Gruvbox Dark", origin: "Emacs · gruvbox-theme", appearance: .dark,
      bg: 0x282828, canvas: 0x1d2021, fg: 0xebdbb2, dim: 0xbdae93, faint: 0x928374, border: 0x3c3836,
      accent: 0x83a598, signal: 0xfe8019, heading: (0x83a598, 0xfabd2f, 0xd3869b),
      keyword: 0xfb4934, todo: 0xfb4934, done: 0xb8bb26, priority: 0xfe8019, planning: 0xd3869b,
      tag: 0x928374, link: 0x8ec07c, code: 0xb8bb26, timestamp: 0x83a598, comment: 0x928374
    ),
    emacs(
      id: "solarized-dark", name: "Solarized Dark", origin: "Emacs · solarized-theme", appearance: .dark,
      bg: 0x002b36, canvas: 0x00212b, fg: 0x93a1a1, dim: 0x839496, faint: 0x586e75, border: 0x073642,
      accent: 0x268bd2, signal: 0xcb4b16, heading: (0xcb4b16, 0x859900, 0x268bd2),
      keyword: 0x859900, todo: 0xdc322f, done: 0x859900, priority: 0xb58900, planning: 0xd33682,
      tag: 0x586e75, link: 0x6c71c4, code: 0x2aa198, timestamp: 0x6c71c4, comment: 0x586e75
    ),
    emacs(
      id: "zenburn", name: "Zenburn", origin: "Emacs · zenburn-theme", appearance: .dark,
      bg: 0x3f3f3f, canvas: 0x2b2b2b, fg: 0xdcdccc, dim: 0xb0b09e, faint: 0x7f9f7f, border: 0x4f4f4f,
      accent: 0x8cd0d3, signal: 0xdfaf8f, heading: (0xdfaf8f, 0xbfebbf, 0x7cb8bb),
      keyword: 0xf0dfaf, todo: 0xcc9393, done: 0xafd8af, priority: 0xf0dfaf, planning: 0xdc8cc3,
      tag: 0x8f8f7f, link: 0xf0dfaf, code: 0x7f9f7f, timestamp: 0x8cd0d3, comment: 0x7f9f7f
    ),
    emacs(
      id: "monokai", name: "Monokai", origin: "Emacs · monokai-theme", appearance: .dark,
      bg: 0x272822, canvas: 0x1e1f1c, fg: 0xf8f8f2, dim: 0xc0c0b5, faint: 0x75715e, border: 0x3e3d31,
      accent: 0x66d9ef, signal: 0xfd971f, heading: (0xa6e22e, 0x66d9ef, 0xe6db74),
      keyword: 0xf92672, todo: 0xf92672, done: 0xa6e22e, priority: 0xfd971f, planning: 0xae81ff,
      tag: 0x75715e, link: 0x66d9ef, code: 0xe6db74, timestamp: 0xae81ff, comment: 0x75715e
    ),
    emacs(
      id: "doom-one", name: "Doom One", origin: "Emacs · doom-themes", appearance: .dark,
      bg: 0x282c34, canvas: 0x21242b, fg: 0xbbc2cf, dim: 0x9ca3b0, faint: 0x5b6268, border: 0x3f444a,
      accent: 0x51afef, signal: 0xda8548, heading: (0x51afef, 0xc678dd, 0xa9a1e1),
      keyword: 0x51afef, todo: 0x98be65, done: 0x5b6268, priority: 0xecbe7b, planning: 0xc678dd,
      tag: 0x5b6268, link: 0x51afef, code: 0x46d9ff, timestamp: 0x51afef, comment: 0x5b6268
    ),
    emacs(
      id: "spacemacs-dark", name: "Spacemacs Dark", origin: "Emacs · spacemacs-theme", appearance: .dark,
      bg: 0x292b2e, canvas: 0x212026, fg: 0xb2b2b2, dim: 0x939393, faint: 0x686868, border: 0x3a3740,
      accent: 0x4f97d7, signal: 0xdc752f, heading: (0x4f97d7, 0x2d9574, 0x67b11d),
      keyword: 0x4f97d7, todo: 0xdc752f, done: 0x2d9574, priority: 0xce537a, planning: 0xbc6ec5,
      tag: 0x686868, link: 0x4f97d7, code: 0xbc6ec5, timestamp: 0x2d9574, comment: 0x2aa1ae
    ),
    emacs(
      id: "tokyo-night", name: "Tokyo Night", origin: "Emacs · tokyo-night", appearance: .dark,
      bg: 0x1a1b26, canvas: 0x16161e, fg: 0xc0caf5, dim: 0xa9b1d6, faint: 0x565f89, border: 0x292e42,
      accent: 0x7aa2f7, signal: 0xff9e64, heading: (0x7aa2f7, 0xbb9af7, 0x7dcfff),
      keyword: 0xbb9af7, todo: 0xf7768e, done: 0x9ece6a, priority: 0xe0af68, planning: 0xbb9af7,
      tag: 0x565f89, link: 0x7dcfff, code: 0x9ece6a, timestamp: 0x7aa2f7, comment: 0x565f89
    ),
    emacs(
      id: "catppuccin-mocha", name: "Catppuccin Mocha", origin: "Emacs · catppuccin-theme", appearance: .dark,
      bg: 0x1e1e2e, canvas: 0x181825, fg: 0xcdd6f4, dim: 0xa6adc8, faint: 0x6c7086, border: 0x313244,
      accent: 0x89b4fa, signal: 0xfab387, heading: (0xf38ba8, 0xfab387, 0xf9e2af),
      keyword: 0xcba6f7, todo: 0xf38ba8, done: 0xa6e3a1, priority: 0xfab387, planning: 0xcba6f7,
      tag: 0x6c7086, link: 0x89b4fa, code: 0x94e2d5, timestamp: 0xb4befe, comment: 0x6c7086
    ),
  ]

  /// The original OpenOrg light palette. Syntax roles keep the system colors
  /// the editor has always used so the default look is unchanged.
  static let openOrgPaper = WorkspaceTheme(
    id: defaultLightID,
    name: "Celorga Paper",
    origin: "Celorga",
    appearance: .light,
    palette: WorkspaceThemePalette(
      canvas: NSColor(srgbRed: 0.949, green: 0.941, blue: 0.914, alpha: 1),
      document: NSColor(srgbRed: 0.988, green: 0.984, blue: 0.969, alpha: 1),
      hairline: NSColor(srgbRed: 0.843, green: 0.839, blue: 0.808, alpha: 1),
      text: NSColor(deviceWhite: 0.12, alpha: 1),
      secondaryText: NSColor(deviceWhite: 0.40, alpha: 1),
      tertiaryText: NSColor(deviceWhite: 0.58, alpha: 1),
      structural: NSColor(srgbRed: 0.157, green: 0.329, blue: 0.843, alpha: 1),
      signal: NSColor(srgbRed: 0.761, green: 0.278, blue: 0.173, alpha: 1),
      accent: nil,
      sourceText: .labelColor,
      keyword: .systemPurple,
      planning: .systemOrange,
      priority: .systemOrange,
      todo: .systemBlue,
      done: .systemGreen,
      tag: .secondaryLabelColor,
      link: .controlAccentColor,
      code: .secondaryLabelColor,
      timestamp: .controlAccentColor,
      comment: .secondaryLabelColor,
      heading1: nil,
      heading2: nil,
      heading3: nil,
      overridesBodyText: false
    )
  )

  /// The original OpenOrg dark palette.
  static let openOrgNight = WorkspaceTheme(
    id: defaultDarkID,
    name: "Celorga Night",
    origin: "Celorga",
    appearance: .dark,
    palette: WorkspaceThemePalette(
      canvas: NSColor(srgbRed: 0.082, green: 0.102, blue: 0.094, alpha: 1),
      document: NSColor(srgbRed: 0.106, green: 0.129, blue: 0.122, alpha: 1),
      hairline: NSColor(srgbRed: 0.212, green: 0.251, blue: 0.235, alpha: 1),
      text: NSColor(deviceWhite: 0.92, alpha: 1),
      secondaryText: NSColor(deviceWhite: 0.68, alpha: 1),
      tertiaryText: NSColor(deviceWhite: 0.50, alpha: 1),
      structural: NSColor(srgbRed: 0.525, green: 0.639, blue: 1.000, alpha: 1),
      signal: NSColor(srgbRed: 1.000, green: 0.525, blue: 0.408, alpha: 1),
      accent: nil,
      sourceText: .labelColor,
      keyword: .systemPurple,
      planning: .systemOrange,
      priority: .systemOrange,
      todo: .systemBlue,
      done: .systemGreen,
      tag: .secondaryLabelColor,
      link: .controlAccentColor,
      code: .secondaryLabelColor,
      timestamp: .controlAccentColor,
      comment: .secondaryLabelColor,
      heading1: nil,
      heading2: nil,
      heading3: nil,
      overridesBodyText: false
    )
  )

  // swiftlint:disable:next function_parameter_count
  static func emacs(
    id: String,
    name: String,
    origin: String,
    appearance: WorkspaceThemeAppearance,
    bg: UInt32,
    canvas: UInt32,
    fg: UInt32,
    dim: UInt32,
    faint: UInt32,
    border: UInt32,
    accent: UInt32,
    signal: UInt32,
    heading: (UInt32, UInt32, UInt32),
    keyword: UInt32,
    todo: UInt32,
    done: UInt32,
    priority: UInt32,
    planning: UInt32,
    tag: UInt32,
    link: UInt32,
    code: UInt32,
    timestamp: UInt32,
    comment: UInt32
  ) -> WorkspaceTheme {
    WorkspaceTheme(
      id: id,
      name: name,
      origin: origin,
      appearance: appearance,
      palette: WorkspaceThemePalette(
        canvas: hex(canvas),
        document: hex(bg),
        hairline: hex(border),
        text: hex(fg),
        secondaryText: hex(dim),
        tertiaryText: hex(faint),
        structural: hex(accent),
        signal: hex(signal),
        accent: hex(accent),
        sourceText: hex(fg),
        keyword: hex(keyword),
        planning: hex(planning),
        priority: hex(priority),
        todo: hex(todo),
        done: hex(done),
        tag: hex(tag),
        link: hex(link),
        code: hex(code),
        timestamp: hex(timestamp),
        comment: hex(comment),
        heading1: hex(heading.0),
        heading2: hex(heading.1),
        heading3: hex(heading.2),
        overridesBodyText: true
      )
    )
  }

  static func hex(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255,
      green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255,
      alpha: 1
    )
  }
}

// MARK: - Active theme state

/// Holds the active light/dark theme pair.
///
/// SwiftUI reads colors through `trackedColor`, which touches the observable
/// theme IDs so views re-render when the pair changes and returns a color
/// instance bound to that exact pair. AppKit reads `liveColor`, a stable
/// dynamic `NSColor` resolved against the current pair at draw time; theme
/// changes redisplay open windows so text views pick up new colors.
@Observable
public final class WorkspaceThemeCenter: @unchecked Sendable {
  public static let shared = WorkspaceThemeCenter()

  public private(set) var lightThemeID = WorkspaceThemeCatalog.defaultLightID
  public private(set) var darkThemeID = WorkspaceThemeCatalog.defaultDarkID

  @ObservationIgnored private let lock = NSLock()
  @ObservationIgnored private var lightTheme = WorkspaceThemeCatalog.openOrgPaper
  @ObservationIgnored private var darkTheme = WorkspaceThemeCatalog.openOrgNight
  @ObservationIgnored private var pairColorCache: [String: NSColor] = [:]
  @ObservationIgnored private var liveColorCache: [String: NSColor] = [:]

  public init() {}

  /// Activate a light/dark pair. Unknown or mismatched IDs fall back to the
  /// OpenOrg default for that appearance.
  public func select(lightThemeID: String?, darkThemeID: String?) {
    let light = WorkspaceThemeCatalog.theme(id: lightThemeID, for: .light)
    let dark = WorkspaceThemeCatalog.theme(id: darkThemeID, for: .dark)
    let changed: Bool = lock.withLock {
      let changed = lightTheme.id != light.id || darkTheme.id != dark.id
      lightTheme = light
      darkTheme = dark
      return changed
    }
    if self.lightThemeID != light.id { self.lightThemeID = light.id }
    if self.darkThemeID != dark.id { self.darkThemeID = dark.id }
    if changed {
      if Thread.isMainThread {
        MainActor.assumeIsolated { Self.redisplayOpenWindows() }
      } else {
        DispatchQueue.main.async { Self.redisplayOpenWindows() }
      }
    }
  }

  public func theme(for appearance: WorkspaceThemeAppearance) -> WorkspaceTheme {
    lock.withLock { appearance == .dark ? darkTheme : lightTheme }
  }

  /// The theme that SwiftUI views should use, registering observation.
  public func trackedTheme(isDark: Bool) -> WorkspaceTheme {
    _ = isDark ? darkThemeID : lightThemeID
    return theme(for: isDark ? .dark : .light)
  }

  /// A SwiftUI color for `role`, re-evaluated when the active pair changes.
  public func trackedColor(_ role: WorkspaceThemeRole, opacity: Double = 1) -> Color {
    _ = lightThemeID
    _ = darkThemeID
    return Color(nsColor: pairColor(role, alpha: opacity))
  }

  /// The theme's control tint, or `nil` when the pair keeps the macOS accent.
  public func trackedAccent() -> Color? {
    _ = lightThemeID
    _ = darkThemeID
    let (light, dark) = lock.withLock { (lightTheme, darkTheme) }
    guard light.palette.accent != nil || dark.palette.accent != nil else { return nil }
    let key = "accent|\(light.id)|\(dark.id)"
    let color = cachedPairColor(key: key) {
      NSColor(name: nil) { appearance in
        let palette = Self.isDark(appearance) ? dark.palette : light.palette
        return palette.accent ?? .controlAccentColor
      }
    }
    return Color(nsColor: color)
  }

  /// Whether SwiftUI body text should adopt the theme foreground.
  public func trackedOverridesBodyText() -> Bool {
    _ = lightThemeID
    _ = darkThemeID
    return lock.withLock { lightTheme.palette.overridesBodyText || darkTheme.palette.overridesBodyText }
  }

  /// A stable dynamic color that resolves `role` against the current pair
  /// whenever AppKit draws.
  public func liveColor(_ role: WorkspaceThemeRole, alpha: CGFloat = 1) -> NSColor {
    let key = "\(role.rawValue)|\(alpha)"
    return lock.withLock {
      if let cached = liveColorCache[key] { return cached }
      let color = NSColor(name: nil) { [unowned self] appearance in
        let palette = self.theme(for: Self.isDark(appearance) ? .dark : .light).palette
        let base = palette.color(role)
        return alpha < 1 ? base.withAlphaComponent(alpha) : base
      }
      liveColorCache[key] = color
      return color
    }
  }

  private func pairColor(_ role: WorkspaceThemeRole, alpha: Double) -> NSColor {
    let (light, dark) = lock.withLock { (lightTheme, darkTheme) }
    let key = "\(role.rawValue)|\(alpha)|\(light.id)|\(dark.id)"
    return cachedPairColor(key: key) {
      NSColor(name: nil) { appearance in
        let palette = Self.isDark(appearance) ? dark.palette : light.palette
        let base = palette.color(role)
        return alpha < 1 ? base.withAlphaComponent(alpha) : base
      }
    }
  }

  private func cachedPairColor(key: String, make: () -> NSColor) -> NSColor {
    lock.withLock {
      if let cached = pairColorCache[key] { return cached }
      let color = make()
      pairColorCache[key] = color
      return color
    }
  }

  /// CSS overrides that apply the active pair to rendered HTML documents,
  /// re-evaluated when the pair changes.
  public func trackedDocumentStylesheet() -> String {
    _ = lightThemeID
    _ = darkThemeID
    let (light, dark) = lock.withLock { (lightTheme, darkTheme) }
    return WorkspaceThemeDocumentStyle.stylesheet(light: light, dark: dark)
  }

  /// CSS overrides for the HTML AI chat transcript and message documents.
  public func trackedChatStylesheet() -> String {
    _ = lightThemeID
    _ = darkThemeID
    let (light, dark) = lock.withLock { (lightTheme, darkTheme) }
    return WorkspaceThemeDocumentStyle.chatStylesheet(light: light, dark: dark)
  }

  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  @MainActor
  static func redisplayOpenWindows() {
    for window in NSApplication.shared.windows {
      guard let root = window.contentView?.superview ?? window.contentView else { continue }
      markNeedsDisplay(root)
    }
  }

  @MainActor
  private static func markNeedsDisplay(_ view: NSView) {
    view.needsDisplay = true
    for subview in view.subviews {
      markNeedsDisplay(subview)
    }
  }
}

// MARK: - Rendered HTML documents

/// Maps a theme pair onto the CSS custom properties and Org selectors of the
/// shared Org2 HTML export. The OpenOrg defaults emit nothing, so the
/// export's own light/dark palette stays authoritative for them.
public enum WorkspaceThemeDocumentStyle {
  public static let styleElementID = "org2-workspace-theme"

  public static func stylesheet(light: WorkspaceTheme, dark: WorkspaceTheme) -> String {
    pairStylesheet(light: light, dark: dark) { rules(for: $0, selectorPrefix: ":root") }
  }

  /// Document rules plus the chat transcript's cards, headers, pills, and
  /// status text. Page backgrounds stay transparent over the themed pane.
  public static func chatStylesheet(light: WorkspaceTheme, dark: WorkspaceTheme) -> String {
    pairStylesheet(light: light, dark: dark) {
      rules(for: $0, selectorPrefix: ":root") + chatRules(for: $0, selectorPrefix: ":root")
    }
  }

  static func pairStylesheet(
    light: WorkspaceTheme,
    dark: WorkspaceTheme,
    rules: (WorkspaceTheme) -> String
  ) -> String {
    var css = ""
    if light.palette.overridesBodyText {
      css += rules(light)
    }
    if dark.palette.overridesBodyText {
      css += "@media (prefers-color-scheme: dark) {\n" + rules(dark) + "}\n"
    }
    return css
  }

  static func chatRules(for theme: WorkspaceTheme, selectorPrefix r: String) -> String {
    func c(_ role: WorkspaceThemeRole) -> String { cssColor(theme.resolvedColor(role)) }
    func mix(_ role: WorkspaceThemeRole, _ percent: Int, _ base: String = "transparent") -> String {
      "color-mix(in srgb, \(c(role)) \(percent)%, \(base))"
    }
    let muted = [
      ".message-header", ".message-placeholder", ".attachment-name", ".queued-actions", ".expansion",
      ".reasoning-text", ".activity-detail", ".show-earlier", ".more-files", "#live", ".live-detail",
      ".live-elapsed", ".live-text-toggle", ".live-activity-toggle", "#status", ".start-work-source",
    ].map { "\(r) \($0)" }.joined(separator: ", ")
    return """
    \(r) body { color: \(c(.text)); }
    \(r) .message-card { background: \(c(.document)); border-color: \(c(.hairline)); }
    \(r) article.user .message-card { background: \(mix(.structural, 9, c(.document))); }
    \(r) article.match .message-card { outline-color: \(c(.structural)); }
    \(r) .avatar { color: \(c(.secondaryText)); background: \(mix(.text, 8, c(.document))); }
    \(r) .avatar.user-avatar { color: \(c(.structural)); background: \(mix(.structural, 14, c(.document))); }
    \(muted) { color: \(c(.secondaryText)); }
    \(r) .message-header strong, \(r) .detail-header, \(r) .change-summary .detail-header, \(r) .live-text { color: \(c(.text)); }
    \(r) .detail-block { border-top-color: \(c(.hairline)); }
    \(r) .context-pill { color: \(c(.link)); background: \(mix(.link, 10)); border-color: \(mix(.link, 35)); }
    \(r) .system-badge { color: \(c(.planning)); background: \(mix(.planning, 14)); }
    \(r) .queued-badge { background: \(mix(.text, 10)); }
    \(r) .attachment-preview { border-color: \(c(.hairline)); background: \(c(.canvas)); }
    \(r) button:hover { background: \(mix(.text, 10)); }
    \(r) .icon-button.copied, \(r) .insertions { color: \(c(.done)); }
    \(r) .deletions { color: \(c(.todo)); }
    \(r) #latest { background: \(c(.document)); border-color: \(c(.hairline)); }
    \(r) .live-stop { background: \(mix(.text, 8)); }

    """
  }

  static func rules(for theme: WorkspaceTheme, selectorPrefix root: String) -> String {
    func c(_ role: WorkspaceThemeRole) -> String { cssColor(theme.resolvedColor(role)) }
    func mix(_ role: WorkspaceThemeRole, _ percent: Int) -> String {
      "color-mix(in srgb, \(c(role)) \(percent)%, transparent)"
    }
    return """
    \(root) {
      --org2-text: \(c(.text));
      --org2-muted: \(c(.secondaryText));
      --org2-faint: \(mix(.structural, 9));
      --org2-rule: \(c(.hairline));
      --org2-code: \(c(.canvas));
      --org2-surface: \(c(.document));
      --org2-elevated-surface: color-mix(in srgb, \(c(.document)) 94%, \(c(.text)));
      --org2-link: \(c(.link));
      --org2-accent: \(c(.structural));
      --org2-signal: \(c(.signal));
      --org2-success: \(c(.done));
      --org2-chart-axis: \(c(.tertiaryText));
      --org2-chart-grid: \(c(.hairline));
      --org2-chart-mark: \(c(.structural));
      --org2-chart-label: \(c(.secondaryText));
      --org2-chart-title: \(c(.text));
      --org2-chart-surface: \(c(.document));
    \(chartSeriesVariables(for: theme))}
    \(root), \(root) body { background: \(c(.document)); }
    \(root) h1 { color: \(c(.heading1)); }
    \(root) h2 { color: \(c(.heading2)); }
    \(root) h3 { color: \(c(.heading3)); }
    \(root) .org2-todo { color: \(c(.todo)); background: \(mix(.todo, 13)); }
    \(root) .org2-todo.todo-done { color: \(c(.done)); background: \(mix(.done, 13)); }
    \(root) .org2-todo.todo-canceled, \(root) .org2-todo.todo-cancelled { color: \(c(.tertiaryText)); background: \(mix(.tertiaryText, 10)); }
    \(root) .org2-priority { color: \(c(.priority)); }
    \(root) .org2-planning-kind { color: \(c(.planning)); }
    \(root) .org2-tag { color: \(c(.tag)); }
    \(root) :not(pre) > code { color: \(c(.code)); }
    \(root) .org2-comment, \(root) .org2-comment-keyword { color: \(c(.comment)); }

    """
  }

  /// Theme roles that color chart series 2…8, after `--org2-chart-mark`
  /// (the theme's structural accent). Roles that repeat an earlier color are
  /// skipped so series stay distinguishable.
  static let chartSeriesRoles: [WorkspaceThemeRole] = [.signal, .done, .tag, .link, .priority, .planning, .todo, .keyword, .heading2]

  /// Fallbacks matching the renderer's defaults in src/export.ts.
  static let defaultChartSeries: [WorkspaceThemeAppearance: [String]] = [
    .light: ["#d9480f", "#0f9d8a", "#8e44ad", "#c2185b", "#5c8a1f", "#b7791f", "#2b6cb0"],
    .dark: ["#ff9b6a", "#4fd1c5", "#c39bf0", "#f687b3", "#9ae66e", "#f6c66b", "#7fb2f0"],
  ]

  static let chartSeriesCount = 7

  /// CSS colors for `--org2-chart-series-2` … `--org2-chart-series-8`.
  public static func chartSeriesColors(for theme: WorkspaceTheme) -> [String] {
    var used: Set<String> = [cssColor(theme.resolvedColor(.structural)), cssColor(theme.resolvedColor(.text))]
    var colors: [String] = []
    for role in chartSeriesRoles where colors.count < chartSeriesCount {
      let color = cssColor(theme.resolvedColor(role))
      if used.insert(color).inserted { colors.append(color) }
    }
    for color in defaultChartSeries[theme.appearance] ?? [] where colors.count < chartSeriesCount {
      if used.insert(color).inserted { colors.append(color) }
    }
    return colors
  }

  static func chartSeriesVariables(for theme: WorkspaceTheme) -> String {
    chartSeriesColors(for: theme).enumerated()
      .map { "  --org2-chart-series-\($0.offset + 2): \($0.element);\n" }
      .joined()
  }

  static func cssColor(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    let hex = String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    return rgb.alphaComponent < 1 ? "color-mix(in srgb, \(hex) \(Int((rgb.alphaComponent * 100).rounded()))%, transparent)" : hex
  }

  /// Place the theme stylesheet after the export's own styles and before a
  /// corpus's custom app stylesheet, so user CSS still has the last word.
  public static func injecting(_ stylesheet: String, into html: String) -> String {
    guard !stylesheet.isEmpty else { return html }
    let element = "<style id=\"\(styleElementID)\">\n\(stylesheet)</style>"
    if let range = html.range(of: "<style id=\"org2-app-user-style\">") {
      var result = html
      result.replaceSubrange(range.lowerBound..<range.lowerBound, with: element)
      return result
    }
    if let range = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) {
      var result = html
      result.replaceSubrange(range, with: element + "</head>")
      return result
    }
    return element + html
  }

  /// JavaScript that swaps the theme stylesheet in an already loaded page.
  public static func replacementScript(_ stylesheet: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [stylesheet], options: [])) ?? Data("[\"\"]".utf8)
    let literal = String(decoding: data, as: UTF8.self)
    return """
    (() => {
      const css = \(literal)[0];
      let style = document.getElementById('\(styleElementID)');
      if (!css) { style?.remove(); return; }
      if (!style) {
        style = document.createElement('style');
        style.id = '\(styleElementID)';
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = css;
    })();
    """
  }
}

// MARK: - SwiftUI helpers

private struct WorkspaceThemeRootModifier: ViewModifier {
  func body(content: Content) -> some View {
    let center = WorkspaceThemeCenter.shared
    content
      .tint(center.trackedAccent())
      .foregroundStyle(
        center.trackedOverridesBodyText()
          ? AnyShapeStyle(center.trackedColor(.text))
          : AnyShapeStyle(HierarchicalShapeStyle.primary)
      )
  }
}

extension View {
  /// Apply the active theme's control tint and body text color to a window root.
  public func workspaceThemed() -> some View {
    modifier(WorkspaceThemeRootModifier())
  }
}
