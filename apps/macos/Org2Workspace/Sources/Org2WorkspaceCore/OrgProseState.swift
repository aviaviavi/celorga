import Foundation

// Prose mode keeps its reversible state in one Org comment block inside the
// document it describes:
//
//   #+BEGIN_COMMENT
//   ORG2_PROSE_STATE_V1
//   {"alternatives":[...],"ghosts":[...],"overflow":[...],"version":1}
//   #+END_COMMENT
//
// The payload is compact JSON with sorted keys, so it is always a single
// physical line that can never be mistaken for Org structure. Unknown fields
// at any level are kept and written back.

/// A JSON value that remembers integers separately so unknown future fields
/// round-trip without changing representation.
enum OrgProseJSON: Equatable, Sendable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([OrgProseJSON])
  case object([String: OrgProseJSON])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([OrgProseJSON].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: OrgProseJSON].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

struct OrgProseStateError: Error, Equatable, LocalizedError {
  let reason: String
  var errorDescription: String? { reason }
}

enum OrgProseStateFormat {
  static let markerPrefix = "ORG2_PROSE_STATE_V"
  /// Marker prefixes accepted when reading, Celorga first. Writers keep `markerPrefix`.
  static let markerPrefixes = [CelorgaNames.celorgaName(markerPrefix), markerPrefix]
  static let marker = "ORG2_PROSE_STATE_V1"
  static let beginLine = "#+BEGIN_COMMENT"
  static let endLine = "#+END_COMMENT"
  static let version = 1
  /// UTF-16 units of context kept on each side of an anchor.
  static let contextLimit = 48
  static let originalOrigin = "original"
  static let authorOrigin = "author"
  /// A version returned by an explicit, user-initiated model request.
  static let aiOrigin = "ai"

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  static func newID() -> String {
    UUID().uuidString.lowercased()
  }
}

// MARK: - Records

/// Locates a fragment by its text plus bounded surrounding context. The raw
/// offset is only a cached hint used to break ties.
struct OrgProseAnchor: Equatable, Sendable {
  var text: String
  var prefix: String
  var suffix: String
  var offset: Int?
  var extra: [String: OrgProseJSON] = [:]

  /// Captures `range` of `body` (the document without its state block).
  static func make(in body: NSString, range: NSRange) -> OrgProseAnchor {
    OrgProseAnchor(
      text: body.substring(with: range),
      prefix: context(in: body, before: range.location),
      suffix: context(in: body, after: NSMaxRange(range)),
      offset: range.location
    )
  }

  /// Captures the gap at `location` for text that was removed from `body`.
  static func gap(in body: NSString, at location: Int, removedText: String) -> OrgProseAnchor {
    OrgProseAnchor(
      text: removedText,
      prefix: context(in: body, before: location),
      suffix: context(in: body, after: location),
      offset: location
    )
  }

  static func context(
    in body: NSString,
    before location: Int,
    limit: Int = OrgProseStateFormat.contextLimit
  ) -> String {
    var start = max(0, location - limit)
    if start > 0, start < body.length {
      let sequence = body.rangeOfComposedCharacterSequence(at: start)
      if sequence.location < start { start = NSMaxRange(sequence) }
    }
    guard start < location else { return "" }
    return body.substring(with: NSRange(location: start, length: location - start))
  }

  static func context(
    in body: NSString,
    after location: Int,
    limit: Int = OrgProseStateFormat.contextLimit
  ) -> String {
    var end = min(body.length, location + limit)
    if end < body.length, end > location {
      let sequence = body.rangeOfComposedCharacterSequence(at: end)
      if sequence.location < end { end = sequence.location }
    }
    guard end > location else { return "" }
    return body.substring(with: NSRange(location: location, length: end - location))
  }
}

/// Where an `ai` variant came from. Every field is optional on read, and
/// unknown fields (or known fields of an unexpected type) are kept verbatim.
struct OrgProseAIProvenance: Equatable, Sendable {
  /// The provider kind, such as `anthropic` or `ollama`. Never a credential or
  /// a machine-local destination identifier.
  var provider: String?
  var model: String?
  var instruction: String?
  var createdAt: String?
  var extra: [String: OrgProseJSON] = [:]
}

