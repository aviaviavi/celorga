import Foundation

/// Reads a source file together with its `Name+NN*.swift` continuation files.
///
/// `ContentView.swift` and `WorkspaceStore.swift` are split into numbered
/// extension files so the compiler can build them in parallel. Source-shape
/// tests read the whole logical file, in the original order.
enum SplitSourceText {
  static func read(_ url: URL) throws -> String {
    let directory = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let continuations = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(base + "+") && $0.hasSuffix(".swift") }
      .sorted()
    var parts = [try String(contentsOf: url, encoding: .utf8)]
    for name in continuations {
      parts.append(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
    }
    return parts.joined(separator: "\n")
  }
}
