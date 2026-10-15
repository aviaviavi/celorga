import Foundation

/// Crash-safe lookup for Org2WorkspaceCore's bundled resources.
///
/// Never use SwiftPM's generated `Bundle.module` in this target. Its accessor
/// calls `fatalError` when the resource bundle is missing, and it only looks
/// next to the `.app` (outside `Contents/`, where code signing forbids files)
/// or at the absolute build path on the machine that compiled it. A packaged
/// app therefore launched only on the build machine (issue #589).
///
/// The app build copies every file from `Sources/Org2WorkspaceCore/Resources`
/// into `Contents/Resources`, so `Bundle.main` serves packaged apps. Command
/// line builds, `swift run`, and tests find the SwiftPM resource bundle next to
/// the executable or test bundle instead. A missing resource returns `nil`.
enum WorkspaceResources {
  static let swiftPMBundleName = "Org2Workspace_Org2WorkspaceCore.bundle"

  private final class BundleMarker {}

  static let resourceBundles: [Bundle] = {
    var bundles: [Bundle] = [Bundle.main]
    var seen = Set<String>()
    var directories: [URL] = []
    if let resourceURL = Bundle.main.resourceURL { directories.append(resourceURL) }
    directories.append(Bundle.main.bundleURL)
    if let executableURL = Bundle.main.executableURL {
      directories.append(executableURL.deletingLastPathComponent())
    }
    let codeBundleURL = Bundle(for: BundleMarker.self).bundleURL
    directories.append(codeBundleURL)
    directories.append(codeBundleURL.deletingLastPathComponent())
    for directory in directories {
      let candidate = directory.appendingPathComponent(swiftPMBundleName).standardizedFileURL
      guard seen.insert(candidate.path).inserted,
            FileManager.default.fileExists(atPath: candidate.path),
            let bundle = Bundle(url: candidate)
      else { continue }
      bundles.append(bundle)
    }
    return bundles
  }()

  static func url(forResource name: String, withExtension ext: String?) -> URL? {
    for bundle in resourceBundles {
      if let url = bundle.url(forResource: name, withExtension: ext) { return url }
    }
    return nil
  }
}