struct OrgProseVariant: Equatable, Sendable {
  var id: String
  var text: String
  /// `original` for the text that was first selected, `author` for versions
  /// the user typed, `ai` for versions returned by a model request. Unknown
  /// values are preserved.
  var origin: String
  var created: String?
  /// Present on `ai` variants written by this version of Celorga.
  var provenance: OrgProseAIProvenance? = nil
  var extra: [String: OrgProseJSON] = [:]

  var isAI: Bool { origin == OrgProseStateFormat.aiOrigin }
}

struct OrgProseAlternativeSet: Equatable, Sendable {
  var id: String
  /// The anchor text is always the active variant's text.
  var anchor: OrgProseAnchor
  var activeVariantID: String
  var variants: [OrgProseVariant]
  var created: String?
  var extra: [String: OrgProseJSON] = [:]

  var activeIndex: Int? { variants.firstIndex { $0.id == activeVariantID } }
}

struct OrgProseGhost: Equatable, Sendable {
  var id: String
  var anchor: OrgProseAnchor
  var created: String?
  var extra: [String: OrgProseJSON] = [:]
}

struct OrgProseOverflowItem: Equatable, Sendable {
  var id: String
  /// `anchor.text` is the parked fragment. The prefix/suffix surround the gap
  /// it left in the body.
  var anchor: OrgProseAnchor
  var created: String?
  var extra: [String: OrgProseJSON] = [:]

  var text: String { anchor.text }
}

struct OrgProseState: Equatable, Sendable {
  var alternatives: [OrgProseAlternativeSet] = []
  var ghosts: [OrgProseGhost] = []
  var overflow: [OrgProseOverflowItem] = []
  var extra: [String: OrgProseJSON] = [:]

  var isEmpty: Bool {
    alternatives.isEmpty && ghosts.isEmpty && overflow.isEmpty && extra.isEmpty
  }
}

// MARK: - Codec

extension OrgProseState {
  static func decode(payload: String) throws -> OrgProseState {
    guard let data = payload.data(using: .utf8) else {
      throw OrgProseStateError(reason: "The prose state is not valid UTF-8.")
    }
    let value: OrgProseJSON
    do {
      value = try JSONDecoder().decode(OrgProseJSON.self, from: data)
    } catch {
      throw OrgProseStateError(reason: "The prose state is not valid JSON.")
    }
    guard case .object(let object) = value else {
      throw OrgProseStateError(reason: "The prose state is not a JSON object.")
    }
    guard case .int(OrgProseStateFormat.version)? = object["version"] else {
      throw OrgProseStateError(reason: "The prose state has an unsupported or missing version.")
    }
    var state = OrgProseState()
    state.alternatives = try Self.records(object["alternatives"], "alternatives", OrgProseAlternativeSet.init(json:))
    state.ghosts = try Self.records(object["ghosts"], "ghosts", OrgProseGhost.init(json:))
    state.overflow = try Self.records(object["overflow"], "overflow", OrgProseOverflowItem.init(json:))
    state.extra = object.filter { !Self.knownKeys.contains($0.key) }
    return state
  }

  func encodedPayload() -> String {
    var object = extra
    object["version"] = .int(OrgProseStateFormat.version)
    object["alternatives"] = .array(alternatives.map { $0.json })
    object["ghosts"] = .array(ghosts.map { $0.json })
    object["overflow"] = .array(overflow.map { $0.json })
    return OrgProseJSONWriter.string(.object(object))
  }

  private static let knownKeys: Set<String> = ["version", "alternatives", "ghosts", "overflow"]

  private static func records<T>(
    _ value: OrgProseJSON?,
    _ name: String,
    _ make: ([String: OrgProseJSON]) throws -> T
  ) throws -> [T] {
    guard let value else { return [] }
    guard case .array(let items) = value else {
      throw OrgProseStateError(reason: "The prose state field “\(name)” is malformed.")
    }
    return try items.map { item in
      guard case .object(let object) = item else {
        throw OrgProseStateError(reason: "The prose state field “\(name)” is malformed.")
      }
      return try make(object)
    }
  }
}

