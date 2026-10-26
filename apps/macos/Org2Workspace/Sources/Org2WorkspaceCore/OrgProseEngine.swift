import Foundation

// Pure, deterministic Prose mode operations. Every operation takes the full
// document text and returns the full replacement text, so the editor can apply
// it as one undoable replacement and tests need no UI.

enum OrgProseResolutionFailure: Equatable, Sendable {
  /// The anchored text is no longer in the document.
  case missing
  /// More than one place matches and nothing safely breaks the tie.
  case ambiguous
  /// The text exists but its surrounding context changed.
  case contextChanged
}

enum OrgProseResolution: Equatable, Sendable {
  /// A range in full-document UTF-16 coordinates (zero length for gaps).
  case resolved(NSRange)
  case unresolved(OrgProseResolutionFailure)

  var range: NSRange? {
    if case .resolved(let range) = self { return range }
    return nil
  }
}

enum OrgProseError: Error, Equatable, LocalizedError {
  case invalidState(String)
  case emptySelection
  case selectionTouchesState
  case overlapsAlternative
  case unchangedText
  case emptyText
  case notFound(String)
  case anchorUnresolved
  case revisionTargetChanged

  var errorDescription: String? {
    switch self {
    case .invalidState(let reason):
      return "Prose actions are unavailable: \(reason) Switch to Source mode to inspect it. Nothing was changed."
    case .emptySelection:
      return "Select some text first."
    case .selectionTouchesState:
      return "The selection includes the hidden prose state. Select only prose."
    case .overlapsAlternative:
      return "The selection partly overlaps an existing alternative."
    case .unchangedText:
      return "That is the same as the current text."
    case .emptyText:
      return "Enter some text."
    case .notFound(let what):
      return what
    case .anchorUnresolved:
      return "The original location can no longer be found."
    case .revisionTargetChanged:
      return "The selected text changed while the revision was running. Nothing was changed."
    }
  }
}

/// The span captured when a revision request starts. The request runs
/// asynchronously, so the result is applied by re-resolving `anchor` (or the
/// alternative) against the document as it is when the reply arrives.
struct OrgProseRevisionTarget: Equatable, Sendable {
  /// The text to revise: the selection, or the active version of the
  /// alternative at the cursor.
  let text: String
  /// Body coordinates, like every stored anchor.
  let anchor: OrgProseAnchor
  /// Set when the revision joins an existing alternative.
  let alternativeID: String?
  /// Bounded surrounding prose sent with the request, without the state block.
  let contextBefore: String
  let contextAfter: String
}

struct OrgProseEdit: Equatable {
  let text: String
  /// Nil leaves the editor's selection alone.
  let selection: NSRange?
  let message: String
}

/// A parsed document plus coordinate helpers that treat the state block as
/// invisible.
struct OrgProseContext {
  let text: NSString
  let block: NSRange?
  let state: OrgProseState
  let body: NSString

  init(text: String) throws {
    let document = OrgProseDocument.parse(text)
    if let reason = document.invalidReason {
      throw OrgProseError.invalidState(reason)
    }
    self.text = text as NSString
    self.block = document.blockRange
    self.state = document.state ?? OrgProseState()
    if let block = document.blockRange {
      self.body = (text as NSString).replacingCharacters(in: block, with: "") as NSString
    } else {
      self.body = text as NSString
    }
  }

  func intersectsBlock(_ range: NSRange) -> Bool {
    guard let block else { return false }
    if range.length == 0 {
      return range.location > block.location && range.location < NSMaxRange(block)
    }
    return NSIntersectionRange(range, block).length > 0
  }

  /// Body-to-full for a non-empty range; nil when the range would straddle the block.
  func fullRange(fromBody range: NSRange) -> NSRange? {
    guard let block else { return range }
    let start = range.location
    let end = NSMaxRange(range)
    if start < block.location && end > block.location { return nil }
    let fullStart = start < block.location ? start : start + block.length
    return NSRange(location: fullStart, length: range.length)
  }

  func fullLocation(fromBody location: Int) -> Int {
    guard let block else { return location }
    return location <= block.location ? location : location + block.length
  }

  func bodyLocation(fromFull location: Int) -> Int {
    guard let block else { return location }
    if location <= block.location { return location }
    if location >= NSMaxRange(block) { return location - block.length }
    return block.location
  }

