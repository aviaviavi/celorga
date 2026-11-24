import Foundation

/// The AI destination list a corpus can carry so each Mac that opens it gets
/// the same chat destinations. It holds settings only; API keys and other
/// credentials stay in each Mac's Keychain.
enum SharedAIChatDestinations {
  static let schema = "org2:ai-chat-destinations:v1"
  static let fileName = "ai-chat-destinations.json"

  private struct Document: Codable {
    var schema: String
    var destinations: [AIChatDestinationConfiguration]
  }

  static func fileURL(corpusRoot: URL) -> URL {
    CelorgaNames.stateDirectory(corpusRoot: corpusRoot)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  static func read(from url: URL) -> [AIChatDestinationConfiguration]? {
    guard let data = try? Data(contentsOf: url),
          let document = try? JSONDecoder().decode(Document.self, from: data),
          document.schema == schema
    else { return nil }
    return document.destinations
  }

  static func write(_ destinations: [AIChatDestinationConfiguration], to url: URL) throws {
    let document = Document(
      schema: schema,
      destinations: destinations.filter(\.isEnabled).map(sanitized)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(document)
    data.append(0x0A)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if (try? Data(contentsOf: url)) == data { return }
    try data.write(to: url, options: .atomic)
  }

  /// The local list plus every shared destination it lacks, in shared order
  /// after the local ones. A shared destination whose @mention is taken
  /// locally gets a numbered mention so every destination stays addressable.
  static func merging(
    _ shared: [AIChatDestinationConfiguration],
    into local: [AIChatDestinationConfiguration]
  ) -> [AIChatDestinationConfiguration] {
    var result = local
    var ids = Set(local.map(\.id))
    var mentions = Set(local.map { $0.mention.lowercased() })
    for destination in shared where !ids.contains(destination.id) {
      var added = sanitized(destination)
      added.isEnabled = true
      added.mention = AIChatDestinationConfiguration.normalizedMention(added.mention)
      let base = added.mention
      var suffix = 1
      while mentions.contains(added.mention.lowercased()) {
        suffix += 1
        added.mention = "\(base)-\(suffix)"
      }
      ids.insert(added.id)
      mentions.insert(added.mention.lowercased())
      result.append(added)
    }
    return result
  }

  /// Drops a password embedded in an endpoint URL. A shared corpus must not
  /// carry credentials; the Keychain token remains each Mac's own.
  static func sanitized(_ destination: AIChatDestinationConfiguration) -> AIChatDestinationConfiguration {
    var copy = destination
    if var components = URLComponents(string: destination.endpoint),
       components.scheme != nil,
       components.password != nil {
      components.password = nil
      copy.endpoint = components.string ?? ""
    }
    return copy
  }
}