enum OrgProseJSONWriter {
  /// Deterministic compact JSON. U+0085, U+2028, and U+2029 are escaped so the
  /// payload stays on one line for every Foundation line-break definition.
  static func string(_ value: OrgProseJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let encoded = String(data: data, encoding: .utf8)
    else {
      return "{\"version\":1}"
    }
    return encoded
      .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }
}

private func proseString(
  _ object: [String: OrgProseJSON],
  _ key: String,
  required: Bool = true
) throws -> String? {
  switch object[key] {
  case .string(let value)?:
    return value
  case nil, .null?:
    if required {
      throw OrgProseStateError(reason: "A prose state record is missing “\(key)”.")
    }
    return nil
  default:
    throw OrgProseStateError(reason: "A prose state record has a malformed “\(key)”.")
  }
}

private func proseExtra(
  _ object: [String: OrgProseJSON],
  known: Set<String>
) -> [String: OrgProseJSON] {
  object.filter { !known.contains($0.key) }
}

private func proseSet(_ object: inout [String: OrgProseJSON], _ key: String, _ value: String?) {
  if let value { object[key] = .string(value) }
}

extension OrgProseAnchor {
  fileprivate static let knownKeys: Set<String> = ["text", "prefix", "suffix", "offset"]

  fileprivate init(json value: OrgProseJSON?) throws {
    guard case .object(let object)? = value else {
      throw OrgProseStateError(reason: "A prose state record is missing its anchor.")
    }
    let offset: Int?
    switch object["offset"] {
    case .int(let value)?: offset = value
    case nil, .null?: offset = nil
    default: throw OrgProseStateError(reason: "A prose state anchor has a malformed offset.")
    }
    self.init(
      text: try proseString(object, "text") ?? "",
      prefix: try proseString(object, "prefix", required: false) ?? "",
      suffix: try proseString(object, "suffix", required: false) ?? "",
      offset: offset,
      extra: proseExtra(object, known: Self.knownKeys)
    )
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    object["text"] = .string(text)
    object["prefix"] = .string(prefix)
    object["suffix"] = .string(suffix)
    if let offset { object["offset"] = .int(offset) }
    return .object(object)
  }
}

extension OrgProseAIProvenance {
  /// Lenient by design: provenance is descriptive, so a surprising value is
  /// kept in `extra` instead of making the whole block unreadable.
  fileprivate init(json object: [String: OrgProseJSON]) {
    var rest = object
    func take(_ key: String) -> String? {
      guard case .string(let value)? = object[key] else { return nil }
      rest.removeValue(forKey: key)
      return value
    }
    let provider = take("provider")
    let model = take("model")
    let instruction = take("instruction")
    let createdAt = take("createdAt")
    self.init(provider: provider, model: model, instruction: instruction, createdAt: createdAt, extra: rest)
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    proseSet(&object, "provider", provider)
    proseSet(&object, "model", model)
    proseSet(&object, "instruction", instruction)
    proseSet(&object, "createdAt", createdAt)
    return .object(object)
  }
}

extension OrgProseVariant {
  fileprivate static let knownKeys: Set<String> = ["id", "text", "origin", "created"]

  fileprivate init(json object: [String: OrgProseJSON]) throws {
    var extra = proseExtra(object, known: Self.knownKeys)
    var provenance: OrgProseAIProvenance?
    if case .object(let raw)? = object["provenance"] {
      provenance = OrgProseAIProvenance(json: raw)
      extra.removeValue(forKey: "provenance")
    }
    self.init(
      id: try proseString(object, "id") ?? "",
      text: try proseString(object, "text") ?? "",
      origin: try proseString(object, "origin", required: false) ?? OrgProseStateFormat.authorOrigin,
      created: try proseString(object, "created", required: false),
      provenance: provenance,
      extra: extra
    )
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    object["id"] = .string(id)
    object["text"] = .string(text)
    object["origin"] = .string(origin)
    proseSet(&object, "created", created)
    if let provenance { object["provenance"] = provenance.json }
    return .object(object)
  }
}

