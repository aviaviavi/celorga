import AppKit
import SwiftUI

enum WorkspaceDesign {
  static let cornerRadius: CGFloat = 11
  static let controlRadius: CGFloat = 7
  static let contentInset: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 8
  static let headerHorizontalInset: CGFloat = 16
  static let headerVerticalInset: CGFloat = 11
  /// Shared height of the title row in every pane header (surface headers and
  /// the document detail header), so adjacent panes line up. Fits a headline
  /// title over one caption line, or a small control strip.
  static let paneHeaderRowHeight: CGFloat = 34
  static let selectionMarkerGutterWidth: CGFloat = 22
  static let selectionMarkerVerticalOffset: CGFloat = -1

  // AppKit's semantic label colors can become extremely faint when a hosted
  // editor hierarchy is treated as inactive. Keep document chrome and source
  // text tied to the current appearance, not window activation.
  //
  // Surfaces and text follow the active light/dark theme pair (see
  // WorkspaceTheme.swift). The OpenOrg default pair mirrors the restrained,
  // warm editorial palette used by the Org2 site.
  static var stablePrimaryNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.text) }
  static var stableSecondaryNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.secondaryText) }
  static var stableTertiaryNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.tertiaryText) }
  static var canvasNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.canvas) }
  static var documentNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.document) }
  static var structuralNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.structural) }
  static var signalNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.signal) }
  static var hairlineNSColor: NSColor { WorkspaceThemeCenter.shared.liveColor(.hairline) }

  static var primaryText: Color { themed(.text) }
  static var secondaryText: Color { themed(.secondaryText) }
  static var tertiaryText: Color { themed(.tertiaryText) }
  static var structuralAccent: Color { themed(.structural) }
  static var signalAccent: Color { themed(.signal) }

  static func themed(_ role: WorkspaceThemeRole, opacity: Double = 1) -> Color {
    WorkspaceThemeCenter.shared.trackedColor(role, opacity: opacity)
  }

  /// Heading title style. The OpenOrg pair keeps body-colored headings;
  /// imported themes use their outline level colors.
  static func headingStyle(level: Int) -> AnyShapeStyle {
    guard WorkspaceThemeCenter.shared.trackedOverridesBodyText() else {
      return AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
    switch level {
    case 1: return AnyShapeStyle(themed(.heading1))
    case 2: return AnyShapeStyle(themed(.heading2))
    default: return AnyShapeStyle(themed(.heading3))
    }
  }

  static var barBackground: Color {
    themed(.document)
  }

  static var surfaceBackground: Color {
    themed(.document)
  }

  static var appBackground: Color {
    themed(.canvas)
  }

  /// Behind the AI chat transcript and composer. OpenOrg defaults keep the
  /// window color; imported themes use their canvas.
  static var paneBackground: Color {
    themed(.pane)
  }

  static var subtleFill: Color {
    themed(.text, opacity: 0.045)
  }

  static var selectedFill: Color {
    structuralAccent.opacity(0.105)
  }

  static var hairline: Color {
    themed(.hairline)
  }

  static var controlFill: Color {
    themed(.text, opacity: 0.055)
  }

  static var controlHoverFill: Color {
    themed(.text, opacity: 0.085)
  }

  static var controlGroupFill: Color {
    structuralAccent.opacity(0.045)
  }

  static var controlPressedFill: Color {
    structuralAccent.opacity(0.12)
  }

  static var panelFill: Color {
    structuralAccent.opacity(0.035)
  }
}

