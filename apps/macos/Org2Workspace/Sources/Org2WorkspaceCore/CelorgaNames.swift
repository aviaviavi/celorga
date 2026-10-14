import Foundation

/// Celorga names and their pre-rename (Org2/OpenOrg) equivalents.
///
/// Phase 1 of the rename (see docs/rename/celorga.org): every reader accepts
/// both spellings, preferring the Celorga one. Writers keep editing whichever
/// config file a corpus already has; brand-new corpora get `celorga.json`.
/// Mirrors `src/brandNames.ts`.
public enum CelorgaNames {
  public static let propertyPrefix = "CELORGA_"
  public static let legacyPropertyPrefix = "ORG2_"
  public static let configFileName = "celorga.json"
  public static let legacyConfigFileName = "org2.json"
  public static let stateDirectoryName = ".celorga"
  public static let legacyStateDirectoryName = ".org2"
  public static let schemaNamespace = "celorga"
  public static let legacySchemaNamespace = "org2"
  public static let toolPrefix = "celorga_"
  public static let legacyToolPrefix = "org2_"

  /// Config file names in lookup order, Celorga first.
  public static let configFileNames = [configFileName, legacyConfigFileName]
  /// State directory names in lookup order, Celorga first.
  public static let stateDirectoryNames = [stateDirectoryName, legacyStateDirectoryName]

  // MARK: Property and environment names

  /// The Celorga spelling of a property or environment name (`ORG2_X` -> `CELORGA_X`).
  public static func celorgaName(_ name: String) -> String {
    name.hasPrefix(legacyPropertyPrefix)
      ? propertyPrefix + name.dropFirst(legacyPropertyPrefix.count)
      : name
  }

  /// The legacy spelling of a property or environment name (`CELORGA_X` -> `ORG2_X`).
  public static func legacyName(_ name: String) -> String {
    name.hasPrefix(propertyPrefix)
      ? legacyPropertyPrefix + name.dropFirst(propertyPrefix.count)
      : name
  }

  /// Both spellings, Celorga first. Names without a brand prefix are returned unchanged.
  public static func aliases(_ name: String) -> [String] {
    let modern = celorgaName(name)
    let legacy = legacyName(name)
    return modern == legacy ? [name] : [modern, legacy]
  }

  /// Expands candidate names so each branded name is tried as `CELORGA_X`, then `ORG2_X`.
  public static func withAliases(_ names: [String]) -> [String] {
    var result: [String] = []
    for name in names {
      for alias in aliases(name) where !result.contains(alias) {
        result.append(alias)
      }
    }
    return result
  }

  /// True when `candidate` is `name` in either spelling (case-insensitive).
  public static func isBrandName(_ candidate: String, _ name: String) -> Bool {
    let upper = candidate.uppercased()
    return aliases(name.uppercased()).contains(upper)
  }

  /// Reads a branded property, accepting either spelling as `name`. Returns the
  /// Celorga value when present and non-blank, otherwise the legacy value.
  /// Lookup is exact first, then case-insensitive.
  public static func property(_ name: String, in properties: [String: String]) -> String? {
    var fallback: String?
    for alias in aliases(name) {
      guard let value = lookup(alias, in: properties) else { continue }
      if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
      if fallback == nil { fallback = value }
    }
    return fallback
  }

  /// The key a branded property is actually stored under, for in-place updates.
  public static func propertyKey(_ name: String, in properties: [String: String]) -> String? {
    for alias in aliases(name) {
      if properties[alias] != nil { return alias }
      if let key = properties.keys.first(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
        return key
      }
    }
    return nil
  }

  private static func lookup(_ key: String, in properties: [String: String]) -> String? {
    if let value = properties[key] { return value }
    return properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
  }

  /// Reads a branded environment variable, preferring `CELORGA_X` over `ORG2_X`.
  public static func environment(
    _ name: String,
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    for alias in aliases(name) {
      if let value = environment[alias], !value.isEmpty { return value }
    }
    return nil
  }

  /// The environment with every `CELORGA_X` copied to `ORG2_X` where the legacy name is unset or empty.
  public static func mirroredEnvironment(_ environment: [String: String]) -> [String: String] {
    var result = environment
    for (key, value) in environment where key.hasPrefix(propertyPrefix) {
      let legacy = legacyName(key)
      if (result[legacy] ?? "").isEmpty { result[legacy] = value }
    }
    return result
  }

  /// Copies every `CELORGA_X` environment variable to `ORG2_X` when the legacy
  /// name is unset, so `ProcessInfo` reads and child processes (the bundled
  /// CLI) see the Celorga value. Call once at process start.
  public static func mirrorCelorgaEnvironment() {
    let current = ProcessInfo.processInfo.environment
    for (key, value) in mirroredEnvironment(current) where current[key] != value {
      setenv(key, value, 1)
    }
  }

  // MARK: Schema ids