extension OrgProseAlternativeSet {
  fileprivate static let knownKeys: Set<String> = ["id", "anchor", "activeVariantID", "variants", "created"]

  fileprivate init(json object: [String: OrgProseJSON]) throws {
    guard case .array(let rawVariants)? = object["variants"] else {
      throw OrgProseStateError(reason: "An alternative is missing its variants.")
    }
    let variants = try rawVariants.map { raw -> OrgProseVariant in
      guard case .object(let variantObject) = raw else {
        throw OrgProseStateError(reason: "An alternative has a malformed variant.")
      }
      return try OrgProseVariant(json: variantObject)
    }
    let active = try proseString(object, "activeVariantID") ?? ""
    guard variants.contains(where: { $0.id == active }) else {
      throw OrgProseStateError(reason: "An alternative's active variant does not exist.")
    }
    self.init(
      id: try proseString(object, "id") ?? "",
      anchor: try OrgProseAnchor(json: object["anchor"]),
      activeVariantID: active,
      variants: variants,
      created: try proseString(object, "created", required: false),
      extra: proseExtra(object, known: Self.knownKeys)
    )
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    object["id"] = .string(id)
    object["anchor"] = anchor.json
    object["activeVariantID"] = .string(activeVariantID)
    object["variants"] = .array(variants.map { $0.json })
    proseSet(&object, "created", created)
    return .object(object)
  }
}

extension OrgProseGhost {
  fileprivate static let knownKeys: Set<String> = ["id", "anchor", "created"]

  fileprivate init(json object: [String: OrgProseJSON]) throws {
    self.init(
      id: try proseString(object, "id") ?? "",
      anchor: try OrgProseAnchor(json: object["anchor"]),
      created: try proseString(object, "created", required: false),
      extra: proseExtra(object, known: Self.knownKeys)
    )
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    object["id"] = .string(id)
    object["anchor"] = anchor.json
    proseSet(&object, "created", created)
    return .object(object)
  }
}

extension OrgProseOverflowItem {
  fileprivate static let knownKeys: Set<String> = ["id", "anchor", "created"]

  fileprivate init(json object: [String: OrgProseJSON]) throws {
    self.init(
      id: try proseString(object, "id") ?? "",
      anchor: try OrgProseAnchor(json: object["anchor"]),
      created: try proseString(object, "created", required: false),
      extra: proseExtra(object, known: Self.knownKeys)
    )
  }

  fileprivate var json: OrgProseJSON {
    var object = extra
    object["id"] = .string(id)
    object["anchor"] = anchor.json
    proseSet(&object, "created", created)
    return .object(object)
  }
}

// MARK: - Locating the block

enum OrgProseBlockStatus: Equatable, Sendable {
  case absent
  /// The block range covers the BEGIN line through the END line, including
  /// its line terminator when present.
  case valid(NSRange)
  /// A prose-state marker exists but cannot be safely rewritten.
  case invalid(reason: String, range: NSRange?)
}

struct OrgProseDocument: Sendable {
  let text: String
  let status: OrgProseBlockStatus
  /// Nil unless the status is `.valid` or `.absent` (then empty).
  let state: OrgProseState?

  var blockRange: NSRange? {
    if case .valid(let range) = status { return range }
    return nil
  }

  var invalidReason: String? {
    if case .invalid(let reason, _) = status { return reason }
    return nil
  }