  // MARK: Anchor resolution

  func resolveText(_ anchor: OrgProseAnchor) -> OrgProseResolution {
    guard !anchor.text.isEmpty else { return .unresolved(.missing) }
    let candidates = Self.occurrences(of: anchor.text, in: body).compactMap { range -> (NSRange, Int)? in
      guard let full = fullRange(fromBody: range) else { return nil }
      var score = 0
      if !anchor.prefix.isEmpty, Self.prefix(anchor.prefix, endsAt: range.location, in: body) { score += 1 }
      if !anchor.suffix.isEmpty, Self.suffix(anchor.suffix, startsAt: NSMaxRange(range), in: body) { score += 1 }
      return (full, score)
    }
    guard !candidates.isEmpty else { return .unresolved(.missing) }
    let sides = (anchor.prefix.isEmpty ? 0 : 1) + (anchor.suffix.isEmpty ? 0 : 1)
    let full = candidates.filter { $0.1 == sides }
    if !full.isEmpty {
      return pick(full.map { $0.0.location }, length: anchor.text.utf16.count, anchor: anchor)
    }
    let partial = candidates.filter { $0.1 > 0 }
    if !partial.isEmpty {
      return pick(partial.map { $0.0.location }, length: anchor.text.utf16.count, anchor: anchor)
    }
    if candidates.count == 1, let offset = anchor.offset,
       bodyLocation(fromFull: candidates[0].0.location) == offset {
      return .resolved(candidates[0].0)
    }
    return .unresolved(candidates.count > 1 ? .ambiguous : .contextChanged)
  }

  func resolveInsertion(_ anchor: OrgProseAnchor) -> OrgProseResolution {
    let sides = (anchor.prefix.isEmpty ? 0 : 1) + (anchor.suffix.isEmpty ? 0 : 1)
    if sides == 0 {
      return body.length == 0 ? .resolved(NSRange(location: fullLocation(fromBody: 0), length: 0)) : .unresolved(.ambiguous)
    }
    let prefixLength = anchor.prefix.utf16.count
    let joined = Self.occurrences(of: anchor.prefix + anchor.suffix, in: body)
      .map { $0.location + prefixLength }
    if !joined.isEmpty {
      return pickInsertion(joined, anchor: anchor)
    }
    var partial: [Int] = []
    if !anchor.prefix.isEmpty {
      partial += Self.occurrences(of: anchor.prefix, in: body).map { NSMaxRange($0) }
    }
    if !anchor.suffix.isEmpty {
      partial += Self.occurrences(of: anchor.suffix, in: body).map { $0.location }
    }
    let unique = Array(Set(partial)).sorted()
    if !unique.isEmpty {
      return pickInsertion(unique, anchor: anchor)
    }
    return .unresolved(.missing)
  }

  /// Picks the single candidate (full-document locations) or breaks a tie with
  /// the cached offset. Anything else stays unresolved.
  private func pick(_ locations: [Int], length: Int, anchor: OrgProseAnchor) -> OrgProseResolution {
    if locations.count == 1 {
      return .resolved(NSRange(location: locations[0], length: length))
    }
    if let offset = anchor.offset {
      let matching = locations.filter { bodyLocation(fromFull: $0) == offset }
      if matching.count == 1 {
        return .resolved(NSRange(location: matching[0], length: length))
      }
    }
    return .unresolved(.ambiguous)
  }

  private func pickInsertion(_ bodyLocations: [Int], anchor: OrgProseAnchor) -> OrgProseResolution {
    if bodyLocations.count == 1 {
      return .resolved(NSRange(location: fullLocation(fromBody: bodyLocations[0]), length: 0))
    }
    if let offset = anchor.offset {
      let matching = bodyLocations.filter { $0 == offset }
      if matching.count == 1 {
        return .resolved(NSRange(location: fullLocation(fromBody: matching[0]), length: 0))
      }
    }
    return .unresolved(.ambiguous)
  }

  static func occurrences(of needle: String, in text: NSString) -> [NSRange] {
    guard !needle.isEmpty, text.length > 0 else { return [] }
    var result: [NSRange] = []
    var from = 0
    while from < text.length {
      let hit = text.range(
        of: needle,
        options: .literal,
        range: NSRange(location: from, length: text.length - from)
      )
      guard hit.location != NSNotFound else { break }
      result.append(hit)
      from = hit.location + 1
    }
    return result
  }

