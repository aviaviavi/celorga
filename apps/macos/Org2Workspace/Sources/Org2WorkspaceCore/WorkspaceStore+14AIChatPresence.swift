import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  nonisolated public static func relatedBacklinkNodes(
    from backlinks: [BacklinkItem],
    relativePathForFile: (String) -> String
  ) -> [RelatedBacklinkNode] {
    let grouped = Dictionary(grouping: backlinks.compactMap { backlink -> BacklinkItem? in
      guard backlink.srcId?.isEmpty == false else { return nil }
      let title = Org2Display.cleanInline(backlink.srcTitle).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !isGenericRelatedBacklinkTitle(title) else { return nil }
      return backlink
    }) { backlink in
      backlink.srcId ?? backlink.srcTitle
    }

    return grouped.compactMap { key, items in
      guard let first = items.first else { return nil }
      let sortedItems = items.sorted {
        if $0.file != $1.file {
          return $0.file.localizedCaseInsensitiveCompare($1.file) == .orderedAscending
        }
        return $0.lineForEditor < $1.lineForEditor
      }
      let cleanTitle = Org2Display.cleanInline(first.srcTitle).trimmingCharacters(in: .whitespacesAndNewlines)
      let files = Set(items.map(\.file))
      let examples = sortedItems
        .map { Org2Display.cleanInline($0.context).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { unique, context in
          guard unique.count < 2, !unique.contains(context) else { return }
          unique.append(context)
        }
      return RelatedBacklinkNode(
        id: key,
        idValue: first.srcId,
        title: cleanTitle,
        referenceCount: items.count,
        fileCount: files.count,
        primaryPath: "\(relativePathForFile(sortedItems[0].file)):\(sortedItems[0].lineForEditor)",
        examples: examples
      )
    }
    .sorted { lhs, rhs in
      let lhsScore = lhs.referenceCount + lhs.fileCount
      let rhsScore = rhs.referenceCount + rhs.fileCount
      if lhsScore != rhsScore { return lhsScore > rhsScore }
      if lhs.referenceCount != rhs.referenceCount { return lhs.referenceCount > rhs.referenceCount }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
  }

  nonisolated public static func isGenericRelatedBacklinkTitle(_ title: String) -> Bool {
    let normalized = title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(separator: " ")
      .joined(separator: " ")
    guard !normalized.isEmpty else { return true }
    return Self.genericRelatedBacklinkTitles.contains(normalized)
  }

  private nonisolated static let genericRelatedBacklinkTitles: Set<String> = [
    "abstract",
    "action items",
    "agenda",
    "background",
    "context",
    "decision",
    "decisions",
    "detail",
    "details",
    "discussion",
    "follow up",
    "follow ups",
    "highlights",
    "notes",
    "overview",
    "raw transcript",
    "recap",
    "recurring themes",
    "related",
    "summary",
    "takeaways",
    "theme",
    "themes",
    "transcript"
  ]

  public func toggleNodeContextPane() {
    recordCurrentNavigationDestination()
    isNodeContextPanePresented.toggle()
    if isNodeContextPanePresented, let selectedLocation {
      scheduleBacklinksLoad(for: selectedLocation)
    } else {
      cancelBacklinksLoad(clearResults: false)
    }
  }

  public func toggleBacklinkFileGroup(_ group: BacklinkFileGroup) {
    if expandedBacklinkFileIDs.contains(group.id) {
      expandedBacklinkFileIDs.remove(group.id)
    } else {
      expandedBacklinkFileIDs.insert(group.id)
    }
  }

  public func selectBacklink(_ backlink: BacklinkItem) {
    pendingNavigationSource = "backlink"
    select(.backlink(backlink))
  }

  func scheduleSelectedEntityMetadata(for source: EntrySource?) {
    selectedEntityMetadataGeneration &+= 1
    let generation = selectedEntityMetadataGeneration
    selectedEntityMetadataTask?.cancel()
    selectedEntityMetadataTask = nil
    guard let source else {
      selectedNodeEntityType = nil
      selectedNodeHasExplicitEntityType = false
      return
    }

    selectedNodeEntityType = nil
    selectedNodeHasExplicitEntityType = false
    selectedEntityMetadataTask = Task { @MainActor [weak self] in
      let metadata = await Task.detached(priority: .utility) {
        (
          type: Self.entityType(for: source),
          hasExplicitType: Self.hasExplicitEntityType(source)
        )
      }.value
      guard let self,
            !Task.isCancelled,
            self.selectedEntityMetadataGeneration == generation,
            self.selectedEntrySource?.id == source.id
      else { return }
      self.selectedNodeEntityType = metadata.type
      self.selectedNodeHasExplicitEntityType = metadata.hasExplicitType
      self.selectedEntityMetadataTask = nil
    }
  }

  public var canSetSelectedNodeEntityType: Bool {
    guard let source = selectedEntrySource,
          source.isEditable,
          Self.isEntityTypeTarget(source)
    else {
      return false
    }
    return !isSavingEntry
      && !isSavingBlock
      && !isEditingEntry
      && editingBlockID == nil
      && !liveFileEditorHasUnsavedChanges
  }

  nonisolated static func entityType(for source: EntrySource) -> Org2EntityType? {
    if let explicit = explicitEntityType(for: source) {
      return explicit
    }

    let metadata = entityMetadataText(for: source)
    if let legacyKind = firstRegularExpressionCapture(
      in: metadata,
      pattern: #"(?im)^\s*(?:#\+(?:CELORGA_KIND|ORG2_KIND|KIND)|:KIND):\s*(person)\s*$"#
    ).flatMap(Org2EntityType.init) {
      return legacyKind
    }
    if hasLegacyPersonTag(in: metadata) {
      return Org2EntityType("person")
    }

    guard !source.isSubtree, source.startLine == 1 else { return nil }
    let components = URL(fileURLWithPath: source.file).pathComponents.map { $0.lowercased() }
    if components.contains(where: { ["people", "persons", "contacts"].contains($0) }) {
      return Org2EntityType("person")
    }
    if components.contains(where: { ["company", "companies", "accounts", "organizations", "orgs"].contains($0) }) {
      return Org2EntityType("company")
    }
    if components.contains(where: { ["project", "projects"].contains($0) }) {
      return Org2EntityType("project")
    }
    return nil
  }

  nonisolated static func showsEntityActionItems(for source: EntrySource) -> Bool {
    guard !source.isSubtree else { return false }
    return entityType(for: source)?.supportsActionItems == true
  }

  public func loadEntityActionItems(for source: EntrySource) async {
    entityActionItemsLoadGeneration += 1
    let generation = entityActionItemsLoadGeneration

    guard let corpusRoot else {
      entityActionItems = nil
      isLoadingEntityActionItems = false
      return
    }

    let fallbackTitle = URL(fileURLWithPath: source.file)
      .deletingPathExtension()
      .lastPathComponent
      .replacingOccurrences(of: "-", with: " ")
    let resolved = await Task.detached(priority: .utility) {
      let supportsActionItems = Self.showsEntityActionItems(for: source)
      let object = Self.firstOrgID(in: source.text).map { "id:\($0)" }
        ?? Self.aiChatTitle(from: source.text, fallback: fallbackTitle).title
      return (supportsActionItems, object)
    }.value
    guard generation == entityActionItemsLoadGeneration,
          selectedEntrySource?.id == source.id,
          resolved.0
    else {
      entityActionItems = nil
      isLoadingEntityActionItems = false
      return
    }
    let object = resolved.1
    guard !object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      entityActionItems = nil
      isLoadingEntityActionItems = false
      return
    }

    entityActionItems = nil
    isLoadingEntityActionItems = true
    defer {
      if generation == entityActionItemsLoadGeneration {
        isLoadingEntityActionItems = false
      }
    }

    do {
      let payload: NodeActionItemsPayload
      if let loader = nodeActionItemsLoaderForTesting {
        payload = try await loader(object, corpusRoot)
      } else {
        payload = try await cli.runJSON([
          "query", "actions",
          "--object", object,
          "--dir", corpusRoot.path,
          "--recursive",
          "--recent-days", "30",
          "--open-limit", "5",
          "--completed-limit", "2",
          "--format", "json",
        ])
      }
      guard generation == entityActionItemsLoadGeneration,
            selectedEntrySource?.id == source.id
      else { return }
      entityActionItems = payload
    } catch is CancellationError {
      return
    } catch {
      guard generation == entityActionItemsLoadGeneration,
            selectedEntrySource?.id == source.id
      else { return }
      entityActionItems = nil
    }
  }

  public func selectEntityActionItem(_ item: NodeActionItem) {
    guard let corpusRoot else { return }
    let root = corpusRoot.resolvingSymlinksInPath().standardizedFileURL
    let candidate = (item.file.hasPrefix("/")
      ? URL(fileURLWithPath: item.file)
      : root.appendingPathComponent(item.file))
      .resolvingSymlinksInPath()
      .standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/") else {
      statusText = "Action item is outside the active corpus"
      return
    }
    let backlink = BacklinkItem(
      srcId: item.id,
      srcTitle: item.title,
      file: candidate.path,
      line: max(0, item.line - 1),
      context: item.snippet ?? item.title
    )
    select(.backlink(backlink), surface: selectedSurface)
  }

  public func setSelectedNodeEntityType(_ entityType: Org2EntityType?) async {
    guard let source = selectedEntrySource,
          source.isEditable,
          Self.isEntityTypeTarget(source),
          canSetSelectedNodeEntityType
    else {
      statusText = "No editable node loaded"
      return
    }
    guard let replacement = Self.sourceTextSettingEntityType(source, entityType: entityType) else {
      statusText = "Node type update failed"
      return
    }
    guard Self.normalizeLineEndings(replacement) != Self.normalizeLineEndings(source.text) else {
      statusText = entityType.map { "Type is already \($0.title)" } ?? "Node has no explicit type"
      return
    }

    let undoSnapshot = await fileUndoSnapshot(for: source.file)
    isSavingEntry = true
    defer { isSavingEntry = false }
    do {
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.endLineExclusive,
        replacement: replacement,
        expectedOriginal: source.text
      )
      guard selectedEntrySource?.id == source.id else {
        await recordFileUndo(from: undoSnapshot)
        return
      }
      await recordFileUndo(from: undoSnapshot)
      await finishSavedEntry(source: source, savedText: replacement, keepEditing: false)
      statusText = entityType.map { "Type -> \($0.title)" } ?? "Explicit node type removed"
    } catch {
      errorText = error.localizedDescription
      statusText = "Node type update failed"
    }
  }

  public func promptAndSetSelectedNodeEntityType() {
    guard canSetSelectedNodeEntityType else {
      statusText = "No editable node loaded"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Set Node Type"
    alert.informativeText = "Use a short type such as person, company, project, decision, or topic."
    alert.addButton(withTitle: "Set")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "entity type"
    field.stringValue = selectedNodeEntityType?.rawValue ?? ""
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let entityType = Org2EntityType(field.stringValue) else {
      statusText = "Node type must contain a letter or number"
      return
    }
    Task { await setSelectedNodeEntityType(entityType) }
  }

  nonisolated static func sourceTextSettingEntityType(
    _ source: EntrySource,
    entityType: Org2EntityType?
  ) -> String? {
    guard isEntityTypeTarget(source) else { return nil }
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard !lines.isEmpty else { return nil }

    if source.isSubtree {
      lines[0] = removingEntityTypeTags(from: lines[0])
      removeDirectEntityTypeProperties(from: &lines)
      if let entityType {
        upsertDirectEntityTypeProperty(entityType.rawValue, in: &lines)
      }
    } else {
      removeFileEntityTypeMetadata(from: &lines)
      if let entityType {
        upsertFileEntityTypeProperty(entityType.rawValue, in: &lines)
      }
    }
    return lines.joined(separator: "\n")
  }

  nonisolated private static func isEntityTypeTarget(_ source: EntrySource) -> Bool {
    if source.isSubtree {
      return source.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map { $0.range(of: #"^\*+\s+"#, options: .regularExpression) != nil } == true
    }
    return source.startLine == 1
  }

  nonisolated private static func explicitEntityType(for source: EntrySource) -> Org2EntityType? {
    let metadata = entityMetadataText(for: source)
    if let propertyType = firstRegularExpressionCapture(
      in: metadata,
      pattern: #"(?im)^\s*(?:#\+(?:CELORGA_ENTITY_TYPE|ORG2_ENTITY_TYPE|ENTITY_TYPE)|:(?:CELORGA_ENTITY_TYPE|ORG2_ENTITY_TYPE|ENTITY_TYPE)):\s*(.+?)\s*$"#
    ).flatMap(Org2EntityType.init) {
      return propertyType
    }
    return entityTagTokens(in: metadata).compactMap(Org2EntityType.init).first
  }

  nonisolated private static func hasExplicitEntityType(_ source: EntrySource) -> Bool {
    explicitEntityType(for: source) != nil
  }

  nonisolated private static func entityMetadataText(for source: EntrySource) -> String {
    // Entity metadata is defined at the document/subtree boundary. Bound the
    // inspected prefix so toolbar recomputation can never scale with a large
    // body or archive payload.
    let metadataPrefix = String(source.text.prefix(131_072))
    let lines = normalizeLineEndings(metadataPrefix)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard source.isSubtree else {
      return lines.prefix { !isHeadingLine($0) }.joined(separator: "\n")
    }
    guard !lines.isEmpty else { return "" }
    var end = 1
    while end < lines.count,
          lines[end].trimmingCharacters(in: .whitespaces).range(
            of: #"^(?:SCHEDULED|DEADLINE|CLOSED):"#,
            options: [.regularExpression, .caseInsensitive]
          ) != nil {
      end += 1
    }
    if end < lines.count,
       lines[end].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" {
      end += 1
      while end < lines.count {
        let isEnd = lines[end].trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
        end += 1
        if isEnd { break }
      }
    }
    return lines[..<end].joined(separator: "\n")
  }

  nonisolated private static func entityTagTokens(in metadata: String) -> [String] {
    metadata
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("*")
          || trimmed.lowercased().hasPrefix("#+filetags:")
          || trimmed.lowercased().hasPrefix("#+roam_tags:")
      }
      .flatMap { line in
        line.split(separator: ":").compactMap { rawToken -> String? in
          let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if token.hasPrefix("type_") { return String(token.dropFirst("type_".count)) }
          if token.hasPrefix("type-") { return String(token.dropFirst("type-".count)) }
          return nil
        }
      }
  }

  nonisolated private static func hasLegacyPersonTag(in metadata: String) -> Bool {
    metadata
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("*")
          || trimmed.lowercased().hasPrefix("#+filetags:")
          || trimmed.lowercased().hasPrefix("#+roam_tags:")
      }
      .contains { line in
        line.split(separator: ":").contains { rawToken in
          rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "person"
        }
      }
  }

  nonisolated private static func firstRegularExpressionCapture(
    in text: String,
    pattern: String
  ) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let source = text as NSString
    guard let match = regex.firstMatch(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ), match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else {
      return nil
    }
    return source.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func removingEntityTypeTags(from line: String) -> String {
    line
      .replacingOccurrences(
        of: #"(?i):type[-_][A-Za-z0-9_-]+(?=:)"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespaces)
  }

  nonisolated private static func removeFileEntityTypeMetadata(from lines: inout [String]) {
    let preambleEnd = lines.firstIndex(where: isHeadingLine) ?? lines.count
    for index in (0..<preambleEnd).reversed() {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.range(
        of: #"^(?:#\+(?:CELORGA_ENTITY_TYPE|ORG2_ENTITY_TYPE|ENTITY_TYPE)|:(?:CELORGA_ENTITY_TYPE|ORG2_ENTITY_TYPE|ENTITY_TYPE)):"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        lines.remove(at: index)
        continue
      }
      if trimmed.range(
        of: #"^#\+(?:FILETAGS|ROAM_TAGS):"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        lines[index] = removingEntityTypeTags(from: lines[index])
      }
    }
    removeEmptyFilePropertyDrawers(from: &lines)
  }

  nonisolated private static func removeEmptyFilePropertyDrawers(from lines: inout [String]) {
    var index = 0
    while index < (lines.firstIndex(where: isHeadingLine) ?? lines.count) {
      guard lines[index].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" else {
        index += 1
        continue
      }
      guard let end = lines[(index + 1)...].firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
      }) else { return }
      if lines[(index + 1)..<end].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        lines.removeSubrange(index...end)
      } else {
        index = end + 1
      }
    }
  }

  nonisolated private static func filePropertyDrawerRange(in lines: [String]) -> ClosedRange<Int>? {
    let preambleEnd = lines.firstIndex(where: isHeadingLine) ?? lines.count
    guard preambleEnd > 0 else { return nil }
    for start in 0..<preambleEnd where
      lines[start].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:"
    {
      guard start + 1 < preambleEnd,
            let end = lines[(start + 1)..<preambleEnd].firstIndex(where: {
              $0.trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
            })
      else { return nil }
      return start...end
    }
    return nil
  }

  nonisolated private static func upsertFileEntityTypeProperty(
    _ rawValue: String,
    in lines: inout [String]
  ) {
    if let drawer = filePropertyDrawerRange(in: lines) {
      lines.insert(":ORG2_ENTITY_TYPE: \(rawValue)", at: drawer.upperBound)
      return
    }
    let preambleEnd = lines.firstIndex(where: isHeadingLine) ?? lines.count
    let lastKeyword = (0..<preambleEnd).last(where: {
      lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#+")
    })
    lines.insert(contentsOf: [
      ":PROPERTIES:",
      ":ORG2_ENTITY_TYPE: \(rawValue)",
      ":END:",
    ], at: lastKeyword.map { $0 + 1 } ?? 0)
  }

  nonisolated private static func directPropertyDrawerRange(in lines: [String]) -> ClosedRange<Int>? {
    guard !lines.isEmpty, lines[0].range(of: #"^\*+\s+"#, options: .regularExpression) != nil else {
      return nil
    }
    var start = 1
    while start < lines.count,
          lines[start].trimmingCharacters(in: .whitespaces).range(
            of: #"^(?:SCHEDULED|DEADLINE|CLOSED):"#,
            options: [.regularExpression, .caseInsensitive]
          ) != nil {
      start += 1
    }
    guard start < lines.count,
          lines[start].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:",
          let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
          })
    else {
      return nil
    }
    return start...end
  }

  nonisolated private static func isHeadingLine(_ line: String) -> Bool {
    line.range(of: #"^\*+\s+"#, options: .regularExpression) != nil
  }

  nonisolated private static func removeDirectEntityTypeProperties(from lines: inout [String]) {
    guard let drawer = directPropertyDrawerRange(in: lines) else { return }
    for index in drawer.reversed() where index > drawer.lowerBound && index < drawer.upperBound {
      if lines[index].trimmingCharacters(in: .whitespaces).range(
        of: #"^:(?:CELORGA_ENTITY_TYPE|ORG2_ENTITY_TYPE|ENTITY_TYPE):"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        lines.remove(at: index)
      }
    }
    if let updated = directPropertyDrawerRange(in: lines),
       lines[(updated.lowerBound + 1)..<updated.upperBound]
         .allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      lines.removeSubrange(updated)
    }
  }

  nonisolated private static func upsertDirectEntityTypeProperty(
    _ rawValue: String,
    in lines: inout [String]
  ) {
    if let drawer = directPropertyDrawerRange(in: lines) {
      lines.insert(":ORG2_ENTITY_TYPE: \(rawValue)", at: drawer.upperBound)
      return
    }
    var insertionIndex = 1
    while insertionIndex < lines.count,
          lines[insertionIndex].trimmingCharacters(in: .whitespaces).range(
            of: #"^(?:SCHEDULED|DEADLINE|CLOSED):"#,
            options: [.regularExpression, .caseInsensitive]
          ) != nil {
      insertionIndex += 1
    }
    lines.insert(contentsOf: [
      ":PROPERTIES:",
      ":ORG2_ENTITY_TYPE: \(rawValue)",
      ":END:",
    ], at: insertionIndex)
  }

  func openNodeBriefArtifact(
    url: URL,
    relativePath: String,
    title: String,
    modifiedAt: Date?
  ) {
    let zone = NSString(string: relativePath).deletingLastPathComponent
    let thread = AIChatThreadRecord(
      title: "Brief: \(title)",
      file: url.path,
      line: 1,
      zone: zone.isEmpty ? "views" : zone,
      modifiedAt: modifiedAt,
      idValue: nil
    )
    activateDetailLocation(.aiChatThreadRecord(thread), mode: .page, surface: .files, recordsHistory: true)
    selectedAIChatThreadRecordID = thread.id
    pendingNodeBriefArtifactRelativePath = nil
    pendingNodeBriefTitle = nil
    aiChatStatusText = "Opened cached node brief"
    statusText = "Opened \(relativePath)"
  }

  nonisolated static func nodeBriefArtifactRelativePath(id: String?, file: String, line: Int) -> String {
    let tokenRaw: String
    if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      tokenRaw = id
    } else {
      tokenRaw = "\(file)-line-\(max(1, line))"
    }
    return "views/node-briefs/\(slug(tokenRaw)).org"
  }

  nonisolated static func legacyNodeBriefArtifactRelativePath(
    title: String,
    id: String?,
    file: String,
    line: Int
  ) -> String {
    let tokenRaw: String
    if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      tokenRaw = id
    } else {
      tokenRaw = "\(file)-line-\(max(1, line))"
    }
    return "views/openclaw/node-briefs/\(slug(title))-\(slug(tokenRaw)).org2"
  }

  nonisolated static func nodeBriefArtifact(at url: URL, relativePath: String) -> NodeBriefArtifact? {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          (values.fileSize ?? 0) > 0,
          let raw = try? String(contentsOf: url, encoding: .utf8)
    else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains("ORG2_NODE_BRIEF_STATUS: pending"),
          !trimmed.contains("CELORGA_NODE_BRIEF_STATUS: pending")
    else {
      return nil
    }
    return NodeBriefArtifact(
      relativePath: relativePath,
      file: url.standardizedFileURL.path,
      title: nodeBriefArtifactTitle(raw),
      body: nodeBriefArtifactBody(raw),
      modifiedAt: modificationDate(for: url)
    )
  }

  nonisolated static func nodeBriefArtifactTitle(_ raw: String) -> String {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      guard text.uppercased().hasPrefix("#+TITLE:") else { continue }
      return text
        .dropFirst("#+TITLE:".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "Node brief"
  }

  nonisolated static func nodeBriefArtifactBody(_ raw: String) -> String {
    let lines = raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var index = 0
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.uppercased().hasPrefix("#+TITLE:") {
        index += 1
        continue
      }
      if trimmed == ":PROPERTIES:" {
        index += 1
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != ":END:" {
          index += 1
        }
        if index < lines.count { index += 1 }
        continue
      }
      if trimmed.isEmpty {
        index += 1
        continue
      }
      break
    }
    guard index < lines.count else { return "" }
    let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.count > 20_000 else { return body }
    let end = body.index(body.startIndex, offsetBy: 20_000)
    return String(body[..<end]) + "\n\n[Brief truncated in context pane. Open the full artifact to continue.]"
  }

  nonisolated static func nodeBriefPrompt(
    title: String,
    reference: String,
    artifactRelativePath: String,
    artifactLocalPath: String,
    artifactRuntimePath: String,
    sourceID: String?
  ) -> String {
    let artifactID = "node-brief-\(slug(sourceID ?? reference))"
    let provenance = [
      sourceID.map { "id:\($0)" },
      "file:\(reference)"
    ].compactMap { $0 }.joined(separator: ", ")
    return """
    Generate a concise, source-cited briefing for the selected Celorga node "\(title)" and save it as a Celorga view artifact.

    Target artifact relative path: \(artifactRelativePath)
    Target artifact path for the current AI runtime: \(artifactRuntimePath)
    Local artifact path: \(artifactLocalPath)
    Selected node: \(reference)
    \(sourceID.map { "Selected node ID: \($0)" } ?? "Selected node ID: unavailable")

    Use the selected-node source and computed backlink context provided in the Celorga workspace context. You may run celorga backlinks/search/query for more source context if needed, but do not run celorga brief to generate this brief.

    Before writing, do a current-state sweep. Search recent and agent/workflow files for the selected node title, aliases, account/company names, and obvious variants. Prefer newer dated entries over older background context when describing current state. Do not discard completed DONE/CANCELED workflow items if they record important current facts such as an email sent, follow-up sent, handoff completed, decision made, current owner, waiting on reply/response, blocked state, or other recent account/project state. Treat properties and phrases such as SENT_AT, LAST_SENT_AT, GMAIL_SENT_MESSAGE_ID, FOLLOWUP_STATUS, FOLLOWUP_SENT_AT, waiting on reply, awaiting response, blocked, sent, approved, or completed as possible current-state evidence even when the TODO itself is no longer active.

    Write for a human trying to quickly understand the node. Focus on what matters, not how Celorga stores it. Do not present stable IDs, artifact metadata, file paths, provenance fields, review status, schema fields, or the mere existence of a title/ID as facts or highlights. Use file paths and line numbers only as citations after concrete claims. Mention metadata only in "Node health issues" when it is actually broken, missing, duplicated, stale, or confusing.

    Keep the body concise:
    - Most important facts: 3-6 bullets, including recent material state changes even if they came from completed workflow entries.
    - Active related tasks: only TODO/open/actionable items, up to 5 bullets, or "None found."
    - Recent related decisions: only decisions/commitments/outcomes, up to 5 bullets, or "None found."
    - Open questions: unresolved questions/unknowns/risks, including waiting-on-response states, up to 5 bullets, or "None found."
    - Node health issues: put this last; include only maintenance problems such as contradictory notes, stale generated context, broken links, missing IDs, duplicate IDs, bad citations, or confusing organization.

    Create the parent directory if needed. Replace the artifact file atomically if it already exists. The file must be valid Org and start with:
    #+TITLE: Node brief: \(title)
    :PROPERTIES:
    :ID: \(artifactID)
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_PROVENANCE: \(provenance)
    :ORG2_GENERATOR: Celorga AI chat node brief
    :ORG2_GENERATED_AT: <ISO-8601 timestamp>
    :ORG2_CLAIM_STATE: source-backed
    :ORG2_REVIEW_STATUS: review-required
    :ORG2_AI_TASK: node-brief
    :ORG2_PROMPT_TEMPLATE: node-brief@v3
    :END:

    Then write these sections:
    * Most important facts
    * Active related tasks
    * Recent related decisions
    * Open questions
    * Node health issues
    * Sources

    Cite file paths and line numbers for every concrete claim. Prefer specific, user-meaningful facts over generic graph or storage details. Do not edit canonical notes. Reply in chat with only a short confirmation and the artifact path.
    """
  }

  func backlinkTargetID(for location: WorkspaceLocation) async throws -> String? {
    if let id = location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
      return id
    }

    do {
      let payload: OrgIDLookupPayload = try await cli.runJSON([
        "id", "get",
        "--file", location.file,
        "--line", "\(location.lineForEditor)",
        "--format", "json"
      ])
      applyResolvedID(payload.id, to: location)
      return payload.id
    } catch {
      return nil
    }
  }

  func applyResolvedID(_ id: String, to location: WorkspaceLocation) {
    guard selectedLocationMatches(location) else { return }
    switch selectedLocation {
    case .aiChatThreadRecord(let thread):
      selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
        title: thread.title,
        file: thread.file,
        line: thread.lineForEditor,
        zone: thread.zone,
        modifiedAt: thread.modifiedAt,
        idValue: id
      ))
    default:
      break
    }
  }

  public func openSelectedLocation() {
    if selectedLocation == nil,
       agendaMode == .assigned,
       let selectedAssignedWorkItemID,
       let item = assignedWorkItems.first(where: { $0.id == selectedAssignedWorkItemID }) {
      selectAssignedWorkItem(item)
    }
    guard let selectedLocation else { return }
    open(selectedLocation)
  }

  public func open(_ location: WorkspaceLocation) {
    openFile(path: location.file, line: location.lineForEditor)
  }

  public func revealSelectedLocation() {
    guard let selectedLocation else { return }
    revealFile(path: selectedLocation.file)
  }

  public func revealFile(path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  public func openFileInEditor(path: String, line: Int = 1) {
    openFile(path: path, line: line)
  }

  public func copyFileReference(path: String, line: Int? = nil) {
    let reference = line.map { "\(relativePath(path)):\($0)" } ?? relativePath(path)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(reference, forType: .string)
    statusText = "Copied \(reference)"
  }

  public func relativePath(_ path: String) -> String {
    guard let corpusRoot else { return path }
    return Self.relativePath(for: path, root: corpusRoot)
  }

  nonisolated static func relativePath(for path: String, root: URL) -> String {
    let originalPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath == rootPath { return "." }
    if resolvedPath.hasPrefix(rootPath + "/") {
      return String(resolvedPath.dropFirst(rootPath.count + 1))
    }
    return originalPath
  }

  func startNewAIThread(with rawPointers: [AIChatContextPointer]) {
    var seen = Set<String>()
    let pointers = rawPointers.filter {
      seen.insert("\($0.kind)|\($0.reference)|\($0.displayTitle)").inserted
    }
    guard !pointers.isEmpty else {
      statusText = "No selected items are available for AI context"
      return
    }

    let destination = selectedAIChatDestination
    let threadTitle = pointers.count == 1
      ? pointers[0].threadTitle
      : "Context: \(pointers.count) selected items"
    createAIChatThread(
      title: Self.normalizedAIChatThreadTitle(threadTitle),
      statusText: "New \(destination.title) context chat",
      runtime: destination.runtime,
      destinationID: destination.id
    )
    let draft = pointers.map(injectedAIChatContext).joined()
    publishAIChatComposerDraft(draft)
    recordWorkspaceUndo(.aiChatDraft(previous: "", next: draft))
    setAIChatAssistantPanelPresented(true)

    let countLabel = pointers.count == 1 ? "1 item" : "\(pointers.count) items"
    aiChatStatusText = "Added \(countLabel) to \(destination.title)"
    statusText = "Started a new AI thread with \(countLabel)"
  }

  func aiChatContextPointer(
    for run: AgentRunItem,
    requiresExistingRecord: Bool
  ) -> AIChatContextPointer? {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return nil
    }
    let relativePath = CelorgaNames.runRecordRelativePath(runID: run.id, corpusRoot: corpusRoot)
    let recordURL = corpusRoot.appendingPathComponent(relativePath).standardizedFileURL
    if requiresExistingRecord, !FileManager.default.fileExists(atPath: recordURL.path) {
      errorText = "The run record could not be found at \(relativePath)."
      statusText = "Run record missing"
      return nil
    }

    let title = Self.agentRunContextTitle(run)
    return AIChatContextPointer(
      kind: "agent run",
      displayTitle: title,
      reference: "\(mappedPathForOpenClaw(recordURL.path)):1",
      displayReference: "\(relativePath):1",
      threadTitle: "Run: \(title)"
    )
  }

  nonisolated private static func agentRunContextTitle(_ run: AgentRunItem) -> String {
    let title = run.displayTitle
    return title.count <= 80
      ? title
      : String(title.prefix(79)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  func aiChatContextPointer(for item: ApprovalItem) -> AIChatContextPointer {
    let title = Org2Display.cleanInline(item.title)
    return AIChatContextPointer(
      kind: item.isRunApproval ? "run approval" : "approval item",
      displayTitle: title,
      reference: "\(mappedPathForOpenClaw(item.file)):\(item.line)",
      displayReference: "\(relativePath(item.file)):\(item.line)",
      threadTitle: "Approval: \(title)"
    )
  }

  func aiChatContextPointer(for file: CorpusFile) -> AIChatContextPointer {
    let title = Self.titleFromFileStem(URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent)
    return AIChatContextPointer(
      kind: "selected file",
      displayTitle: title,
      reference: "\(mappedPathForOpenClaw(file.path)):1",
      displayReference: "\(file.relativePath):1",
      threadTitle: "File: \(title)"
    )
  }

  func aiChatContextPointer(for location: WorkspaceLocation) -> AIChatContextPointer {
    let kind: String
    switch location {
    case .agenda:
      kind = "agenda item"
    case .assigned:
      kind = "assigned agenda item"
    case .search:
      kind = "search result"
    case .backlink:
      kind = "backlink"
    case .aiChatThreadRecord:
      kind = "selected page"
    case .meeting:
      kind = "meeting"
    }
    let title = aiChatReadableContextTitle(
      location.title,
      file: location.file,
      generic: "Selected item"
    )
    return AIChatContextPointer(
      kind: kind,
      displayTitle: title,
      reference: "\(mappedPathForOpenClaw(location.file)):\(location.lineForEditor)",
      displayReference: "\(relativePath(location.file)):\(location.lineForEditor)",
      threadTitle: "Ask: \(title)"
    )
  }

  func aiChatContextPointerForCurrentSelection() -> AIChatContextPointer? {
    if let selectedBlock,
       let pointer = aiChatContextPointer(for: AIChatBlockContextPointer(source: selectedEntrySource, block: selectedBlock)) {
      return pointer
    }

    if let source = selectedEntrySource {
      let kind = source.isSubtree ? "selected entry" : "selected page"
      let fallbackTitle = selectedLocation?.title ?? Self.titleFromFileStem(URL(fileURLWithPath: source.file).deletingPathExtension().lastPathComponent)
      let title = aiChatContextDisplayTitle(for: source, fallback: fallbackTitle, generic: source.isSubtree ? "Selected entry" : "Selected page")
      return AIChatContextPointer(
        kind: kind,
        displayTitle: title,
        reference: "\(mappedPathForOpenClaw(source.file)):\(source.startLine)",
        displayReference: "\(relativePath(source.file)):\(source.startLine)",
        threadTitle: "Ask: \(title)"
      )
    }

    if let location = selectedLocation {
      return aiChatContextPointer(for: location)
    }

    return nil
  }

  func currentAIChatResourceReference() -> AIChatResourceReference? {
    guard let location = selectedLocation else { return nil }
    let file = URL(fileURLWithPath: location.file).standardizedFileURL.path
    if let rawID = location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines),
       !rawID.isEmpty {
      return AIChatResourceReference(
        key: "id:\(rawID)",
        kind: .heading,
        title: location.title,
        file: file,
        line: location.lineForEditor,
        idValue: rawID
      )
    }
    guard location.lineForEditor <= 1 else { return nil }
    return AIChatResourceReference(
      key: "file:\(file)",
      kind: .file,
      title: location.title,
      file: file,
      line: 1
    )
  }

  func aiChatContextPointer(for block: AIChatBlockContextPointer?) -> AIChatContextPointer? {
    guard let block else { return nil }
    let startLine = max(1, block.startLine)
    let endLineInclusive = max(startLine, block.endLineExclusive - 1)
    let mappedFile = mappedPathForOpenClaw(block.file)
    let displayFile = relativePath(block.file)
    let reference: String
    let displayReference: String
    if endLineInclusive > startLine {
      reference = "\(mappedFile):\(startLine)-\(endLineInclusive)"
      displayReference = "\(displayFile):\(startLine)-\(endLineInclusive)"
    } else {
      reference = "\(mappedFile):\(startLine)"
      displayReference = "\(displayFile):\(startLine)"
    }
    return AIChatContextPointer(
      kind: "selected block",
      displayTitle: block.displayTitle,
      reference: reference,
      displayReference: displayReference,
      threadTitle: "Ask: \(block.displayTitle)"
    )
  }

  func addAIChatContext(_ pointer: AIChatContextPointer, threadMode: AIChatThreadMode) {
    let injectedContext = injectedAIChatContext(pointer)
    let hadSelectedThread = selectedAIChatThreadID != nil
    let unthreadedDraft = hadSelectedThread ? "" : aiChatDraft
    if !canReuseAIChatContextDraftThread(mode: threadMode) {
      prepareAIChatThread(
        mode: threadMode,
        title: pointer.threadTitle,
        statusText: "New context chat"
      )
    }
    let previousDraft = currentAIChatDraftForSelectedThread()
    let draftToAppend = previousDraft.isEmpty ? unthreadedDraft : previousDraft
    var nextDraft = previousDraft
    if previousDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      nextDraft = injectedContext + draftToAppend
    } else if !draftToAppend.contains(pointer.reference) {
      nextDraft = injectedContext + draftToAppend
    }
    if nextDraft != previousDraft {
      publishAIChatComposerDraft(nextDraft)
      recordWorkspaceUndo(.aiChatDraft(previous: hadSelectedThread ? previousDraft : unthreadedDraft, next: nextDraft))
    }

    setAIChatAssistantPanelPresented(true)
    let runtimeTitle = selectedAIChatDestinationTitle
    aiChatStatusText = "Added \(pointer.displayReference) to \(runtimeTitle)"
    statusText = "Added \(pointer.displayReference) to \(runtimeTitle)"
  }

  func injectedAIChatContext(_ pointer: AIChatContextPointer) -> String {
    let displayTitle = pointer.displayTitle
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "”", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "Use \(pointer.kind) “\(displayTitle)” at \(pointer.reference) as context.\n\n"
  }

  func automaticAIChatActionText(
    _ pointer: AIChatContextPointer,
    prompt: String,
    userText: String = ""
  ) -> String {
    AIChatContextPresentation.automaticContext(
      kind: pointer.kind,
      title: pointer.displayTitle,
      reference: pointer.reference,
      prompt: prompt,
      userText: userText
    )
  }

  private func aiChatContextDisplayTitle(
    for source: EntrySource,
    fallback: String,
    generic: String
  ) -> String {
    if let heading = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine).compactMap({ block -> String? in
      guard case .heading(let heading) = block.rendered else { return nil }
      return heading.title
    }).first {
      return aiChatReadableContextTitle(heading, file: source.file, generic: generic)
    }
    return aiChatReadableContextTitle(fallback, file: source.file, generic: generic)
  }

  private func aiChatReadableContextTitle(_ rawTitle: String, file _: String, generic: String) -> String {
    let firstLine = rawTitle.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? rawTitle
    let title = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleStem = URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent
    guard !title.isEmpty,
          UUID(uuidString: titleStem) == nil
    else { return generic }
    return title.count > 64 ? String(title.prefix(61)) + "…" : title
  }

  func resolvedAIChatContext(_ context: AIChatPresentedContext) -> AIChatPresentedContext {
    guard context.usesGenericTitle else { return context }
    let reference = AIChatFileReference(path: context.reference, line: nil)
    guard let path = localPathForOpenClawReference(reference.path) else { return context }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let stem = url.deletingPathExtension().lastPathComponent
    let fallback = UUID(uuidString: stem) == nil ? Self.titleFromFileStem(stem) : context.title
    guard let prefix = try? Self.readPrefix(url, maxBytes: 256 * 1024) else { return context }
    let title = Self.aiChatTitle(from: prefix, fallback: fallback).title
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.localizedCaseInsensitiveCompare(context.title) != .orderedSame else {
      return context
    }
    return AIChatPresentedContext(
      kind: context.kind,
      title: title.count > 96 ? String(title.prefix(93)) + "…" : title,
      reference: context.reference,
      sourceLine: context.sourceLine,
      automaticPrompt: context.automaticPrompt
    )
  }

  func openAIChatContext(_ context: AIChatPresentedContext) {
    openChatFileReference(AIChatFileReference(path: context.reference, line: nil))
  }

  private func canReuseAIChatContextDraftThread(mode: AIChatThreadMode) -> Bool {
    guard mode == .newThread,
          let thread = selectedAIChatThread,
          thread.messages.isEmpty
    else { return false }
    return !AIChatContextPresentation(currentAIChatDraftForSelectedThread()).contexts.isEmpty
  }

  func mappedPathForOpenClaw(_ path: String) -> String {
    guard let corpusRoot,
          let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes)
    else {
      return path
    }

    let localRoot = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
    if path == localRoot {
      return remoteRoot
    }
    if path.hasPrefix(localRoot + "/") {
      return remoteRoot + "/" + String(path.dropFirst(localRoot.count + 1))
    }
    return path
  }

  public var aiChatContextRootText: String {
    effectiveOpenClawRemoteCorpusPath() ?? "Remote corpus root not configured"
  }

  static func restoreAgendaMode(from defaults: UserDefaults, key: String) -> AgendaMode {
    guard let rawValue = defaults.string(forKey: key),
          let mode = AgendaMode(rawValue: rawValue)
    else {
      return .focus
    }
    return mode
  }

  func migrateLegacyDefaultsIfNeeded(
    legacyDomains: [String],
    defaultOpenClawEndpoint: String
  ) {
    guard !legacyDomains.isEmpty,
          defaults.object(forKey: legacyDefaultsMigrationKey) == nil
    else {
      return
    }

    let keys = [
      corpusKey,
      agendaModeKey,
      openClawEndpointKey,
      openClawAgentKey,
      agentHandoffAssigneeKey,
      personalAssigneeNamesKey,
      openClawRemoteCorpusPathKey,
      aiChatBriefsStartNewThreadKey,
      orgCryptEncryptOnSaveKey,
      orgCryptRecipientsKey,
      orgCryptRecipientFilesKey,
      orgCryptUseDefaultGpgKeyKey,
      orgCryptUseDefaultGpgKeyMigrationKey,
      orgCryptGpgProgramKey
    ]
    let defaultValues: [String: AnyHashable] = [
      openClawEndpointKey: defaultOpenClawEndpoint,
      openClawAgentKey: "main",
      agentHandoffAssigneeKey: Self.defaultAgentHandoffAssignee,
      personalAssigneeNamesKey: "",
      openClawRemoteCorpusPathKey: "",
      aiChatBriefsStartNewThreadKey: true,
      orgCryptGpgProgramKey: "gpg"
    ]

    var migratedAny = false
    for domain in legacyDomains {
      guard let legacyDefaults = UserDefaults(suiteName: domain) else { continue }
      for key in keys {
        guard let value = legacyDefaults.object(forKey: key),
              shouldMigrateDefaultValue(forKey: key, defaultValues: defaultValues)
        else {
          continue
        }
        defaults.set(value, forKey: key)
        migratedAny = true
      }
    }

    defaults.set(true, forKey: legacyDefaultsMigrationKey)
    if migratedAny {
      defaults.synchronize()
    }
  }

  private func shouldMigrateDefaultValue(
    forKey key: String,
    defaultValues: [String: AnyHashable]
  ) -> Bool {
    guard let currentValue = defaults.object(forKey: key) else { return true }
    guard let defaultValue = defaultValues[key] else { return false }
    if let currentString = currentValue as? String,
       let defaultString = defaultValue.base as? String {
      return currentString == defaultString
    }
    if let currentBool = currentValue as? Bool,
       let defaultBool = defaultValue.base as? Bool {
      return currentBool == defaultBool
    }
    return false
  }

  static func shouldIgnoreStandardDefaultsForTests(_ defaults: UserDefaults) -> Bool {
    NSClassFromString("XCTestCase") != nil
      && defaults === UserDefaults.standard
  }

  nonisolated static func shouldMigrateLegacyDefaults(bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
    return bundleIdentifier == "org.org2.workspace"
  }

  nonisolated static func shouldMigrateLegacyDefaultsForCurrentBundle(bundle: Bundle = .main) -> Bool {
    shouldMigrateLegacyDefaults(bundleIdentifier: bundle.bundleIdentifier)
  }

  func restoreCorpusRoot() -> URL? {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults) else {
      return nil
    }

    if let saved = restoreSavedCorpusRoot() {
      return saved
    }

    return mountedCorpora
      .first(where: { isDirectory($0.path) })
      .map { URL(fileURLWithPath: $0.path).standardizedFileURL }
  }

  private func restoreSavedCorpusRoot() -> URL? {
    guard let saved = defaults.string(forKey: corpusKey), isDirectory(saved) else {
      return nil
    }
    return URL(fileURLWithPath: saved).standardizedFileURL
  }

  func restoreOpenClawRemoteCorpusPath(for root: URL) -> String {
    let path = root.standardizedFileURL.path
    if let paths = defaults.dictionary(forKey: openClawRemoteCorpusPathsByCorpusKey) as? [String: String],
       let configured = paths[path] {
      return configured
    }
    // The pre-mount setting belonged to the single saved corpus. Reuse it only
    // for that exact path; a newly mounted corpus must never inherit it.
    if defaults.string(forKey: corpusKey).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == path {
      return defaults.string(forKey: openClawRemoteCorpusPathKey) ?? ""
    }

    // Early multi-corpus builds could persist the mount list without ever
    // writing corpusRoot. If there is exactly one established mount, the old
    // single-corpus OpenClaw path can only belong to that corpus. Promote it to
    // the per-corpus map so later mounts never inherit it.
    let legacyRemotePath = defaults.string(forKey: openClawRemoteCorpusPathKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if defaults.string(forKey: corpusKey) == nil,
       !legacyRemotePath.isEmpty,
       mountedCorpora.count == 1,
       mountedCorpora[0].path == path {
      var paths = defaults.dictionary(forKey: openClawRemoteCorpusPathsByCorpusKey) as? [String: String] ?? [:]
      paths[path] = legacyRemotePath
      defaults.set(paths, forKey: openClawRemoteCorpusPathsByCorpusKey)
      return legacyRemotePath
    }
    return ""
  }

  func currentOpenClawSettings(allowKeychainRead: Bool = false) -> OpenClawGatewaySettings {
    if allowKeychainRead,
       openClawBearerToken == nil,
       openClawHasStoredToken {
      openClawBearerToken = OpenClawKeychain.readToken(allowUserInteraction: true)
      openClawHasStoredToken = openClawBearerToken != nil || OpenClawKeychain.containsToken()
    }

    return OpenClawGatewaySettings.resolve(
      userEndpoint: openClawEndpointText,
      userBearerToken: openClawBearerToken,
      deviceIdentityFileURL: openClawDeviceIdentityFileURL
    )
  }

  func openClawSettings(
    forDestinationID destinationID: String,
    allowKeychainRead: Bool = false
  ) -> OpenClawGatewaySettings {
    guard destinationID != AIChatDestinationConfiguration.openClawID,
          let destination = aiChatDestination(id: destinationID),
          destination.adapter == .openClaw
    else {
      return currentOpenClawSettings(allowKeychainRead: allowKeychainRead)
    }
    let token = allowKeychainRead
      ? AIChatDestinationCredentials.readToken(
          destinationID: destinationID,
          allowUserInteraction: true
        )
      : nil
    return OpenClawGatewaySettings.resolve(
      userEndpoint: destination.endpoint,
      userBearerToken: token,
      deviceIdentityFileURL: openClawDeviceIdentityFileURL
    )
  }

  func currentOrgCryptSettings() -> OrgCryptSettings {
    return OrgCryptSettings(
      encryptOnSave: orgCryptEncryptOnSave,
      recipients: OrgCryptSettings.splitListText(orgCryptRecipientsText),
      recipientFiles: OrgCryptSettings.splitListText(orgCryptRecipientFilesText),
      gpgProgram: orgCryptGpgProgram,
      passphrase: nil,
      useDefaultGpgKey: orgCryptUseDefaultGpgKey
    )
  }

  /// Keychain access can synchronously involve Security.framework and, when
  /// permitted, a user-interaction round trip. Operational crypt paths await
  /// it off MainActor; the synchronous settings snapshot above is retained for
  /// explicit configuration UI/bootstrap state only.
  func currentOrgCryptSettingsForOperation() async -> OrgCryptSettings {
    let encryptOnSave = orgCryptEncryptOnSave
    let recipients = OrgCryptSettings.splitListText(orgCryptRecipientsText)
    let recipientFiles = OrgCryptSettings.splitListText(orgCryptRecipientFilesText)
    let gpgProgram = orgCryptGpgProgram
    let useDefaultGpgKey = orgCryptUseDefaultGpgKey
    let keychain = await Task.detached(priority: .userInitiated) {
      let passphrase = OrgCryptKeychain.readPassphrase(allowUserInteraction: true)
      return (passphrase, passphrase != nil || OrgCryptKeychain.containsPassphrase())
    }.value
    orgCryptHasStoredPassphrase = keychain.1
    return OrgCryptSettings(
      encryptOnSave: encryptOnSave,
      recipients: recipients,
      recipientFiles: recipientFiles,
      gpgProgram: gpgProgram,
      passphrase: keychain.0,
      useDefaultGpgKey: useDefaultGpgKey
    )
  }

  func encryptOrgCryptSubtreesAfterExplicitSave(file: String) async throws -> Int {
    let settings = await currentOrgCryptSettingsForOperation()
    guard settings.encryptOnSave else { return 0 }
    guard let context = captureDocumentCorpusContext(forFile: file) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: file,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    return try await performDocumentMutation(context: context, files: [file]) { execution in
      let url = URL(fileURLWithPath: file)
      let snapshot = try await execution.readSnapshot(at: url)
      let result = try OrgCrypt.encryptPlaintextCryptSubtrees(
        in: snapshot.text,
        file: file,
        settings: settings
      )
      guard result.encryptedCount > 0, result.text != snapshot.text else { return 0 }
      try await execution.commit(result.text, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "org-crypt encryption"
        )
      }
      return result.encryptedCount
    }
  }

  @discardableResult
  func persistAIChatTranscript(recordsMutation: Bool = true) -> Bool {
    if recordsMutation {
      recordAIChatTranscriptMutation()
    }
    let transcriptMutationGeneration = aiChatTranscriptMutationGeneration
    let messageMutationVersions = aiChatThreadMessageMutationVersions
    aiChatTranscriptPersistenceGeneration &+= 1
    deferredAIChatTranscriptPersistenceTask?.cancel()
    deferredAIChatTranscriptPersistenceTask = nil
    if isLoadingAIChatTranscript {
      journalAIChatMutationsDuringTranscriptLoad()
      return true
    }
    hasAuthoritativeAIChatTranscriptState = true
    guard !aiChatTranscriptWritesBlocked else {
      errorText = "AI chat transcript writes are disabled until its storage is recovered."
      return false
    }
    if let aiChatTranscriptSaverForTesting {
      do {
        try aiChatTranscriptSaverForTesting()
        acknowledgeAIChatTranscriptPersistence(
          transcriptMutationGeneration: transcriptMutationGeneration,
          messageMutationVersions: messageMutationVersions
        )
        registerMissingHydratedAIChatThreadsInLRU()
        enforceHydratedAIChatThreadLimit()
        return true
      } catch {
        errorText = "AI chat transcript save failed: \(error.localizedDescription)"
        return false
      }
    }
    enqueueAIChatTranscriptSnapshot(
      aiChatTranscriptSnapshot(),
      legacyURL: aiChatTranscriptURL,
      transcriptMutationGeneration: transcriptMutationGeneration
    )
    return true
  }

  private func aiChatTranscriptSnapshot() -> AIChatTranscriptSnapshot {
    let key = aiChatTranscriptURL.standardizedFileURL.path
    let known = knownAIChatThreadIDsByPath[key, default: []].union(aiChatThreads.map(\.id))
    knownAIChatThreadIDsByPath[key] = known
    return AIChatTranscriptSnapshot(
      threads: aiChatThreads,
      selectedThreadID: selectedAIChatThreadID,
      settlementSettings: aiChatThreadSettlementSettings,
      knownThreadIDs: known
    )
  }

  private func enqueueAIChatTranscriptSnapshot(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL,
    transcriptMutationGeneration: UInt64
  ) {
    let context = captureAIChatCorpusContext()
    let mutationVersions = aiChatThreadMessageMutationVersions
    var snapshot = snapshot
    let key = legacyURL.standardizedFileURL.path
    let known = knownAIChatThreadIDsByPath[key, default: []].union(snapshot.threads.map(\.id))
    snapshot.knownThreadIDs = known
    knownAIChatThreadIDsByPath[key] = known
    let storeGeneration = AIChatTranscriptStore.shared.enqueue(snapshot, legacyURL: legacyURL)
    lastEnqueuedAIChatTranscriptStoreGeneration = (storeGeneration, legacyURL)
    Task { @MainActor [weak self] in
      do {
        try await AIChatTranscriptStore.shared.waitUntilPersisted(
          generation: storeGeneration,
          legacyURL: legacyURL
        )
      } catch {
        guard let self, self.isCurrentAIChatCorpusContext(context) else { return }
        self.errorText = "AI chat transcript save failed: \(error.localizedDescription)"
        return
      }
      guard let self, self.isCurrentAIChatCorpusContext(context) else { return }
      self.acknowledgeAIChatTranscriptPersistence(
        transcriptMutationGeneration: transcriptMutationGeneration,
        messageMutationVersions: mutationVersions
      )
      self.registerMissingHydratedAIChatThreadsInLRU()
      self.enforceHydratedAIChatThreadLimit()
      // Other hosts should see new messages and replies without waiting on
      // the synchronizer's filesystem-watcher delay.
      self.nudgeAIChatStoreSynchronization()
    }
  }

  private func journalAIChatMutationsDuringTranscriptLoad() {
    for thread in aiChatThreads {
      if let index = pendingAIChatThreadsDuringLoad.firstIndex(where: { $0.id == thread.id }) {
        pendingAIChatThreadsDuringLoad[index] = thread
      } else {
        pendingAIChatThreadsDuringLoad.append(thread)
      }
    }
    pendingAIChatSelectionDuringLoad = selectedAIChatThreadID
  }

  /// Commits the transcript as it is now and waits until that state is
  /// durable. Other threads keep streaming while the barrier is written, so by
  /// default a newer mutation does not fail the caller: the state the caller
  /// depends on is already on disk, and the newer mutation is saved on its own
  /// schedule. Treating it as a failure rejected OpenClaw sends with "the
  /// pending turn could not be saved before dispatch" whenever another chat was
  /// active. Pass `requiresNoNewerMutations` when every in-memory change must be
  /// durable, as before quitting.
  func persistAIChatTranscriptDurably(
    context: AIChatCorpusContextToken,
    requiresNoNewerMutations: Bool = false
  ) async -> Bool {
    guard isCurrentAIChatCorpusContext(context),
          !isLoadingAIChatTranscript,
          !aiChatTranscriptWritesBlocked
    else { return false }
    let transcriptMutationGeneration = aiChatTranscriptMutationGeneration
    let mutationVersions = aiChatThreadMessageMutationVersions
    if let aiChatTranscriptSaverForTesting {
      do {
        try aiChatTranscriptSaverForTesting()
      } catch {
        guard isCurrentAIChatCorpusContext(context) else { return false }
        errorText = "AI chat transcript save failed: \(error.localizedDescription)"
        return false
      }
    } else {
      let transcriptURL = URL(fileURLWithPath: context.transcriptPath)
      let generation = AIChatTranscriptStore.shared.enqueueDurabilityBarrier(
        aiChatTranscriptSnapshot(),
        legacyURL: transcriptURL
      )
      lastEnqueuedAIChatTranscriptStoreGeneration = (generation, transcriptURL)
      aiChatDurabilityBarrierDidEnqueueForTesting?(transcriptURL)
      do {
        try await AIChatTranscriptStore.shared.waitUntilPersisted(
          generation: generation,
          legacyURL: transcriptURL
        )
      } catch {
        guard isCurrentAIChatCorpusContext(context) else { return false }
        errorText = "AI chat transcript save failed: \(error.localizedDescription)"
        return false
      }
    }
    guard isCurrentAIChatCorpusContext(context) else { return false }
    acknowledgeAIChatTranscriptPersistence(
      transcriptMutationGeneration: transcriptMutationGeneration,
      messageMutationVersions: mutationVersions
    )
    registerMissingHydratedAIChatThreadsInLRU()
    enforceHydratedAIChatThreadLimit()
    return requiresNoNewerMutations ? !hasUnpersistedAIChatTranscriptMutation : true
  }

  func scheduleAIChatTranscriptPersistenceAfterInteraction(
    recordsMutation: Bool = true
  ) {
    if recordsMutation {
      recordAIChatTranscriptMutation()
    }
    aiChatTranscriptPersistenceGeneration &+= 1
    let generation = aiChatTranscriptPersistenceGeneration
    deferredAIChatTranscriptPersistenceTask?.cancel()
    deferredAIChatTranscriptPersistenceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: self.aiChatTranscriptPersistenceDelayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      if self.isLoadingAIChatTranscript {
        self.journalAIChatMutationsDuringTranscriptLoad()
        self.deferredAIChatTranscriptPersistenceTask = nil
        return
      }
      guard !self.aiChatTranscriptWritesBlocked else {
        self.errorText = "AI chat transcript writes are disabled until its storage is recovered."
        self.deferredAIChatTranscriptPersistenceTask = nil
        return
      }
      if !self.aiChatSendingThreadIDs.isEmpty {
        guard generation == self.aiChatTranscriptPersistenceGeneration else { return }
        self.deferredAIChatTranscriptPersistenceTask = nil
        self.scheduleAIChatTranscriptPersistenceAfterInteraction(recordsMutation: false)
        return
      }
      let transcriptMutationGeneration = self.aiChatTranscriptMutationGeneration
      let messageMutationVersions = self.aiChatThreadMessageMutationVersions
      if let aiChatTranscriptSaverForTesting = self.aiChatTranscriptSaverForTesting {
        do {
          try aiChatTranscriptSaverForTesting()
          self.acknowledgeAIChatTranscriptPersistence(
            transcriptMutationGeneration: transcriptMutationGeneration,
            messageMutationVersions: messageMutationVersions
          )
          self.registerMissingHydratedAIChatThreadsInLRU()
          self.enforceHydratedAIChatThreadLimit()
        } catch {
          self.errorText = "AI chat transcript save failed: \(error.localizedDescription)"
        }
        if generation == self.aiChatTranscriptPersistenceGeneration {
          self.deferredAIChatTranscriptPersistenceTask = nil
        }
        return
      }
      let transcript = AIChatTranscriptState(
        threads: self.aiChatThreads,
        selectedThreadID: self.selectedAIChatThreadID,
        settlementSettings: self.aiChatThreadSettlementSettings
      )
      let transcriptURL = self.aiChatTranscriptURL
      guard generation == self.aiChatTranscriptPersistenceGeneration else { return }
      self.enqueueAIChatTranscriptSnapshot(
        AIChatTranscriptSnapshot(
          threads: transcript.threads,
          selectedThreadID: transcript.selectedThreadID,
          settlementSettings: transcript.settlementSettings
        ),
        legacyURL: transcriptURL,
        transcriptMutationGeneration: transcriptMutationGeneration
      )
      self.deferredAIChatTranscriptPersistenceTask = nil
    }
  }

  public func flushDeferredAIChatTranscriptPersistence() {
    guard aiChatTranscriptLoadTask == nil,
          hasAuthoritativeAIChatTranscriptState
    else { return }
    aiChatTranscriptPersistenceGeneration &+= 1
    deferredAIChatTranscriptPersistenceTask?.cancel()
    deferredAIChatTranscriptPersistenceTask = nil
    _ = persistAIChatTranscript(recordsMutation: false)
  }

  var hasUnpersistedAIChatTranscriptMutation: Bool {
    aiChatTranscriptMutationGeneration != aiChatTranscriptPersistedMutationGeneration
      || !aiChatThreadMessageMutationVersions.isEmpty
  }

  private func recordAIChatTranscriptMutation() {
    aiChatTranscriptMutationGeneration &+= 1
  }

  private func acknowledgeAIChatTranscriptPersistence(
    transcriptMutationGeneration: UInt64,
    messageMutationVersions: [UUID: UInt64]
  ) {
    for (id, version) in messageMutationVersions
    where aiChatThreadMessageMutationVersions[id] == version {
      aiChatThreadMessageMutationVersions.removeValue(forKey: id)
    }
    if aiChatTranscriptMutationGeneration == transcriptMutationGeneration {
      aiChatTranscriptPersistedMutationGeneration = transcriptMutationGeneration
      rememberCleanAIChatTranscriptMetadata()
    }
  }

  private func resetAIChatTranscriptMutationTracking() {
    aiChatTranscriptMutationGeneration = 0
    aiChatTranscriptPersistedMutationGeneration = 0
  }

  /// Simulates the in-memory queue losing a running turn (for example a
  /// transcript refresh rebuilding it) while the provider is still working.
  func forgetAIChatQueueForTesting(_ threadID: UUID) {
    aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
  }

  func waitForAIChatTranscriptLoadForTesting() async {
    if let aiChatTranscriptLoadTask {
      await aiChatTranscriptLoadTask.value
    }
  }

  func waitForAIChatTranscriptPersistenceForTesting() async throws {
    guard let pending = lastEnqueuedAIChatTranscriptStoreGeneration else { return }
    try await AIChatTranscriptStore.shared.waitUntilPersisted(
      generation: pending.generation,
      legacyURL: pending.url
    )
  }

  func waitForAIChatThreadHydrationForTesting(_ id: UUID) async {
    if let task = aiChatThreadHydrationTasks[id] { await task.value }
  }

  func waitForAIChatHydrationCommitForTesting(_ id: UUID) async {
    if let task = pendingAIChatHydrationCommitTasks[id] { await task.value }
  }

  func aiChatThreadMessageMutationVersionForTesting(_ id: UUID) -> UInt64? {
    aiChatThreadMessageMutationVersions[id]
  }

  func setAIChatTranscriptWritesBlockedForTesting(_ blocked: Bool) {
    aiChatTranscriptWritesBlocked = blocked
  }

  var hasUnpersistedAIChatTranscriptMutationForTesting: Bool {
    hasUnpersistedAIChatTranscriptMutation
  }

  func persistSelectedAIChatThread() {
    let transcriptPath = aiChatTranscriptURL.standardizedFileURL.path
    var selections = defaults.dictionary(forKey: selectedAIChatThreadsByTranscriptKey)
      as? [String: String] ?? [:]
    if let selectedAIChatThreadID {
      selections[transcriptPath] = selectedAIChatThreadID.uuidString.lowercased()
    } else {
      selections.removeValue(forKey: transcriptPath)
    }
    defaults.set(selections, forKey: selectedAIChatThreadsByTranscriptKey)
  }

  func restoredSelectedAIChatThreadID() -> UUID? {
    let transcriptPath = aiChatTranscriptURL.standardizedFileURL.path
    guard let selections = defaults.dictionary(forKey: selectedAIChatThreadsByTranscriptKey)
      as? [String: String],
          let rawID = selections[transcriptPath]
    else {
      return nil
    }
    return UUID(uuidString: rawID)
  }

  nonisolated static func shouldLoadAIChatTranscriptAsynchronously(_ url: URL) -> Bool {
    let storeURL = AIChatTranscriptStore.storeDirectory(for: url)
    let manifestURL = storeURL.appendingPathComponent("manifest.json")
    if let size = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       size > 256_000 {
      return true
    }
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
    return size > 1_000_000
  }

  nonisolated private static func prepareInitialAIChatTranscriptLoad(
    _ loaded: AIChatWorkspaceTranscriptLoad,
    preferredSelectedThreadID: UUID?
  ) -> AIChatPreparedWorkspaceTranscriptLoad {
    guard !Task.isCancelled else {
      return AIChatPreparedWorkspaceTranscriptLoad(loaded: loaded, presentations: [])
    }
    let selectedID = [preferredSelectedThreadID, loaded.transcript.selectedThreadID]
      .compactMap { $0 }
      .first { id in loaded.transcript.threads.contains(where: { $0.id == id }) }
      ?? loaded.transcript.threads.first?.id
    let selectedThread = selectedID.flatMap { id in
      loaded.transcript.threads.first(where: { $0.id == id })
    }
    let presentations = selectedThread.map {
      prepareInitialAIChatMessagePresentations(
        messages: $0.messages,
        isSharedRoom: $0.isSharedRoom
      )
    } ?? []
    return AIChatPreparedWorkspaceTranscriptLoad(
      loaded: loaded,
      presentations: presentations
    )
  }

  func restartAIChatRepairTimer() {
    aiChatRepairTask?.cancel()
    aiChatRepairTask = nil
    guard isWorkspaceRealtimeRefreshActive, aiChatRepairIntervalSeconds.isFinite,
          aiChatRepairIntervalSeconds >= 10, aiChatRepairIntervalSeconds <= 86_400 else { return }
    let interval = aiChatRepairIntervalSeconds
    aiChatRepairTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(interval)) } catch { return }
        guard let self, !Task.isCancelled else { return }
        let url = self.aiChatTranscriptURL
        do {
          let report = try await Task.detached(priority: .utility) {
            try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true)
          }.value
          guard !Task.isCancelled, url == self.aiChatTranscriptURL else { continue }
          self.aiChatRepairError = report.warnings.first
          if report.checked { self.scheduleSyncedAIChatTranscriptRefresh() }
        } catch {
          guard !Task.isCancelled, url == self.aiChatTranscriptURL else { continue }
          self.aiChatRepairError = error.localizedDescription
        }
      }
    }
  }

  func scheduleSyncedAIChatTranscriptRefresh() {
    syncedAIChatRefreshNeeded = true
    guard syncedAIChatRefreshTask == nil else { return }
    syncedAIChatRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, !Task.isCancelled else { return }
        guard self.syncedAIChatRefreshNeeded else { break }
        self.syncedAIChatRefreshNeeded = false
        if !(await self.refreshSyncedAIChatTranscript()) {
          self.syncedAIChatRefreshNeeded = true
          try? await Task.sleep(for: .seconds(1))
        }
      }
      self?.syncedAIChatRefreshTask = nil
    }
  }

  private func aiChatTranscriptMetadata() -> [UUID: AIChatThread] {
    Dictionary(uniqueKeysWithValues: aiChatThreads.map {
      // Reading a conversation is local presentation state, not an edit that
      // should prevent its next remote reply from arriving.
      ($0.id, $0.metadataOnly().replacingAIChatMetadata(unreadMessageCount: 0))
    })
  }

  func rememberCleanAIChatTranscriptMetadata() {
    let previous = syncedAIChatCleanMetadata
    syncedAIChatCleanMetadata = aiChatTranscriptMetadata()
    // A thread changed here must be re-imported from its next committed source.
    for id in Array(syncedAIChatAppliedSources.keys)
      where syncedAIChatCleanMetadata[id] != previous[id] {
      syncedAIChatAppliedSources.removeValue(forKey: id)
    }
    syncedAIChatCleanSettlementSettings = aiChatThreadSettlementSettings
  }

  private func locallyProtectedAIChatThreadIDs(
    metadata: [UUID: AIChatThread]
  ) -> Set<UUID> {
    var ids = aiChatSendingThreadIDs.union(drainingAIChatThreadIDs.filter {
      isAIChatRuntimeStateVisible(for: $0)
    })
    ids.formUnion(aiChatThreadMessageMutationVersions.keys)
    if hasUnpersistedAIChatTranscriptMutation {
      // Include locally deleted IDs so an incoming replica cannot resurrect them.
      ids.formUnion(Set(metadata.keys).union(syncedAIChatCleanMetadata.keys).filter {
        metadata[$0] != syncedAIChatCleanMetadata[$0]
      })
    }
    return ids
  }

  /// Refresh replicas without dispatching agent work or writing viewed history.
  /// Only locally active/edited threads are protected; unrelated chats remain live.
  @discardableResult
  func refreshSyncedAIChatTranscript() async -> Bool {
    guard hasAuthoritativeAIChatTranscriptState, !isLoadingAIChatTranscript else { return false }
    if aiChatTranscriptWritesBlocked {
      retryAIChatTranscriptRecovery()
      return false
    }
    let target = aiChatTranscriptURL
    let loadGeneration = aiChatTranscriptLoadGeneration
    let metadataBeforeRead = aiChatTranscriptMetadata()
    let revisionsBeforeRead = aiChatThreadMessageRevisions
    let settingsBeforeRead = aiChatThreadSettlementSettings
    var protectedIDs = locallyProtectedAIChatThreadIDs(metadata: metadataBeforeRead)
    let targetPath = target.standardizedFileURL.path
    // Fingerprint before reading: a commit that lands during the read changes
    // it again, so the next refresh still picks that commit up.
    let fingerprint = await Task.detached(priority: .userInitiated) {
      AIChatTranscriptStore.shared.committedStateFingerprint(legacyURL: target)
    }.value
    guard target == aiChatTranscriptURL, loadGeneration == aiChatTranscriptLoadGeneration,
          !isLoadingAIChatTranscript else { return false }
    if let applied = syncedAIChatAppliedState,
       applied.allowsSkipping(
         transcriptPath: targetPath,
         transcriptGeneration: loadGeneration,
         fingerprint: fingerprint,
         protectedThreadIDs: locallyProtectedAIChatThreadIDs(metadata: aiChatTranscriptMetadata())
       ) {
      syncedAIChatRefreshSkipCountForTesting &+= 1
      return true
    }
    let loaded = await Task.detached(priority: .utility) {
      AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: target)
    }.value
    guard target == aiChatTranscriptURL, loadGeneration == aiChatTranscriptLoadGeneration,
          !isLoadingAIChatTranscript else { return false }
    guard let loaded else { return true }
    // A sync provider may deliver the commit marker before its immutable shards.
    guard loaded.recoveryStatus == .healthy else { return false }
    let currentMetadata = aiChatTranscriptMetadata()
    protectedIDs.formUnion(locallyProtectedAIChatThreadIDs(metadata: currentMetadata))
    // A local edit may also finish saving while the detached read is in flight.
    protectedIDs.formUnion(Set(currentMetadata.keys).union(metadataBeforeRead.keys).filter {
      currentMetadata[$0] != metadataBeforeRead[$0]
        || aiChatThreadMessageRevisions[$0] != revisionsBeforeRead[$0]
    })
    // Threads whose committed source is unchanged since the last import keep
    // their in-memory copy. Re-importing all of them on every remote commit
    // discarded loaded messages and re-sorted the whole history each time a
    // streaming reply on another Mac saved, several times a second.
    let currentIDs = Set(aiChatThreads.map(\.id))
    let sourcesByID = Dictionary(
      loaded.snapshot.threads.compactMap { thread -> (UUID, SyncedAIChatThreadSource)? in
        loaded.shardDigests[thread.id].map {
          (thread.id, SyncedAIChatThreadSource(shardDigest: $0, metadata: thread.metadataOnly()))
        }
      },
      uniquingKeysWith: { first, _ in first }
    )
    let keptIDs = Set(sourcesByID.compactMap { id, source -> UUID? in
      guard !protectedIDs.contains(id),
            currentIDs.contains(id),
            syncedAIChatCleanMetadata[id] != nil,
            syncedAIChatAppliedSources[id] == source
      else { return nil }
      return id
    })
    let importedCandidates = migrateAIChatThreadDestinations(
      loaded.snapshot.threads.filter { !protectedIDs.contains($0.id) && !keptIDs.contains($0.id) }
    )
    let imported = aiChatReadState.applying(
      to: Self.interruptUnresolvedAIChatSteers(
        in: Self.settlingAnsweredOpenCodeRemoteTurns(in: importedCandidates).threads,
        inFlightSteerIDs: aiChatInFlightSteerMessageIDs
      ).threads,
      transcriptURL: target
    )
    let preserved = aiChatThreads.filter { protectedIDs.contains($0.id) || keptIDs.contains($0.id) }
    let refreshedIDs = Set(currentMetadata.keys).union(imported.map(\.id))
      .subtracting(protectedIDs).subtracting(keptIDs)
    let pendingBeforeRefresh = aiChatPendingUserMessageIDsByThreadID
    saveAIChatComposerForSelectedThread()
    for id in refreshedIDs {
      aiChatThreadHydrationTasks.removeValue(forKey: id)?.cancel()
      aiChatThreadHydrationTaskTokens.removeValue(forKey: id)
      discardPendingAIChatHydrationCommit(for: id)
      aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: id)
      aiChatThreadMessageRevisions.removeValue(forKey: id)
      syncedAIChatCleanMetadata.removeValue(forKey: id)
    }
    unloadedAIChatThreadIDs = unloadedAIChatThreadIDs.intersection(protectedIDs.union(keptIDs))
      .union(loaded.unloadedThreadIDs.subtracting(protectedIDs).subtracting(keptIDs))
    isApplyingPersistedAIChatThreads = true
    defer { isApplyingPersistedAIChatThreads = false }
    let refreshedThreads = Self.sortedAIChatThreadsForDisplay(preserved + imported)
    if refreshedThreads != aiChatThreads {
      aiChatThreads = refreshedThreads
    }
    syncedAIChatAppliedSources = syncedAIChatAppliedSources.filter { keptIDs.contains($0.key) }
    for thread in imported {
      if let source = sourcesByID[thread.id] { syncedAIChatAppliedSources[thread.id] = source }
    }
    syncedAIChatRefreshKeptCountForTesting = keptIDs.count
    knownAIChatThreadIDsByPath[target.standardizedFileURL.path, default: []]
      .formUnion(imported.map(\.id))
    for thread in imported {
      syncedAIChatCleanMetadata[thread.id] = thread.metadataOnly()
        .replacingAIChatMetadata(unreadMessageCount: 0)
      aiChatThreadMessageMutationCounter &+= 1
      aiChatThreadMessageRevisions[thread.id] = aiChatThreadMessageMutationCounter
      let pendingMessages = thread.messages.filter {
        $0.role == .user && $0.deliveryStatus == .sending && $0.deliveryKind != .steer
      }
      let pending = pendingMessages.map(\.id)
      if !pending.isEmpty { aiChatPendingUserMessageIDsByThreadID[thread.id] = pending }
      let previouslyQueuedHere = Set(pendingBeforeRefresh[thread.id] ?? [])
      var resumesLocalQueue = false
      for message in pendingMessages {
        // Only this process's own queue (or a hand-off it accepts below) may
        // dispatch; everything else is another host's in-flight work.
        if previouslyQueuedHere.contains(message.id),
           !aiChatForeignPendingMessageIDs.contains(message.id) {
          resumesLocalQueue = true
        } else {
          aiChatForeignPendingMessageIDs.insert(message.id)
        }
      }
      if resumesLocalQueue, !drainingAIChatThreadIDs.contains(thread.id) {
        let threadID = thread.id
        Task { @MainActor [weak self] in await self?.drainAIChatSendQueue(for: threadID) }
      }
    }
    AIChatTranscriptStore.shared.recordAdoptedThreads(imported, legacyURL: target)
    if aiChatThreadSettlementSettings == syncedAIChatCleanSettlementSettings,
       aiChatThreadSettlementSettings == settingsBeforeRead {
      aiChatThreadSettlementSettings = loaded.snapshot.settlementSettings
      syncedAIChatCleanSettlementSettings = loaded.snapshot.settlementSettings
    }
    let selectedID = selectedAIChatThreadID.flatMap { id in
      aiChatThreads.contains(where: { $0.id == id }) ? id : nil
    } ?? aiChatThreads.first?.id
    if let selectedID {
      if selectedID != selectedAIChatThreadID
          || !(protectedIDs.contains(selectedID) || keptIDs.contains(selectedID)) {
        selectAIChatThread(selectedID, persistsSelection: false)
      }
    } else {
      selectedAIChatThreadID = nil
      aiChatDraft = ""
      aiChatPendingAttachments = []
      replaceAIChatMessages([], shouldPersist: false)
      syncSelectedAIChatSendState()
    }
    initializeHydratedAIChatThreadLRU()
    processAIChatHandoffs()
    // A replica can still carry this host's sends from before a restart.
    for thread in imported {
      repairStaleLocalAIChatSends(in: thread.id, transcriptURL: target)
    }
    syncedAIChatAppliedState = fingerprint.map {
      SyncedAIChatAppliedState(
        transcriptPath: targetPath,
        transcriptGeneration: loadGeneration,
        fingerprint: $0,
        protectedThreadIDs: protectedIDs
      )
    }
    return true
  }

  // MARK: - Cross-host chat presence, provenance, and routing

  /// Configures the per-installation transcript writer before any store is
  /// created. Each process owns one head file in the shared chat store.
  nonisolated public static func configureAIChatTranscriptWriter(
    defaults: UserDefaults,
    label: String? = nil
  ) {
    AIChatTranscriptStore.shared.configureWriter(
      .persistent(defaults: defaults, label: label)
    )
  }

  /// Sets the identity recorded in message provenance and presence records.
  public func configureAIChatHost(_ identity: AIChatHostIdentity) {
    AIChatLocalHostRegistry.shared.register(identity.ref)
    guard identity != aiChatHostIdentity else { return }
    aiChatHostIdentity = identity
    lastPublishedAIChatLiveRecord = nil
  }

  func aiChatUserMessageProvenance(
    origin: AIChatMessageProvenance?,
    routedTo target: AIChatHostIdentity?,
    at date: Date
  ) -> AIChatMessageProvenance {
    let host = aiChatHostIdentity
    return AIChatMessageProvenance(
      originClient: origin?.originClient ?? (host.kind == .desktop ? .desktop : nil),
      originDeviceName: origin?.originDeviceName,
      receivedByHostRef: host.ref,
      receivedByHostName: host.name,
      executionHostRef: target?.ref ?? host.ref,
      executionHostName: target?.name ?? host.name,
      acceptedAt: target == nil ? date : nil,
      requestedByLabel: origin?.requestedByLabel,
      requestedByDestinationID: origin?.requestedByDestinationID,
      requestedByMessageID: origin?.requestedByMessageID
    )
  }

  /// The reply ID for a managed remote OpenCode turn. The turn keeps running
  /// on its harness host, so more than one OpenOrg host may collect it (the
  /// host that started it after waking, and a host on the harness machine
  /// while the first was asleep). A shared ID lets their copies merge.
  nonisolated static func openCodeRemoteReplyID(for userMessageID: UUID) -> UUID {
    let digest = SHA256.hash(data: Data("openorg-opencode-remote-reply:\(userMessageID.uuidString.lowercased())".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  /// The host whose runtime most recently handled the conversation.
  func aiChatExecutionHostRef(for messages: [AIChatMessage]) -> String? {
    messages.last(where: { $0.provenance?.executionHostRef != nil })?.provenance?.executionHostRef
  }

  private func freshAIChatRemoteHost(ref: String, now: Date = Date()) -> AIChatLiveHostRecord? {
    aiChatRemoteLiveHosts.first {
      $0.hostRef == ref && $0.isFresh(now: now, within: aiChatLiveFreshnessInterval)
    }
  }

  /// The online host that should run the next turn of `thread`, or nil to run
  /// it here. A conversation stays with the host that already runs it while
  /// that host is online and has the destination enabled; otherwise this host
  /// takes over so a message never waits on an unreachable machine.
  func aiChatRoutingTarget(
    for thread: AIChatThread,
    destinationID: String
  ) -> AIChatLiveHostRecord? {
    guard aiChatRoutesTurnsToThreadHost, !thread.isSharedRoom else { return nil }
    let now = Date()
    func routable(_ ref: String) -> AIChatLiveHostRecord? {
      aiChatRemoteLiveHosts.first {
        $0.hostRef == ref && $0.isRoutable(now: now, within: aiChatLiveFreshnessInterval)
          && $0.enabledDestinationIDs.contains(destinationID)
      }
    }
    let ownerRef = aiChatExecutionHostRef(for: aiChatMessages(for: thread.id))
    if let ownerRef, ownerRef != aiChatHostIdentity.ref, let owner = routable(ownerRef) {
      return owner
    }
    // Detachable client: hand conversations this Mac would run (new, or
    // already run here) to the preferred headless host while it is online.
    if ownerRef == nil || ownerRef == aiChatHostIdentity.ref || ownerRef.map({ routable($0) == nil }) == true,
       let preferred = aiChatPreferredExecutionHostRef, preferred != aiChatHostIdentity.ref,
       let target = routable(preferred) {
      return target
    }
    // While this host drains for a restart, any other online host with the
    // destination takes new turns.
    if isAIChatDraining {
      return aiChatRemoteLiveHosts
        .filter { $0.isRoutable(now: now, within: aiChatLiveFreshnessInterval) && $0.enabledDestinationIDs.contains(destinationID) }
        .sorted { ($0.hostKind == .server ? 0 : 1, $0.hostName) < ($1.hostKind == .server ? 0 : 1, $1.hostName) }
        .first
    }
    return nil
  }

  /// Online hosts that could own this Mac's new agent turns.
  public var aiChatExecutionHostCandidates: [AIChatLiveHostRecord] {
    let now = Date()
    var seen = Set<String>()
    return aiChatRemoteLiveHosts
      .filter { $0.hostRef != aiChatHostIdentity.ref && $0.isFresh(now: now, within: aiChatLiveFreshnessInterval) }
      .sorted { $0.updatedAt > $1.updatedAt }
      .filter { seen.insert($0.hostRef).inserted }
      .sorted { ($0.hostKind == .server ? 0 : 1, $0.hostName) < ($1.hostKind == .server ? 0 : 1, $1.hostName) }
  }

  /// Number of turns this host is running now.
  public var aiChatRunningTurnCountOnCurrentHost: Int {
    aiChatThreads.filter { isAIChatThreadRunningOnCurrentHost($0.id) }.count
  }

  /// Stops accepting new turns and announces it, so clients route new work to
  /// another host while running turns finish. Used before restarts and updates.
  public func beginAIChatDrain() {
    guard !isAIChatDraining else { return }
    isAIChatDraining = true
    publishAIChatLivePresenceIfNeeded(force: true)
  }

  public func endAIChatDrain() {
    guard isAIChatDraining else { return }
    isAIChatDraining = false
    publishAIChatLivePresenceIfNeeded(force: true)
    processAIChatHandoffs()
  }

  /// Waits until this host runs no turns or `timeout` elapses. Returns the
  /// number of turns still running.
  public func waitForAIChatTurnsToFinish(timeout: TimeInterval, pollInterval: TimeInterval = 0.5) async -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while aiChatRunningTurnCountOnCurrentHost > 0, Date() < deadline, !Task.isCancelled {
      try? await Task.sleep(nanoseconds: UInt64(max(0.05, pollInterval) * 1_000_000_000))
    }
    return aiChatRunningTurnCountOnCurrentHost
  }

  /// A turn currently running on another host, as published in its presence
  /// record.
  public func aiChatRemoteLiveTurn(for threadID: UUID) -> AIChatRemoteLiveTurn? {
    let now = Date()
    for record in aiChatRemoteLiveHosts
    where record.hostRef != aiChatHostIdentity.ref
      && record.isFresh(now: now, within: aiChatLiveFreshnessInterval) {
      if let turn = record.turns.first(where: { $0.threadID == threadID }) {
        return AIChatRemoteLiveTurn(host: record.host, turn: turn, updatedAt: record.updatedAt)
      }
    }
    return nil
  }

  /// The machine where the conversation's agent harness runs when its
  /// destination is a remote (SSH or endpoint) harness. Message provenance
  /// records the OpenOrg host that drove the turn, which is a different
  /// machine in that case, so labels such as "OpenCode on press" use this.
  public func aiChatHarnessHostName(for threadID: UUID) -> String? {
    let destinationID = aiChatRemoteLiveTurn(for: threadID)?.turn.destinationID
      ?? aiChatActiveDestinationID(for: threadID)
    return destinationID.flatMap { aiChatDestination(id: $0)?.harnessHostName }
  }

  /// `aiChatHarnessHostName(for:)` for a thread the caller already holds.
  public func aiChatHarnessHostName(for thread: AIChatThread) -> String? {
    let destinationID = aiChatRemoteLiveTurn(for: thread.id)?.turn.destinationID
      ?? aiChatActiveDestinationID(for: thread)
    return destinationID.flatMap { aiChatDestination(id: $0)?.harnessHostName }
  }

  /// A readable name for the host running or last running this conversation.
  public func aiChatExecutionHostName(for threadID: UUID) -> String? {
    if let harnessHost = aiChatHarnessHostName(for: threadID) { return harnessHost }
    if isAIChatThreadRunningOnCurrentHost(threadID) { return aiChatHostIdentity.name }
    if let remote = aiChatRemoteLiveTurn(for: threadID) { return remote.host.name }
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else { return nil }
    return thread.messages.last(where: { $0.provenance?.executionHostName != nil })?
      .provenance?.executionHostName
  }

  /// A provenance caption for display on this host. Messages that were sent
  /// and answered entirely here return nil to keep ordinary chats quiet.
  public func aiChatProvenanceCaption(for message: AIChatMessage) -> String? {
    guard let provenance = message.provenance else { return nil }
    let here = aiChatHostIdentity.ref
    let isLocal = (provenance.receivedByHostRef ?? here) == here
      && (provenance.executionHostRef ?? here) == here
      && (provenance.originClient == nil || provenance.originClient == .desktop)
    if isLocal, provenance.isAgentTurnRequest {
      // Keep the hand-off visible; only the host details are redundant here.
      return provenance.requestedByLabel.map { "requested by \($0)" }
    }
    guard !isLocal else { return nil }
    return provenance.caption(role: message.role)
  }

  /// A remote host still owns this `sending` message only while its presence
  /// is fresh and either reports the turn or has not refreshed since the
  /// message was handed to it.
  func isAIChatMessageActiveOnRemoteHost(_ message: AIChatMessage, in threadID: UUID) -> Bool? {
    guard let ref = message.provenance?.executionHostRef, ref != aiChatHostIdentity.ref else {
      return nil
    }
    guard let record = freshAIChatRemoteHost(ref: ref) else {
      // Unknown presence (an older build, or no presence synchronized yet):
      // keep the historical behavior and trust the persisted marker.
      return aiChatRemoteLiveHosts.contains(where: { $0.hostRef == ref }) ? false : nil
    }
    if record.turns.contains(where: { $0.threadID == threadID }) { return true }
    // A hand-off the target has not accepted yet is still in flight.
    guard let acceptedAt = message.provenance?.acceptedAt else { return true }
    return record.updatedAt < acceptedAt.addingTimeInterval(20)
  }

  public func setAIChatLivePresenceActive(_ active: Bool) {
    if active {
      guard aiChatLivePresenceTask == nil else { return }
      scheduleAIChatLiveRefresh()
      aiChatLivePresenceTask = Task { @MainActor [weak self] in
        var tick = 0
        while !Task.isCancelled {
          guard let self else { return }
          self.publishAIChatLivePresenceIfNeeded()
          if tick % 5 == 0 {
            self.processAIChatHandoffs()
            self.adoptOrphanedOpenCodeTurns()
          }
          if tick % 15 == 0 { self.scheduleAIChatLiveRefresh() }
          if tick % 60 == 30 { Task { await self.dispatchPluginHooksIfOwner() } }
          tick &+= 1
          try? await Task.sleep(nanoseconds: self.aiChatLivePresenceTickNanoseconds)
        }
      }
    } else {
      aiChatLivePresenceTask?.cancel()
      aiChatLivePresenceTask = nil
      publishAIChatOfflinePresence()
    }
  }

  private func currentAIChatLiveRecord() -> AIChatLiveHostRecord {
    let turns = aiChatThreads.compactMap { thread -> AIChatLiveTurnRecord? in
      guard isAIChatThreadRunningOnCurrentHost(thread.id) else { return nil }
      let snapshot = aiChatLivePresentationSnapshot(for: thread.id)
      let destinationID = aiChatActiveDestinationID(for: thread)
      let activities = aiChatRunActivities(for: thread.id)
        .suffix(AIChatLiveHostDirectory.maximumActivities)
        .map { activity in
          AIChatRunActivity(
            id: activity.id,
            runID: activity.runID,
            kind: activity.kind,
            title: String(activity.title.prefix(200)),
            detail: activity.detail.map { String($0.prefix(400)) },
            status: activity.status,
            updatedAt: activity.updatedAt
          )
        }
      return AIChatLiveTurnRecord(
        threadID: thread.id,
        userMessageID: activeAIChatUserMessageIDByThreadID[thread.id],
        destinationID: destinationID,
        destinationName: destinationID.map(aiChatDestinationTitle),
        startedAt: aiChatRequestStartedAtByThreadID[thread.id],
        streamingReply: AIChatLiveHostDirectory.boundedTail(
          snapshot.streamingReply,
          maximum: AIChatLiveHostDirectory.maximumStreamingCharacters
        ),
        reasoning: AIChatLiveHostDirectory.boundedTail(
          snapshot.reasoning,
          maximum: AIChatLiveHostDirectory.maximumReasoningCharacters
        ),
        activities: Array(activities)
      )
    }
    let authenticationNeeded = aiChatAuthenticationNeededDestinationIDs()
    return AIChatLiveHostRecord(
      writerID: AIChatTranscriptStore.shared.writerIdentity.id,
      host: aiChatHostIdentity,
      enabledDestinationIDs: enabledAIChatDestinations.map(\.id).sorted(),
      turns: turns,
      authenticationNeededDestinationIDs: authenticationNeeded.isEmpty ? nil : authenticationNeeded,
      isDraining: isAIChatDraining ? true : nil
    )
  }

  func publishAIChatLivePresenceIfNeeded(force: Bool = false) {
    guard corpusRoot != nil, hasAuthoritativeAIChatTranscriptState else { return }
    let transcriptURL = aiChatTranscriptURL.standardizedFileURL
    if let previousURL = lastPublishedAIChatLiveTranscriptURL, previousURL != transcriptURL {
      publishAIChatOfflinePresence()
    }
    let record = currentAIChatLiveRecord()
    let now = Date()
    let contentChanged = lastPublishedAIChatLiveRecord.map { !$0.hasSameContent(as: record) } ?? true
    let heartbeatDue = lastPublishedAIChatLiveRecord.map {
      now.timeIntervalSince($0.updatedAt) >= aiChatLiveHeartbeatInterval
    } ?? true
    guard force || contentChanged || heartbeatDue else { return }
    lastPublishedAIChatLiveRecord = record
    lastPublishedAIChatLiveTranscriptURL = transcriptURL
    let root = corpusRoot
    Task.detached(priority: .utility) {
      try? AIChatLiveHostDirectory.write(record, transcriptURL: transcriptURL)
      if contentChanged {
        SyncthingScanHint.shared.scan(
          path: AIChatLiveHostDirectory.directory(forTranscript: transcriptURL),
          corpusRoot: root
        )
      }
    }
  }

  private func publishAIChatOfflinePresence() {
    guard let url = lastPublishedAIChatLiveTranscriptURL,
          var record = lastPublishedAIChatLiveRecord
    else { return }
    record.isOnline = false
    record.turns = []
    record.updatedAt = Date()
    lastPublishedAIChatLiveRecord = nil
    lastPublishedAIChatLiveTranscriptURL = nil
    try? AIChatLiveHostDirectory.write(record, transcriptURL: url)
    SyncthingScanHint.shared.scan(
      path: AIChatLiveHostDirectory.directory(forTranscript: url),
      corpusRoot: corpusRoot
    )
  }

  /// Ask the synchronization provider to propagate committed chat changes now.
  func nudgeAIChatStoreSynchronization() {
    SyncthingScanHint.shared.scan(
      path: AIChatTranscriptStore.storeDirectory(for: aiChatTranscriptURL),
      corpusRoot: corpusRoot
    )
  }

  func scheduleAIChatLiveRefresh() {
    aiChatLiveRefreshNeeded = true
    guard aiChatLiveRefreshTask == nil else { return }
    aiChatLiveRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self, self.aiChatLiveRefreshNeeded else { break }
        self.aiChatLiveRefreshNeeded = false
        await self.refreshAIChatRemoteLiveHosts()
      }
      self?.aiChatLiveRefreshTask = nil
    }
  }

  func refreshAIChatRemoteLiveHosts() async {
    let transcriptURL = aiChatTranscriptURL.standardizedFileURL
    let writerID = AIChatTranscriptStore.shared.writerIdentity.id
    let records = await Task.detached(priority: .utility) {
      AIChatLiveHostDirectory.readAll(transcriptURL: transcriptURL, excludingWriterID: writerID)
    }.value
    guard transcriptURL == aiChatTranscriptURL.standardizedFileURL else { return }
    let hostRef = aiChatHostIdentity.ref
    let visible = records.filter { $0.hostRef != hostRef }.sorted { $0.hostRef < $1.hostRef }
    if visible != aiChatRemoteLiveHosts {
      aiChatRemoteLiveHosts = visible
      syncSelectedAIChatSendState()
    }
  }

  /// Accept conversations another host handed to this one, and take back
  /// hand-offs whose target went away.
  /// A managed remote OpenCode turn keeps running on its harness machine when
  /// the OpenOrg host that started it sleeps or quits, but only that host
  /// records the reply. When the turn ran on this machine and finished while
  /// its host is offline, deliver it here so paired phones see the reply
  /// without waiting for the laptop to wake. The finished record stays for
  /// the starting host, which writes the same reply ID when it reconnects.
  func adoptOrphanedOpenCodeTurns(now: Date = Date()) {
    guard hasAuthoritativeAIChatTranscriptState,
          !isLoadingAIChatTranscript,
          !aiChatTranscriptWritesBlocked,
          !isPreparingForTermination
    else { return }
    let directory = openCodeLocalRunDirectory
    for thread in aiChatThreads where !thread.isSharedRoom {
      guard let pendingTurn = thread.pendingTurn,
            let ownerID = pendingTurn.dispatchOwnerID,
            ownerID != Self.aiChatDispatchOwnerID,
            !adoptingOpenCodeTurnThreadIDs.contains(thread.id),
            FileManager.default.fileExists(
              atPath: directory.appendingPathComponent(
                "\(thread.id.uuidString.lowercased()).json"
              ).path
            )
      else { continue }
      if thread.storedMessageCount != nil {
        if aiChatHandoffHydrationRequests.insert(thread.id).inserted {
          Task { @MainActor [weak self] in
            let hydrated = await self?.hydrateAIChatThreadIfNeeded(thread.id)
            if hydrated == nil { self?.aiChatHandoffHydrationRequests.remove(thread.id) }
          }
        }
        continue
      }
      guard let user = thread.messages.first(where: {
              $0.id == pendingTurn.userMessageID && $0.role == .user && $0.deliveryStatus == .sending
            }),
            let hostRef = user.provenance?.executionHostRef,
            hostRef != aiChatHostIdentity.ref,
            freshAIChatRemoteHost(ref: hostRef, now: now) == nil
      else { continue }
      let threadID = thread.id
      adoptingOpenCodeTurnThreadIDs.insert(threadID)
      Task { @MainActor [weak self] in
        let outcome = await OpenCodeClient.finishedLocalRun(
          threadID: threadID,
          runToken: pendingTurn.runID,
          directory: directory
        )
        guard let self else { return }
        defer { self.adoptingOpenCodeTurnThreadIDs.remove(threadID) }
        guard let outcome else { return }
        await self.deliverAdoptedOpenCodeTurn(outcome, pendingTurn: pendingTurn, threadID: threadID)
      }
    }
  }

  private func deliverAdoptedOpenCodeTurn(
    _ outcome: Result<OpenCodeTurnResult, OpenCodeError>,
    pendingTurn: AIChatPendingTurn,
    threadID: UUID
  ) async {
    // Re-check: the starting host may have delivered it while this was read.
    guard let thread = aiChatThread(threadID, transcriptURL: aiChatTranscriptURL),
          thread.pendingTurn?.runID == pendingTurn.runID,
          thread.messages.contains(where: {
            $0.id == pendingTurn.userMessageID && $0.deliveryStatus == .sending
          })
    else { return }
    let destinationID = pendingTurn.destinationID ?? thread.destinationID
    switch outcome {
    case .success(let result):
      persistRuntimeSessionID(
        result.sessionID,
        destinationID: destinationID,
        thread: thread,
        transcriptURL: aiChatTranscriptURL
      )
      let reply = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = insertAIChatReply(
        reply.isEmpty ? "OpenCode completed the turn without a text response." : reply,
        after: pendingTurn.userMessageID,
        in: threadID,
        changeSummary: nil,
        replyID: Self.openCodeRemoteReplyID(for: pendingTurn.userMessageID)
      )
    case .failure(let error):
      await failPendingAIChatTurnDefinitively(
        pendingTurn,
        in: threadID,
        failureText: error.localizedDescription
      )
    }
    aiChatForeignPendingMessageIDs.remove(pendingTurn.userMessageID)
    removePendingAIChatUserMessage(pendingTurn.userMessageID, in: threadID)
    nudgeAIChatStoreSynchronization()
    // Messages queued here behind the orphaned turn may run now.
    if !aiChatPendingUserMessageIDs(for: threadID).isEmpty {
      await drainAIChatSendQueue(for: threadID)
    }
  }

  func processAIChatHandoffs(now: Date = Date()) {
    guard hasAuthoritativeAIChatTranscriptState,
          !isLoadingAIChatTranscript,
          !aiChatTranscriptWritesBlocked,
          !isPreparingForTermination
    else { return }
    let hostRef = aiChatHostIdentity.ref
    for thread in aiChatThreads where !thread.isSettled {
      if thread.storedMessageCount != nil {
        // A cold conversation whose latest message is unresolved may hold a
        // hand-off. Hydrate it, then examine it. A conversation that just
        // arrived from another host can fail to hydrate (its shard has not
        // synchronized yet, or a reload superseded the load); the next pass
        // tries again instead of ignoring the hand-off until the sender
        // reclaims it.
        if thread.storedHasUnresolvedLatestDelivery == true,
           aiChatHandoffHydrationRequests.insert(thread.id).inserted {
          Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.hydrateAIChatThreadIfNeeded(thread.id) == nil {
              self.aiChatHandoffHydrationRequests.remove(thread.id)
            } else {
              self.processAIChatHandoffs()
            }
          }
        }
        continue
      }
      guard !thread.isSharedRoom else { continue }
      let messages = aiChatMessages(for: thread.id)
      var accepted: [UUID] = []
      var reclaimed: [(UUID, String)] = []
      for message in messages
      where message.role == .user && message.deliveryStatus == .sending && message.deliveryKind != .steer {
        guard let provenance = message.provenance, provenance.acceptedAt == nil,
              let target = provenance.executionHostRef
        else { continue }
        if target == hostRef {
          // A draining host leaves hand-offs for their sender to reclaim.
          if !isAIChatDraining { accepted.append(message.id) }
        } else if provenance.receivedByHostRef == hostRef {
          let targetName = provenance.executionHostName ?? target
          let targetRecord = freshAIChatRemoteHost(ref: target, now: now)
          if targetRecord == nil {
            reclaimed.append((message.id, "\(targetName) is offline"))
          } else if targetRecord?.turns.contains(where: { $0.threadID == thread.id }) == true {
            // The target is still running this conversation's turn. A message
            // queued behind it waits there; running it here would split the
            // runtime session across hosts and strand it behind a turn this
            // host cannot drive.
            continue
          } else if targetRecord?.isDraining == true, !isAIChatDraining {
            reclaimed.append((message.id, "\(targetName) is restarting"))
          } else if now.timeIntervalSince(message.createdAt) > aiChatHandoffTimeout {
            reclaimed.append((message.id, "\(targetName) did not pick it up"))
          }
        }
      }
      guard !accepted.isEmpty || !reclaimed.isEmpty else { continue }
      let takeOver = Set(accepted).union(reclaimed.map(\.0))
      let updated = messages.map { message -> AIChatMessage in
        guard takeOver.contains(message.id) else { return message }
        var provenance = message.provenance ?? AIChatMessageProvenance()
        provenance.executionHostRef = hostRef
        provenance.executionHostName = aiChatHostIdentity.name
        provenance.acceptedAt = now
        return message.replacingProvenance(provenance)
      }
      replaceAIChatMessages(updated, for: thread.id, shouldPersist: true)
      aiChatForeignPendingMessageIDs.subtract(takeOver)
      var pending = aiChatPendingUserMessageIDs(for: thread.id)
      for message in updated where takeOver.contains(message.id) && !pending.contains(message.id) {
        pending.append(message.id)
      }
      aiChatPendingUserMessageIDsByThreadID[thread.id] = pending
      if let reason = reclaimed.first?.1, selectedAIChatThreadID == thread.id {
        aiChatStatusText = "\(reason); running here on \(aiChatHostIdentity.name)"
      }
      nudgeAIChatStoreSynchronization()
      guard !drainingAIChatThreadIDs.contains(thread.id) else { continue }
      let threadID = thread.id
      Task { @MainActor [weak self] in
        await self?.drainAIChatSendQueue(for: threadID)
      }
    }
  }

  public func retryAIChatTranscriptRecovery() {
    guard aiChatTranscriptWritesBlocked,
          aiChatTranscriptLoadTask == nil,
          !isLoadingAIChatTranscript
    else { return }
    startAIChatTranscriptReload()
  }

  func startAIChatTranscriptReload() {
    let targetURL = aiChatTranscriptURL.standardizedFileURL
    let preferredSelectedThreadID = restoredSelectedAIChatThreadID()
    isLoadingAIChatTranscript = true
    aiChatTranscriptLoadGeneration &+= 1
    syncedAIChatAppliedSources = [:]
    let generation = aiChatTranscriptLoadGeneration
    aiChatTranscriptLoadTask = Task { @MainActor [weak self] in
      let preparedLoad = await Task.detached(priority: .userInitiated) {
        let initial = Self.readAIChatTranscriptForWorkspace(from: targetURL)
        let loaded: AIChatWorkspaceTranscriptLoad
        if initial.requiresMigration {
          do {
            try AIChatTranscriptStore.shared.flush(
              AIChatTranscriptSnapshot(
                threads: initial.transcript.threads,
                selectedThreadID: initial.transcript.selectedThreadID,
                settlementSettings: initial.transcript.settlementSettings
              ),
              legacyURL: targetURL
            )
            loaded = Self.readAIChatTranscriptForWorkspace(from: targetURL)
          } catch {
            loaded = initial
          }
        } else {
          loaded = initial
        }
        return Self.prepareInitialAIChatTranscriptLoad(
          loaded,
          preferredSelectedThreadID: preferredSelectedThreadID
        )
      }.value
      guard let self,
            self.aiChatTranscriptLoadGeneration == generation,
            self.aiChatTranscriptURL.standardizedFileURL.path == targetURL.path
      else { return }
      let loaded = preparedLoad.loaded
      self.aiChatTranscriptLoadTask = nil
      self.isLoadingAIChatTranscript = false
      self.unloadedAIChatThreadIDs = loaded.unloadedThreadIDs
      self.aiChatTranscriptWritesBlocked = loaded.recoveryStatus.blocksWrites
      self.isApplyingPersistedAIChatThreads = true
      AIChatMessagePresentationCache.install(preparedLoad.presentations)
      self.applyAIChatTranscript(loaded.transcript, shouldPersist: loaded.requiresMigration)
      self.isApplyingPersistedAIChatThreads = false
      if !loaded.requiresMigration { self.initializeHydratedAIChatThreadLRU() }
      self.replayAIChatMutationsAfterTranscriptLoad()
      self.applyAIChatTranscriptRecoveryStatus(loaded.recoveryStatus)
      self.persistStaleLocalAIChatSendRepair(loaded.interruptedSendThreadIDs)
    }
  }

  func switchAIChatTranscript(to url: URL, migrationSource: URL? = nil) {
    guard !usesFixedAIChatTranscriptURL else { return }
    let targetURL = url.standardizedFileURL
    let previousURL = aiChatTranscriptURL.standardizedFileURL
    guard targetURL.path != previousURL.path else { return }
    invalidateWorkspaceSearchRequest()
    saveAIChatComposerForSelectedThread()
    let sourceURL = migrationSource?.standardizedFileURL
    cacheActiveAIChatTranscriptForLateCallbacks()
    if aiChatTranscriptLoadTask == nil {
      // The fallback URL is deliberately not loaded during initialization.
      // Only flush it when memory is known to represent that transcript;
      // otherwise it is the migration input and must remain read-only until
      // the detached load below has captured it.
      if hasAuthoritativeAIChatTranscriptState {
        flushDeferredAIChatTranscriptPersistence()
      }
    } else {
      aiChatTranscriptLoadTask?.cancel()
    }
    aiChatThreadHydrationTasks.values.forEach { $0.cancel() }
    aiChatThreadHydrationTasks.removeAll()
    aiChatThreadHydrationTaskTokens.removeAll()
    pendingAIChatHydrationCommitTasks.values.forEach { $0.cancel() }
    pendingAIChatHydrationCommitTasks.removeAll()
    pendingAIChatHydrationCommits.removeAll()
    unloadedAIChatThreadIDs = []
    hydratedAIChatThreadLRU = []
    aiChatThreadMessageMutationVersions.removeAll()
    aiChatThreadMessageRevisions.removeAll()
    lastEnqueuedAIChatTranscriptStoreGeneration = nil
    publishedAIChatMessagesIdentity = nil
    aiChatTranscriptLoadGeneration &+= 1
    syncedAIChatAppliedSources = [:]
    resetAIChatTranscriptMutationTracking()
    let loadGeneration = aiChatTranscriptLoadGeneration
    aiChatTranscriptLoadTask?.cancel()
    let fallbackMessages = previousURL.path == appAIChatTranscriptURL.standardizedFileURL.path
      ? aiChatMessages
      : []
    let inFlightThreadIDs = Set(aiChatSendOriginsByThreadID.compactMap { threadID, origin in
      origin.transcriptURL.standardizedFileURL.path == targetURL.path ? threadID : nil
    })
    let cachedTargetTranscript = inactiveAIChatTranscriptsByPath[targetURL.path]
    let hasInFlightTurn = !inFlightThreadIDs.isEmpty
    isLoadingAIChatTranscript = true
    aiChatTranscriptWritesBlocked = false
    aiChatTranscriptRecoveryNotice = nil
    pendingAIChatMessageMutationDuringLoad = nil
    pendingAIChatThreadsDuringLoad = []
    pendingAIChatSelectionDuringLoad = nil
    aiChatTranscriptURL = targetURL
    let preferredSelectedThreadID = restoredSelectedAIChatThreadID()
    openClawSessionKey = Self.makeOpenClawSessionKey(agentID: openClawAgentID)
    cancelAllAIChatPendingTurnRecovery()
    syncSelectedAIChatSendState()
    isApplyingPersistedAIChatThreads = true
    applyAIChatTranscript(
      AIChatTranscriptState(
        threads: [],
        selectedThreadID: nil,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      shouldPersist: false
    )
    hasAuthoritativeAIChatTranscriptState = false
    isApplyingPersistedAIChatThreads = false

    let hasTargetTranscript = FileManager.default.fileExists(atPath: targetURL.path)
      || AIChatTranscriptStore.hasCommittedStore(for: targetURL)
    if !hasTargetTranscript,
       sourceURL == nil,
       fallbackMessages.isEmpty,
       cachedTargetTranscript == nil {
      aiChatTranscriptLoadTask = nil
      isLoadingAIChatTranscript = false
      hasAuthoritativeAIChatTranscriptState = true
      return
    }

    aiChatTranscriptLoadTask = Task { @MainActor [weak self] in
      let loadDelay = self?.aiChatTranscriptLoadDelayNanosecondsForTesting ?? 0
      let preparedLoad = await Task.detached(priority: .userInitiated) {
        if loadDelay > 0 { try? await Task.sleep(nanoseconds: loadDelay) }
        let result: AIChatWorkspaceTranscriptLoad
        if hasTargetTranscript {
          result = Self.readAIChatTranscriptForWorkspace(
            from: targetURL,
            marksInterruptedSends: !hasInFlightTurn
          )
        } else if let sourceURL, sourceURL.path != targetURL.path {
          let source = Self.readAIChatTranscriptForWorkspace(from: sourceURL)
          let threads = AIChatTranscriptStore.shared.loadAllThreads(
            replacingMetadata: source.transcript.threads,
            legacyURL: sourceURL
          )
          result = AIChatWorkspaceTranscriptLoad(
            transcript: AIChatTranscriptState(
              threads: threads,
              selectedThreadID: source.transcript.selectedThreadID,
              settlementSettings: source.transcript.settlementSettings
            ),
            unloadedThreadIDs: [],
            requiresMigration: !threads.isEmpty,
            recoveryStatus: source.recoveryStatus
          )
        } else {
          let transcript = Self.aiChatTranscriptState(fromLegacyMessages: fallbackMessages)
          result = AIChatWorkspaceTranscriptLoad(
            transcript: transcript,
            unloadedThreadIDs: [],
            requiresMigration: !transcript.threads.isEmpty,
            recoveryStatus: .healthy
          )
        }
        let loaded: AIChatWorkspaceTranscriptLoad
        if result.requiresMigration {
          do {
            try AIChatTranscriptStore.shared.flush(
              AIChatTranscriptSnapshot(
                threads: result.transcript.threads,
                selectedThreadID: result.transcript.selectedThreadID,
                settlementSettings: result.transcript.settlementSettings
              ),
              legacyURL: targetURL
            )
            // Immediately release the fully decoded legacy graph. The second
            // read materializes only selected/pending/bounded active threads.
            loaded = Self.readAIChatTranscriptForWorkspace(
              from: targetURL,
              marksInterruptedSends: !hasInFlightTurn
            )
          } catch {
            loaded = result
          }
        } else {
          loaded = result
        }
        let restored = Self.restoringCachedAIChatThreads(
          in: loaded,
          cachedTranscript: cachedTargetTranscript,
          priorityThreadIDs: inFlightThreadIDs
        )
        let loadedByID = Dictionary(
          loaded.transcript.threads.map { ($0.id, $0) },
          uniquingKeysWith: { first, _ in first }
        )
        let restoredFromMemory = restored.transcript.threads.filter { loadedByID[$0.id] != $0 }
        AIChatTranscriptStore.shared.forgetAdoptedThreads(
          Set(restoredFromMemory.map(\.id)),
          legacyURL: targetURL
        )
        return Self.prepareInitialAIChatTranscriptLoad(
          restored,
          preferredSelectedThreadID: preferredSelectedThreadID
        )
      }.value
      guard let self,
            !Task.isCancelled,
            self.aiChatTranscriptLoadGeneration == loadGeneration,
            self.aiChatTranscriptURL.standardizedFileURL.path == targetURL.path
      else { return }
      let loaded = preparedLoad.loaded
      self.aiChatTranscriptLoadTask = nil
      self.unloadedAIChatThreadIDs = loaded.unloadedThreadIDs
      self.aiChatTranscriptWritesBlocked = loaded.recoveryStatus.blocksWrites
      self.isLoadingAIChatTranscript = false
      self.isApplyingPersistedAIChatThreads = true
      AIChatMessagePresentationCache.install(preparedLoad.presentations)
      self.applyAIChatTranscript(
        loaded.transcript,
        shouldPersist: loaded.requiresMigration
      )
      self.isApplyingPersistedAIChatThreads = false
      if !loaded.requiresMigration { self.initializeHydratedAIChatThreadLRU() }
      self.replayAIChatMutationsAfterTranscriptLoad()
      self.applyAIChatTranscriptRecoveryStatus(loaded.recoveryStatus)
      self.persistStaleLocalAIChatSendRepair(loaded.interruptedSendThreadIDs)
      self.startPendingAIChatTurnRecovery()
      self.processAIChatHandoffs()
      self.scheduleAIChatLiveRefresh()
    }
  }

  nonisolated private static func restoringCachedAIChatThreads(
    in loaded: AIChatWorkspaceTranscriptLoad,
    cachedTranscript: AIChatTranscriptState?,
    priorityThreadIDs: Set<UUID>
  ) -> AIChatWorkspaceTranscriptLoad {
    guard let cachedTranscript, !cachedTranscript.threads.isEmpty else { return loaded }

    var threads = loaded.transcript.threads
    var restoredThreadIDs = Set<UUID>()
    for cachedThread in cachedTranscript.threads {
      if let index = threads.firstIndex(where: { $0.id == cachedThread.id }) {
        guard priorityThreadIDs.contains(cachedThread.id)
          || cachedThread.updatedAt > threads[index].updatedAt
        else { continue }
        threads[index] = cachedThread
      } else {
        threads.append(cachedThread)
      }
      restoredThreadIDs.insert(cachedThread.id)
    }
    guard !restoredThreadIDs.isEmpty else { return loaded }
    let threadIDSet = Set(threads.map(\.id))
    let selectedThreadID = cachedTranscript.selectedThreadID.flatMap { id in
      threadIDSet.contains(id) ? id : nil
    } ?? loaded.transcript.selectedThreadID
    return AIChatWorkspaceTranscriptLoad(
      transcript: AIChatTranscriptState(
        threads: sortedAIChatThreadsForDisplay(threads),
        selectedThreadID: selectedThreadID,
        settlementSettings: cachedTranscript.settlementSettings
      ),
      unloadedThreadIDs: loaded.unloadedThreadIDs.subtracting(restoredThreadIDs),
      requiresMigration: loaded.requiresMigration,
      recoveryStatus: loaded.recoveryStatus,
      interruptedSendThreadIDs: loaded.interruptedSendThreadIDs.subtracting(restoredThreadIDs)
    )
  }

  func loadAIChatTranscriptForWorkspace(
    from url: URL,
    marksInterruptedSends: Bool = true
  ) -> (
    transcript: AIChatTranscriptState,
    requiresMigration: Bool,
    recoveryStatus: AIChatTranscriptRecoveryStatus,
    interruptedSendThreadIDs: Set<UUID>
  ) {
    let loaded = Self.readAIChatTranscriptForWorkspace(
      from: url,
      marksInterruptedSends: marksInterruptedSends
    )
    unloadedAIChatThreadIDs = loaded.unloadedThreadIDs
    return (
      loaded.transcript,
      loaded.requiresMigration,
      loaded.recoveryStatus,
      loaded.interruptedSendThreadIDs
    )
  }

  func applyAIChatTranscriptRecoveryStatus(
    _ recoveryStatus: AIChatTranscriptRecoveryStatus
  ) {
    switch recoveryStatus {
    case .healthy, .recoveredPreviousManifest:
      let priorNotice = aiChatTranscriptRecoveryNotice
      aiChatTranscriptRecoveryNotice = nil
      if errorText == priorNotice { errorText = nil }
    case .unrecoverable(let message):
      aiChatTranscriptRecoveryNotice = message
      errorText = message
    }
  }

  nonisolated private static func readAIChatTranscriptForWorkspace(
    from url: URL,
    marksInterruptedSends: Bool = true
  ) -> AIChatWorkspaceTranscriptLoad {
    if let loaded = AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: url) {
      // The persisted revision (before any launch-time repair below) is the
      // common ancestor for merging this copy with synchronized replicas.
      AIChatTranscriptStore.shared.recordAdoptedThreads(loaded.snapshot.threads, legacyURL: url)
      if case .unrecoverable(let derivedFailure) = loaded.recoveryStatus,
         let visibleFallback = visibleCanonicalAIChatTranscriptForUnrecoverableStore(
           from: url,
           derivedFailure: derivedFailure,
           marksInterruptedSends: marksInterruptedSends
         ) {
        return visibleFallback
      }
      var transcript = AIChatTranscriptState(
        threads: loaded.snapshot.threads,
        selectedThreadID: loaded.snapshot.selectedThreadID,
        settlementSettings: loaded.snapshot.settlementSettings
      )
      var interruptedSendThreadIDs = Set<UUID>()
      if marksInterruptedSends {
        let persisted = Dictionary(
          transcript.threads.map { ($0.id, $0.messages) },
          uniquingKeysWith: { first, _ in first }
        )
        transcript = Self.aiChatTranscriptStateByMarkingInterruptedSends(transcript)
        interruptedSendThreadIDs = Set(transcript.threads.compactMap { thread in
          persisted[thread.id] == thread.messages ? nil : thread.id
        })
      }
      return AIChatWorkspaceTranscriptLoad(
        transcript: transcript,
        unloadedThreadIDs: loaded.unloadedThreadIDs,
        requiresMigration: loaded.recoveryStatus == .recoveredPreviousManifest,
        recoveryStatus: loaded.recoveryStatus,
        interruptedSendThreadIDs: interruptedSendThreadIDs
      )
    }
    let transcript = Self.loadAIChatTranscript(
      from: url,
      marksInterruptedSends: marksInterruptedSends
    )
    return AIChatWorkspaceTranscriptLoad(
      transcript: transcript,
      unloadedThreadIDs: [],
      requiresMigration: FileManager.default.fileExists(atPath: url.path)
        && !transcript.threads.isEmpty,
      recoveryStatus: .healthy
    )
  }
}