  static func parse(_ text: String) -> OrgProseDocument {
    let ns = text as NSString
    guard OrgProseStateFormat.markerPrefixes.contains(where: {
      ns.range(of: $0, options: .literal).location != NSNotFound
    })
    else {
      return OrgProseDocument(text: text, status: .absent, state: OrgProseState())
    }

    struct Candidate {
      let begin: NSRange
      let marker: NSRange
      let version: String
    }
    var candidates: [Candidate] = []
    for markerPrefix in OrgProseStateFormat.markerPrefixes {
      var searchStart = 0
      while searchStart < ns.length {
        let hit = ns.range(
          of: markerPrefix,
          options: .literal,
          range: NSRange(location: searchStart, length: ns.length - searchStart)
        )
        guard hit.location != NSNotFound else { break }
        searchStart = NSMaxRange(hit)
        let line = ns.lineRange(for: hit)
        guard line.location > 0,
              let content = lineContent(of: line, in: ns)?
                .trimmingCharacters(in: .whitespaces),
              content.hasPrefix(markerPrefix)
        else { continue }
        let version = String(content.dropFirst(markerPrefix.count))
        guard !version.isEmpty, version.allSatisfy(\.isASCII), version.allSatisfy(\.isNumber) else {
          continue
        }
        let previous = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
        guard lineContent(of: previous, in: ns)?
          .trimmingCharacters(in: .whitespaces)
          .caseInsensitiveCompare(OrgProseStateFormat.beginLine) == .orderedSame
        else { continue }
        candidates.append(Candidate(begin: previous, marker: line, version: version))
      }
    }

    guard let candidate = candidates.first else {
      return OrgProseDocument(text: text, status: .absent, state: OrgProseState())
    }
    func invalid(_ reason: String, _ range: NSRange? = nil) -> OrgProseDocument {
      OrgProseDocument(text: text, status: .invalid(reason: reason, range: range), state: nil)
    }
    guard candidates.count == 1 else {
      return invalid("The document contains more than one prose state block.")
    }
    guard candidate.version == String(OrgProseStateFormat.version) else {
      return invalid("The prose state was written by a newer version of Celorga (V\(candidate.version)).")
    }
    let payloadStart = NSMaxRange(candidate.marker)
    guard payloadStart < ns.length else {
      return invalid("The prose state block is truncated.")
    }
    let payloadLine = ns.lineRange(for: NSRange(location: payloadStart, length: 0))
    let endStart = NSMaxRange(payloadLine)
    guard endStart < ns.length else {
      return invalid("The prose state block is not closed.")
    }
    let endLine = ns.lineRange(for: NSRange(location: endStart, length: 0))
    let blockRange = NSRange(
      location: candidate.begin.location,
      length: NSMaxRange(endLine) - candidate.begin.location
    )
    guard lineContent(of: endLine, in: ns)?
      .trimmingCharacters(in: .whitespaces)
      .caseInsensitiveCompare(OrgProseStateFormat.endLine) == .orderedSame
    else {
      return invalid("The prose state block is not a single data line followed by #+END_COMMENT.", blockRange)
    }
    let payload = (lineContent(of: payloadLine, in: ns) ?? "")
      .trimmingCharacters(in: .whitespaces)
    do {
      let state = try OrgProseState.decode(payload: payload)
      return OrgProseDocument(text: text, status: .valid(blockRange), state: state)
    } catch {
      return invalid(error.localizedDescription, blockRange)
    }
  }

  static func render(_ state: OrgProseState) -> String {
    [
      OrgProseStateFormat.beginLine,
      OrgProseStateFormat.marker,
      state.encodedPayload(),
      OrgProseStateFormat.endLine
    ].joined(separator: "\n") + "\n"
  }

  private static func lineContent(of lineRange: NSRange, in text: NSString) -> String? {
    var start = 0
    var end = 0
    var contentsEnd = 0
    text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: lineRange)
    guard contentsEnd >= start else { return nil }
    return text.substring(with: NSRange(location: start, length: contentsEnd - start))
  }
}

// MARK: - Minimal text replacement

enum OrgProseTextDiff {
  /// The smallest single replacement turning `old` into `new`, so applying an
  /// edit to the editor is one undoable change.
  static func replacement(
    from old: String,
    to new: String
  ) -> (range: NSRange, replacement: String)? {
    guard old != new else { return nil }
    let a = Array(old.utf16)
    let b = Array(new.utf16)
    let limit = min(a.count, b.count)
    var prefix = 0
    while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
      suffix += 1
    }
    if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
    if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
    let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
    return (NSRange(location: prefix, length: a.count - prefix - suffix), replacement)
  }
}
