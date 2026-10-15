import AppKit
import SwiftUI

/// Official brand mark for a connector profile, with an SF Symbol fallback for
/// connector types that have no bundled logo.
struct ConnectorBrandLogo: View {
  let type: String
  var size: CGFloat = 18

  var body: some View {
    if let image = Self.image(for: type) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityLabel(Text(type.capitalized))
    } else {
      Image(systemName: WorkspaceSourceCatalog.type(type)?.systemImage ?? "point.3.connected.trianglepath.dotted")
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
    }
  }

  nonisolated static func resourceName(for type: String) -> String? {
    switch type.lowercased() {
    case "slack": "SlackLogo"
    case "notion": "NotionLogo"
    default: nil
    }
  }

  @MainActor private static var cache: [String: NSImage] = [:]

  @MainActor static func image(for type: String) -> NSImage? {
    guard let name = resourceName(for: type) else { return nil }
    if let cached = cache[name] { return cached }
    let url = WorkspaceResources.url(forResource: name, withExtension: "png")
    guard let url, let image = NSImage(contentsOf: url) else { return nil }
    cache[name] = image
    return image
  }
}