  private static func prefix(_ prefix: String, endsAt location: Int, in text: NSString) -> Bool {
    let length = prefix.utf16.count
    guard location >= length else { return false }
    return text.substring(with: NSRange(location: location - length, length: length)) == prefix
  }

  private static func suffix(_ suffix: String, startsAt location: Int, in text: NSString) -> Bool {
    let length = suffix.utf16.count
    guard location + length <= text.length else { return false }
    return text.substring(with: NSRange(location: location, length: length)) == suffix
  }

  func alternativeRanges() -> [(set: OrgProseAlternativeSet, range: NSRange)] {
    state.alternatives.compactMap { set in
      resolveText(set.anchor).range.map { (set: set, range: $0) }
    }
  }

  func ghostRanges() -> [(ghost: OrgProseGhost, range: NSRange)] {
    state.ghosts.compactMap { ghost in
      resolveText(ghost.anchor).range.map { (ghost: ghost, range: $0) }
    }
  }
}

/// Everything the UI needs to render a document's prose state.
struct OrgProseSnapshot: Equatable {
  var status: OrgProseBlockStatus = .absent
  var state = OrgProseState()
  var resolutions: [String: OrgProseResolution] = [:]

  var blockRange: NSRange? {
    // Swift 6.2's release optimizer can end the @Published snapshot borrow
    // before matching this enum when the getter is inlined into a caller.
    @inline(never) get {
      if case .valid(let range) = status { return range }
      return nil
    }
  }

  var invalidReason: String? {
    if case .invalid(let reason, _) = status { return reason }
    return nil
  }

  var isUsable: Bool { invalidReason == nil }

  func resolution(for id: String) -> OrgProseResolution {
    resolutions[id] ?? .unresolved(.missing)
  }

  static func make(for text: String) -> OrgProseSnapshot {
    let document = OrgProseDocument.parse(text)
    guard let state = document.state, document.invalidReason == nil,
          let context = try? OrgProseContext(text: text)
    else {
      return OrgProseSnapshot(status: document.status, state: OrgProseState(), resolutions: [:])
    }
    var resolutions: [String: OrgProseResolution] = [:]
    for set in state.alternatives { resolutions[set.id] = context.resolveText(set.anchor) }
    for ghost in state.ghosts { resolutions[ghost.id] = context.resolveText(ghost.anchor) }
    for item in state.overflow { resolutions[item.id] = context.resolveInsertion(item.anchor) }
    return OrgProseSnapshot(status: document.status, state: state, resolutions: resolutions)
  }

  /// The alternative set whose text contains the caret or selection.
  func alternative(containing selection: NSRange) -> (set: OrgProseAlternativeSet, range: NSRange)? {
    var best: (set: OrgProseAlternativeSet, range: NSRange)?
    for set in state.alternatives {
      guard let range = resolution(for: set.id).range,
            Self.range(range, covers: selection)
      else { continue }
      if best == nil || range.length < best!.range.length { best = (set: set, range: range) }
    }
    return best
  }

  static func range(_ range: NSRange, covers selection: NSRange) -> Bool {
    if selection.length == 0 {
      return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
    return selection.location >= range.location && NSMaxRange(selection) <= NSMaxRange(range)
  }
}

enum OrgProseEngine {
  typealias IDGenerator = () -> String

  // MARK: Alternatives

  /// Adds an author-written version for the selection. When the selection is
  /// inside an existing alternative, the version joins that alternative.
  static func addAlternative(
    to text: String,
    selection: NSRange,
    versionText: String,
    now: Date = Date(),
    makeID: IDGenerator = OrgProseStateFormat.newID
  ) throws -> OrgProseEdit {
    guard !versionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OrgProseError.emptyText
    }
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    guard !context.intersectsBlock(selection) else { throw OrgProseError.selectionTouchesState }
    let stamp = OrgProseStateFormat.timestamp(now)
    let existing = context.alternativeRanges()