/// A static, theme-derived wash: no timer, blur passes, or editor rasterization.
/// Decorative layers never intercept the sidebar's pointer or accessibility events.
struct WorkspaceAtmosphere: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      WorkspaceDesign.appBackground
      if !reduceTransparency {
        LinearGradient(
          colors: [WorkspaceDesign.structuralAccent.opacity(colorScheme == .dark ? 0.12 : 0.07), .clear],
          startPoint: .topLeading, endPoint: .bottomTrailing
        )
        RadialGradient(
          colors: [WorkspaceDesign.signalAccent.opacity(colorScheme == .dark ? 0.14 : 0.09), .clear],
          center: .topLeading, startRadius: 0, endRadius: 330
        )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The canonical OpenOrg artwork, shared by the sidebar and empty chat.
struct WorkspaceBrandMark: View {
  var size: CGFloat = 32
  private static let image: NSImage? = WorkspaceResources.url(forResource: "OpenOrgBrand", withExtension: "png")
    .flatMap { NSImage(contentsOf: $0) }

  var body: some View {
    if let image = Self.image {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}

enum WorkspaceSyntax {
  static let selectionMarker = "*"

  static func headingMarker(for level: Int) -> String {
    String(repeating: "*", count: min(max(level, 1), 3))
  }
}

struct WorkspaceAsteriskMarker: View {
  var level = 1
  var color: Color = WorkspaceDesign.structuralAccent
  var size: CGFloat = 11

  var body: some View {
    Text(WorkspaceSyntax.headingMarker(for: level))
      .font(.system(size: size, weight: .semibold, design: .monospaced))
      .foregroundStyle(color)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

struct WorkspaceSelectionMarker: View {
  var body: some View {
    Text(WorkspaceSyntax.selectionMarker)
      .font(.system(size: 12, weight: .bold, design: .monospaced))
      .foregroundStyle(Color.accentColor)
      .frame(width: WorkspaceDesign.selectionMarkerGutterWidth, height: 20, alignment: .center)
      .offset(y: WorkspaceDesign.selectionMarkerVerticalOffset)
      .accessibilityHidden(true)
  }
}

struct WorkspaceSelectableRowModifier: ViewModifier {
  @State private var isHovered = false
  let isSelected: Bool
  var showsSelectionMarker = true
  var leadingPadding = WorkspaceDesign.selectionMarkerGutterWidth
  var trailingPadding: CGFloat = 10
  var verticalPadding: CGFloat = 0
  var cornerRadius: CGFloat = 8
  var selectedFill = WorkspaceDesign.selectedFill

  func body(content: Content) -> some View {
    content
      .padding(.leading, leadingPadding)
      .padding(.trailing, trailingPadding)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected
          ? selectedFill
          : isHovered ? WorkspaceDesign.themed(.text, opacity: 0.035) : Color.clear,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(WorkspaceDesign.structuralAccent.opacity(0.16), lineWidth: 0.75)
        }
      }
      .overlay(alignment: .leading) {
        if isSelected && showsSelectionMarker {
          WorkspaceSelectionMarker()
        }
      }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .onHover { hovering in
        withAnimation(.easeOut(duration: 0.08)) {
          isHovered = hovering
        }
      }
  }
}

enum WorkspaceMotion {
  static let quick = Animation.easeOut(duration: 0.14)
  static let disclosure = Animation.easeInOut(duration: 0.16)
  static let action = Animation.spring(response: 0.24, dampingFraction: 0.9)
}

/// Animate only the state supplied by the caller, never an entire refresh loop.
private struct WorkspaceActionMotion<Value: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let value: Value

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : WorkspaceMotion.action, value: value)
  }
}

extension View {
  func workspaceActionMotion<Value: Equatable>(value: Value) -> some View {
    modifier(WorkspaceActionMotion(value: value))
  }
}

/// A tiny physical response that does not delay or replace the action.
struct WorkspaceQuietPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.94)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .animation(reduceMotion ? nil : WorkspaceMotion.quick, value: configuration.isPressed)
  }
}

enum WorkspaceSidebarLayout {
  static let minimumWidth: CGFloat = 180

  static func defaultWidth(for containerWidth: CGFloat) -> CGFloat {
    maximumWidth(for: containerWidth)
  }

  static func maximumWidth(for containerWidth: CGFloat) -> CGFloat {
    max(minimumWidth, containerWidth * 0.25)
  }
}

enum WorkspaceMainSplitLayout {
  // Keep the default two-pane window usable at common laptop widths. The
  // document pane remains large enough for its compact header while the chat
  // pane retains enough room for bubbles and its adaptive composer.
  static let surfaceMinimumWidth: CGFloat = 300
  static let surfaceIdealWidth: CGFloat = 440
  static let detailMinimumWidth: CGFloat = 420
  static let detailIdealWidth: CGFloat = 680
}

struct WorkspaceIconBadge: View {
  let systemImage: String
  var tint: Color = .secondary
  var fill: Color = WorkspaceDesign.subtleFill

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 24, height: 24)
      .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

enum WorkspaceActivityIndicatorSize {
  case mini
  case small
  case regular

  var diameter: CGFloat {
    switch self {
    case .mini: 10
    case .small: 14
    case .regular: 28
    }
  }

  var width: CGFloat {
    switch self {
    case .mini: 13
    case .small: 19
    case .regular: 38
    }
  }
}