  /// `celorga:kind:v1` and `org2:kind:v1` are the same record type.
  public static func schemaMatches(_ value: String?, _ id: String) -> Bool {
    guard let value else { return false }
    let suffix = schemaSuffix(id)
    return value == "\(schemaNamespace):\(suffix)" || value == "\(legacySchemaNamespace):\(suffix)"
  }

  /// Normalizes a schema id to the legacy spelling used for comparisons and writes.
  public static func legacySchemaID(_ value: String) -> String {
    value.hasPrefix(schemaNamespace + ":")
      ? legacySchemaNamespace + ":" + value.dropFirst(schemaNamespace.count + 1)
      : value
  }

  private static func schemaSuffix(_ id: String) -> Substring {
    for namespace in [schemaNamespace, legacySchemaNamespace] where id.hasPrefix(namespace + ":") {
      return id.dropFirst(namespace.count + 1)
    }
    return Substring(id)
  }

  // MARK: Corpus files

  /// Whether a file name is a workspace config file (either spelling).
  public static func isConfigFileName(_ name: String) -> Bool {
    configFileNames.contains(name)
  }

  /// The workspace config file in a directory: `celorga.json` if present, else `org2.json` if present.
  public static func configFile(in directory: URL, fileManager: FileManager = .default) -> URL? {
    for name in configFileNames {
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Whether a directory holds a workspace config file in either spelling.
  public static func hasConfigFile(in directory: URL, fileManager: FileManager = .default) -> Bool {
    configFile(in: directory, fileManager: fileManager) != nil
  }

  /// The config file to read or edit in a directory: the existing `celorga.json`
  /// or `org2.json`, otherwise `celorga.json` for a new corpus.
  public static func configFilePath(in directory: URL, fileManager: FileManager = .default) -> URL {
    configFile(in: directory, fileManager: fileManager)
      ?? directory.appendingPathComponent(configFileName, isDirectory: false)
  }

  /// Whether a directory name is a corpus state directory (either spelling).
  public static func isStateDirectoryName(_ name: String) -> Bool {
    stateDirectoryNames.contains(name)
  }

  /// The corpus state directory name: `.celorga` once it exists, otherwise `.org2`.
  public static func stateDirectoryName(corpusRoot: URL, fileManager: FileManager = .default) -> String {
    var isDirectory: ObjCBool = false
    let modern = corpusRoot.appendingPathComponent(stateDirectoryName, isDirectory: true).path
    return fileManager.fileExists(atPath: modern, isDirectory: &isDirectory) && isDirectory.boolValue
      ? stateDirectoryName
      : legacyStateDirectoryName
  }

  /// The corpus state directory: `.celorga/` once a corpus has been migrated, otherwise `.org2/`.
  public static func stateDirectory(corpusRoot: URL, fileManager: FileManager = .default) -> URL {
    corpusRoot.appendingPathComponent(
      stateDirectoryName(corpusRoot: corpusRoot, fileManager: fileManager),
      isDirectory: true
    )
  }

  /// The corpus-relative state path (`.org2/<path>` or `.celorga/<path>`).
  public static func stateRelativePath(_ path: String, corpusRoot: URL, fileManager: FileManager = .default) -> String {
    stateDirectoryName(corpusRoot: corpusRoot, fileManager: fileManager) + "/" + path
  }

  /// The corpus-relative path of a durable run record. An existing `.org` record
  /// wins, then a legacy `.org2` record; a run without a record maps to `.org`.
  public static func runRecordRelativePath(
    runID: String, corpusRoot: URL, fileManager: FileManager = .default
  ) -> String {
    let runs = stateDirectory(corpusRoot: corpusRoot, fileManager: fileManager)
      .appendingPathComponent("runs", isDirectory: true)
    let record = OrgDocumentDefaults.url(in: runs, baseName: runID, fileManager: fileManager)
    return stateRelativePath("runs/" + record.lastPathComponent, corpusRoot: corpusRoot, fileManager: fileManager)
  }

  /// Rewrites a corpus-relative path under `.celorga/` to the `.org2/` spelling
  /// so prefix checks written against the legacy layout match both.
  public static func legacyStateRelativePath(_ relativePath: String) -> String {
    if relativePath == stateDirectoryName { return legacyStateDirectoryName }
    if relativePath.hasPrefix(stateDirectoryName + "/") {
      return legacyStateDirectoryName + relativePath.dropFirst(stateDirectoryName.count)
    }
    return relativePath
  }

  /// Whether a corpus-relative path lies inside a state directory (either spelling).
  public static func isStateRelativePath(_ relativePath: String) -> Bool {
    stateDirectoryNames.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
  }

  // MARK: MCP tools

  /// Accepts `celorga_x` and `org2_x`; returns the legacy spelling used internally.
  public static func legacyToolName(_ name: String) -> String {
    name.hasPrefix(toolPrefix) ? legacyToolPrefix + name.dropFirst(toolPrefix.count) : name
  }

  public static func celorgaToolName(_ name: String) -> String {
    name.hasPrefix(legacyToolPrefix) ? toolPrefix + name.dropFirst(legacyToolPrefix.count) : name
  }
}