    if let match = existing
      .filter({ OrgProseSnapshot.range($0.range, covers: selection) })
      .min(by: { $0.range.length < $1.range.length }) {
      var set = match.set
      let currentText = set.variants.first { $0.id == set.activeVariantID }?.text
      guard versionText != currentText else { throw OrgProseError.unchangedText }
      if let known = set.variants.first(where: { $0.text == versionText }) {
        set.activeVariantID = known.id
      } else {
        let variant = OrgProseVariant(
          id: makeID(),
          text: versionText,
          origin: OrgProseStateFormat.authorOrigin,
          created: stamp
        )
        set.variants.append(variant)
        set.activeVariantID = variant.id
      }
      return try replaceAlternative(set, at: match.range, with: versionText, in: context, message: "Added alternative")
    }

    guard selection.length > 0 else { throw OrgProseError.emptySelection }
    if existing.contains(where: { NSIntersectionRange($0.range, selection).length > 0 }) {
      throw OrgProseError.overlapsAlternative
    }
    let original = context.text.substring(with: selection)
    guard versionText != original else { throw OrgProseError.unchangedText }
    let originalVariant = OrgProseVariant(
      id: makeID(),
      text: original,
      origin: OrgProseStateFormat.originalOrigin,
      created: stamp
    )
    let authored = OrgProseVariant(
      id: makeID(),
      text: versionText,
      origin: OrgProseStateFormat.authorOrigin,
      created: stamp
    )
    let set = OrgProseAlternativeSet(
      id: makeID(),
      anchor: OrgProseAnchor(text: versionText, prefix: "", suffix: "", offset: nil),
      activeVariantID: authored.id,
      variants: [originalVariant, authored],
      created: stamp
    )
    return try replaceAlternative(set, at: selection, with: versionText, in: context, message: "Added alternative", isNew: true)
  }

  // MARK: AI revisions

  /// UTF-16 units of surrounding prose sent on each side of a revision.
  static let revisionContextLimit = 1_200