enum WorkspaceActivityIndicatorStyle {
  case signal
  case typing
  case scan
}

struct WorkspaceActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var size: WorkspaceActivityIndicatorSize = .small
  var tint: Color = .accentColor
  var style: WorkspaceActivityIndicatorStyle = .signal

  @ViewBuilder
  var body: some View {
    if reduceMotion {
      Image(systemName: "ellipsis")
        .font(.system(size: max(8, size.diameter * 0.65), weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: size.width, height: size.diameter)
        .accessibilityLabel("Loading")
    } else {
      WorkspaceNativeProgressIndicator(size: size)
        .frame(width: size.width, height: size.diameter)
        .accessibilityLabel("Loading")
    }
  }
}

private struct WorkspaceNativeProgressIndicator: NSViewRepresentable {
  let size: WorkspaceActivityIndicatorSize

  func makeNSView(context: Context) -> NSProgressIndicator {
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.isIndeterminate = true
    indicator.usesThreadedAnimation = true
    indicator.controlSize = controlSize
    indicator.startAnimation(nil)
    return indicator
  }

  func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
    indicator.controlSize = controlSize
    indicator.startAnimation(nil)
  }

  static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: ()) {
    indicator.stopAnimation(nil)
  }

  private var controlSize: NSControl.ControlSize {
    switch size {
    case .mini: .mini
    case .small: .small
    case .regular: .regular
    }
  }
}

struct WorkspaceLoadingStateView: View {
  let title: String

  init(_ title: String = "Loading") {
    self.title = title
  }

  var body: some View {
    VStack(spacing: 12) {
      WorkspaceActivityIndicator(size: .regular, style: .scan)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }
}

struct KeyboardShortcutBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(WorkspaceDesign.controlFill, in: Capsule())
  }
}

struct WorkspaceActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    WorkspaceActionButtonBody(
      configuration: configuration,
      isEnabled: isEnabled
    )
  }
}

private struct WorkspaceActionButtonBody: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let configuration: ButtonStyleConfiguration
  let isEnabled: Bool
  @State private var isHovering = false

  var body: some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(isEnabled
        ? WorkspaceDesign.primaryText.opacity(configuration.isPressed ? 0.86 : 0.93)
        : WorkspaceDesign.secondaryText)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(minHeight: 26)
      .contentShape(RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
      .background(
        backgroundFill,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .opacity(isEnabled ? 1 : 0.55)
      .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.97)
      .animation(reduceMotion ? nil : WorkspaceMotion.quick, value: configuration.isPressed)
      .animation(reduceMotion ? nil : WorkspaceMotion.quick, value: isHovering)
      .onHover { isHovering = $0 }
  }

  private var backgroundFill: Color {
    if configuration.isPressed {
      return WorkspaceDesign.controlPressedFill
    }
    if isHovering {
      return WorkspaceDesign.controlHoverFill
    }
    return .clear
  }
}

struct WorkspaceControlStrip<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 1) {
      content
    }
    .padding(4)
    .background(
      LinearGradient(
        colors: [WorkspaceDesign.controlGroupFill, WorkspaceDesign.structuralAccent.opacity(0.015)],
        startPoint: .top, endPoint: .bottom
      ),
      in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
    }
  }
}

struct WorkspaceCardSurface: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .fill(WorkspaceDesign.surfaceBackground)
          .shadow(color: Color.black.opacity(0.055), radius: 4, x: 0, y: 1)
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
      }
  }
}

extension View {
  func workspaceSelectableRow(
    isSelected: Bool,
    showsSelectionMarker: Bool = true,
    leadingPadding: CGFloat = WorkspaceDesign.selectionMarkerGutterWidth,
    trailingPadding: CGFloat = 10,
    verticalPadding: CGFloat = 0,
    cornerRadius: CGFloat = 8,
    selectedFill: Color = WorkspaceDesign.selectedFill
  ) -> some View {
    modifier(WorkspaceSelectableRowModifier(
      isSelected: isSelected,
      showsSelectionMarker: showsSelectionMarker,
      leadingPadding: leadingPadding,
      trailingPadding: trailingPadding,
      verticalPadding: verticalPadding,
      cornerRadius: cornerRadius,
      selectedFill: selectedFill
    ))
  }

  func workspaceCardSurface() -> some View {
    modifier(WorkspaceCardSurface())
  }
}