  /// Captures what a "Revise with AI" request would rewrite. Inside an
  /// alternative the whole active version is the target, matching Add
  /// Alternative; otherwise the selection must be non-empty and must not
  /// partly overlap an alternative.
  static func revisionTarget(
    in text: String,
    selection: NSRange,
    contextLimit: Int = revisionContextLimit
  ) throws -> OrgProseRevisionTarget {
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    guard !context.intersectsBlock(selection) else { throw OrgProseError.selectionTouchesState }
    let existing = context.alternativeRanges()
    let range: NSRange
    let alternativeID: String?
    if let match = existing
      .filter({ OrgProseSnapshot.range($0.range, covers: selection) })
      .min(by: { $0.range.length < $1.range.length }) {
      range = match.range
      alternativeID = match.set.id
    } else {
      guard selection.length > 0 else { throw OrgProseError.emptySelection }
      if existing.contains(where: { NSIntersectionRange($0.range, selection).length > 0 }) {
        throw OrgProseError.overlapsAlternative
      }
      range = selection
      alternativeID = nil
    }
    let selected = context.text.substring(with: range)
    guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OrgProseError.emptySelection
    }
    let bodyRange = context.bodyRange(of: range)
    return OrgProseRevisionTarget(
      text: selected,
      anchor: OrgProseAnchor.make(in: context.body, range: bodyRange),
      alternativeID: alternativeID,
      contextBefore: OrgProseAnchor.context(in: context.body, before: bodyRange.location, limit: contextLimit),
      contextAfter: OrgProseAnchor.context(in: context.body, after: NSMaxRange(bodyRange), limit: contextLimit)
    )
  }

  /// Applies a model's revision as a new `ai` version of the target and makes
  /// it active, in one edit. The original stays recoverable as another
  /// version. If the target moved or changed while the request ran, nothing
  /// is changed.
  static func addAIRevision(
    to text: String,
    target: OrgProseRevisionTarget,
    revisedText: String,
    provenance: OrgProseAIProvenance,
    now: Date = Date(),
    makeID: IDGenerator = OrgProseStateFormat.newID
  ) throws -> OrgProseEdit {
    guard !revisedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OrgProseError.emptyText
    }
    let context = try OrgProseContext(text: text)
    let stamp = OrgProseStateFormat.timestamp(now)
    var provenance = provenance
    if provenance.createdAt == nil { provenance.createdAt = stamp }
    let message = "Added AI alternative"

    if let alternativeID = target.alternativeID {
      guard var set = context.state.alternatives.first(where: { $0.id == alternativeID }),
            let range = context.resolveText(set.anchor).range,
            set.variants.first(where: { $0.id == set.activeVariantID })?.text == target.text
      else {
        throw OrgProseError.revisionTargetChanged
      }
      guard revisedText != target.text else { throw OrgProseError.unchangedText }
      if let known = set.variants.first(where: { $0.text == revisedText }) {
        set.activeVariantID = known.id
      } else {
        let variant = OrgProseVariant(
          id: makeID(),
          text: revisedText,
          origin: OrgProseStateFormat.aiOrigin,
          created: stamp,
          provenance: provenance
        )
        set.variants.append(variant)
        set.activeVariantID = variant.id
      }
      return try replaceAlternative(set, at: range, with: revisedText, in: context, message: message)
    }

    guard let range = context.resolveText(target.anchor).range else {
      throw OrgProseError.revisionTargetChanged
    }
    if context.alternativeRanges().contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
      throw OrgProseError.overlapsAlternative
    }
    guard revisedText != target.text else { throw OrgProseError.unchangedText }
    let originalVariant = OrgProseVariant(
      id: makeID(),
      text: target.text,
      origin: OrgProseStateFormat.originalOrigin,
      created: stamp
    )
    let revised = OrgProseVariant(
      id: makeID(),
      text: revisedText,
      origin: OrgProseStateFormat.aiOrigin,
      created: stamp,
      provenance: provenance
    )
    let set = OrgProseAlternativeSet(
      id: makeID(),
      anchor: OrgProseAnchor(text: revisedText, prefix: "", suffix: "", offset: nil),
      activeVariantID: revised.id,
      variants: [originalVariant, revised],
      created: stamp
    )
    return try replaceAlternative(set, at: range, with: revisedText, in: context, message: message, isNew: true)
  }

  /// Moves the alternative containing the selection by `step` versions.
  static func cycleAlternative(in text: String, selection: NSRange, step: Int) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    guard let match = context.alternativeRanges()
      .filter({ OrgProseSnapshot.range($0.range, covers: selection) })
      .min(by: { $0.range.length < $1.range.length })
    else {
      throw OrgProseError.notFound("There is no alternative at the cursor.")
    }
    return try activate(match.set, step: step, at: match.range, in: context)
  }

  static func chooseVariant(
    in text: String,
    alternativeID: String,
    variantID: String
  ) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    guard var set = context.state.alternatives.first(where: { $0.id == alternativeID }),
          set.variants.contains(where: { $0.id == variantID })
    else {
      throw OrgProseError.notFound("That alternative no longer exists.")
    }
    guard let range = context.resolveText(set.anchor).range else {
      throw OrgProseError.anchorUnresolved
    }
    set.activeVariantID = variantID
    let variantText = set.variants.first { $0.id == variantID }?.text ?? ""
    return try replaceAlternative(set, at: range, with: variantText, in: context, message: "Chose alternative")
  }

  private static func activate(
    _ set: OrgProseAlternativeSet,
    step: Int,
    at range: NSRange,
    in context: OrgProseContext
  ) throws -> OrgProseEdit {
    guard set.variants.count > 1, let index = set.activeIndex else {
      throw OrgProseError.notFound("This alternative has no other versions.")
    }
    let count = set.variants.count
    let next = ((index + step) % count + count) % count
    var updated = set
    updated.activeVariantID = set.variants[next].id
    return try replaceAlternative(
      updated,
      at: range,
      with: set.variants[next].text,
      in: context,
      message: "Version \(next + 1) of \(count)"
    )
  }

  private static func replaceAlternative(
    _ set: OrgProseAlternativeSet,
    at range: NSRange,
    with newText: String,
    in context: OrgProseContext,
    message: String,
    isNew: Bool = false
  ) throws -> OrgProseEdit {
    try commit(
      context,
      replacing: range,
      with: newText,
      message: message
    ) { mid, replaced in
      var state = mid.state
      var updated = set
      updated.anchor = OrgProseAnchor.make(in: mid.body, range: mid.bodyRange(of: replaced))
      if isNew {
        state.alternatives.append(updated)
      } else if let index = state.alternatives.firstIndex(where: { $0.id == updated.id }) {
        state.alternatives[index] = updated
      }
      return (state, replaced)
    }
  }

  static func dismissAlternative(in text: String, id: String) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    guard context.state.alternatives.contains(where: { $0.id == id }) else {
      throw OrgProseError.notFound("That alternative no longer exists.")
    }
    var state = context.state
    state.alternatives.removeAll { $0.id == id }
    return try commit(context, replacing: nil, with: "", message: "Dismissed alternative") { _, _ in
      (state, nil)
    }
  }

  // MARK: Ghosts

  static func ghost(
    in text: String,
    selection: NSRange,
    now: Date = Date(),
    makeID: IDGenerator = OrgProseStateFormat.newID
  ) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    guard selection.length > 0 else { throw OrgProseError.emptySelection }
    guard !context.intersectsBlock(selection) else { throw OrgProseError.selectionTouchesState }

    // Ghosts the selection touches merge into one covering ghost.
    var covered = selection
    var merged = Set<String>()
    for entry in context.ghostRanges() where NSIntersectionRange(entry.range, selection).length > 0 {
      covered = NSUnionRange(covered, entry.range)
      merged.insert(entry.ghost.id)
    }
    if merged.count == 1, context.ghostRanges().contains(where: { $0.range == covered }) {
      throw OrgProseError.notFound("That text is already ghosted.")
    }
    if let block = context.block, NSIntersectionRange(covered, block).length > 0 {
      throw OrgProseError.selectionTouchesState
    }
    let id = makeID()
    let stamp = OrgProseStateFormat.timestamp(now)
    return try commit(context, replacing: nil, with: "", message: "Ghosted text") { mid, _ in
      var state = mid.state
      state.ghosts.removeAll { merged.contains($0.id) }
      let bodyRange = mid.bodyRange(of: covered)
      state.ghosts.append(OrgProseGhost(
        id: id,
        anchor: OrgProseAnchor.make(in: mid.body, range: bodyRange),
        created: stamp
      ))
      return (state, nil)
    }
  }

  /// Revives every ghost the selection (or caret) touches.
  static func revive(in text: String, selection: NSRange) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    let touched = context.ghostRanges().filter { entry in
      if selection.length == 0 {
        return selection.location >= entry.range.location && selection.location <= NSMaxRange(entry.range)
      }
      return NSIntersectionRange(entry.range, selection).length > 0
    }
    guard !touched.isEmpty else {
      throw OrgProseError.notFound("There is no ghosted text at the cursor.")
    }
    let ids = Set(touched.map(\.ghost.id))
    var state = context.state
    state.ghosts.removeAll { ids.contains($0.id) }
    return try commit(context, replacing: nil, with: "", message: "Revived text") { _, _ in
      (state, nil)
    }
  }

  static func revive(in text: String, ghostID: String) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    guard context.state.ghosts.contains(where: { $0.id == ghostID }) else {
      throw OrgProseError.notFound("That ghost no longer exists.")
    }
    var state = context.state
    state.ghosts.removeAll { $0.id == ghostID }
    return try commit(context, replacing: nil, with: "", message: "Revived text") { _, _ in
      (state, nil)
    }
  }

  // MARK: Overflow

  static func moveToOverflow(
    in text: String,
    selection: NSRange,
    now: Date = Date(),
    makeID: IDGenerator = OrgProseStateFormat.newID
  ) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    let selection = clamp(selection, length: context.text.length)
    guard selection.length > 0 else { throw OrgProseError.emptySelection }
    guard !context.intersectsBlock(selection) else { throw OrgProseError.selectionTouchesState }
    let fragment = context.text.substring(with: selection)
    let id = makeID()
    let stamp = OrgProseStateFormat.timestamp(now)
    return try commit(context, replacing: selection, with: "", message: "Moved to Overflow") { mid, replaced in
      var state = mid.state
      let gap = mid.bodyLocation(fromFull: replaced.location)
      state.overflow.append(OrgProseOverflowItem(
        id: id,
        anchor: OrgProseAnchor.gap(in: mid.body, at: gap, removedText: fragment),
        created: stamp
      ))
      return (state, NSRange(location: replaced.location, length: 0) as NSRange?)
    }
  }

  /// Restores a parked fragment at its surviving anchor. When the anchor cannot
  /// be resolved the caller must pass `insertionPoint` after an explicit user
  /// action; otherwise `anchorUnresolved` is thrown and nothing changes.
  static func restoreOverflow(
    in text: String,
    id: String,
    insertionPoint: Int? = nil
  ) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    guard let item = context.state.overflow.first(where: { $0.id == id }) else {
      throw OrgProseError.notFound("That fragment is no longer in Overflow.")
    }
    let location: Int
    if let range = context.resolveInsertion(item.anchor).range {
      location = range.location
    } else if let insertionPoint {
      location = min(max(0, insertionPoint), context.text.length)
    } else {
      throw OrgProseError.anchorUnresolved
    }
    let point = NSRange(location: location, length: 0)
    guard !context.intersectsBlock(point) else { throw OrgProseError.selectionTouchesState }
    var fragment = item.text
    // Never fuse the fragment onto the first line of the state block.
    if point.location == context.block?.location, !fragment.hasSuffix("\n") { fragment += "\n" }
    let restored = fragment
    return try commit(context, replacing: point, with: restored, message: "Restored from Overflow") { mid, replaced in
      var state = mid.state
      state.overflow.removeAll { $0.id == id }
      return (state, replaced)
    }
  }

  static func deleteOverflow(in text: String, id: String) throws -> OrgProseEdit {
    let context = try OrgProseContext(text: text)
    guard context.state.overflow.contains(where: { $0.id == id }) else {
      throw OrgProseError.notFound("That fragment is no longer in Overflow.")
    }
    var state = context.state
    state.overflow.removeAll { $0.id == id }
    return try commit(context, replacing: nil, with: "", message: "Deleted from Overflow") { _, _ in
      (state, nil)
    }
  }

  // MARK: Shared plumbing

  static func clamp(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(max(0, range.length), length - location))
  }

  /// Applies an optional body replacement, then rewrites the state block with
  /// whatever `buildState` returns. The returned range becomes the selection.
  private static func commit(
    _ context: OrgProseContext,
    replacing range: NSRange?,
    with replacement: String,
    message: String,
    buildState: (OrgProseContext, NSRange) -> (OrgProseState, NSRange?)
  ) throws -> OrgProseEdit {
    var edited = context.text as String
    var replaced = NSRange(location: 0, length: 0)
    if let range {
      edited = context.text.replacingCharacters(in: range, with: replacement)
      replaced = NSRange(location: range.location, length: (replacement as NSString).length)
    }
    let mid = try OrgProseContext(text: edited)
    let (state, selection) = buildState(mid, replaced)
    let written = write(state, into: mid)
    return OrgProseEdit(
      text: written.text,
      selection: selection.map { written.adjust(clamp($0, length: (edited as NSString).length)) },
      message: message
    )
  }

  private static func write(
    _ state: OrgProseState,
    into context: OrgProseContext
  ) -> (text: String, adjust: (NSRange) -> NSRange) {
    let identity: (NSRange) -> NSRange = { $0 }
    let source = context.text as String
    if let block = context.block {
      if state.isEmpty {
        var removeRange = block
        let nsText = context.text
        // Drop the blank separator line that appending the block introduced.
        if block.location >= 2,
           nsText.substring(with: NSRange(location: block.location - 2, length: 2)) == "\n\n" {
          removeRange = NSRange(location: block.location - 1, length: block.length + 1)
        }
        let text = nsText.replacingCharacters(in: removeRange, with: "")
        let end = NSMaxRange(removeRange)
        let delta = -removeRange.length
        return (text, { range in
          range.location >= end ? NSRange(location: range.location + delta, length: range.length) : range
        })
      }
      let rendered = OrgProseDocument.render(state)
      let text = context.text.replacingCharacters(in: block, with: rendered)
      let end = NSMaxRange(block)
      let delta = (rendered as NSString).length - block.length
      return (text, { range in
        range.location >= end ? NSRange(location: range.location + delta, length: range.length) : range
      })
    }
    guard !state.isEmpty else { return (source, identity) }
    var text = source
    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    text += "\n"
    text += OrgProseDocument.render(state)
    return (text, identity)
  }
}

extension OrgProseContext {
  /// Full-document range (edited outside the block) to body coordinates.
  func bodyRange(of fullRange: NSRange) -> NSRange {
    NSRange(location: bodyLocation(fromFull: fullRange.location), length: fullRange.length)
  }
}
