import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  /// This projection must stay lexical. Resolving symlinks performs filesystem
  /// metadata calls, which used to run once per node from the main actor.
  nonisolated static func corpusRelativePathWithoutFilesystemAccess(
    for path: String,
    root: URL?
  ) -> String {
    guard let root else { return path }
    let rootPath = root.standardizedFileURL.path
    if path == rootPath { return "." }
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
  }

  func scheduleSearchNodeDisplayRefresh(
    limit: Int = 100,
    debounce: Bool = true
  ) {
    searchNodeSearchGeneration &+= 1
    let generation = searchNodeSearchGeneration
    let rows = searchNodeIndexRows
    let query = searchQuery
    searchNodeSearchTask?.cancel()

    guard !rows.isEmpty else {
      searchNodeSearchTask = nil
      searchNodes = []
      return
    }

    searchNodeSearchTask = Task { [rows, query, generation, limit] in
      if debounce {
        try? await Task.sleep(nanoseconds: 70_000_000)
      } else {
        await Task.yield()
      }
      guard !Task.isCancelled else { return }
      let matches = await Task.detached(priority: .userInitiated) {
        Self.filteredSearchNodes(rows, query: query, limit: limit)
      }.value
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self,
              self.searchNodeSearchGeneration == generation,
              self.searchQuery == query,
              self.searchMode == .nodes
        else { return }
        self.searchNodes = matches
        self.searchNodeSearchTask = nil
      }
    }
  }

  nonisolated private static func filteredSearchNodes(
    _ rows: [SearchNodeIndexRow],
    query rawQuery: String,
    limit: Int
  ) -> [OrgRoamNodeReference] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return Array(rows.map(\.node).sorted(by: compareSearchNodes).prefix(limit))
    }
    let normalizedQuery = Self.normalizedQuickOpenQuery(query)
    let normalizedLabelQuery = Self.normalizedQuickOpenCandidate(query)
    return rows
      .compactMap { row -> (OrgRoamNodeReference, Int)? in
        let bestScore = row.normalizedCandidates.compactMap {
          Self.fuzzyScore(normalizedQuery: normalizedQuery, normalizedCandidate: $0)
        }.max()
        guard let bestScore else { return nil }
        let exactBoost = row.normalizedLabels.contains { $0.contains(normalizedLabelQuery) } ? 50 : 0
        return (row.node, bestScore + exactBoost)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return compareSearchNodes(lhs.0, rhs.0)
      }
      .prefix(limit)
      .map(\.0)
  }

  nonisolated private static func compareSearchNodes(
    _ lhs: OrgRoamNodeReference,
    _ rhs: OrgRoamNodeReference
  ) -> Bool {
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    let pathOrder = lhs.file.localizedStandardCompare(rhs.file)
    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
    return lhs.line < rhs.line
  }

  func selectedLocationMatches(_ location: WorkspaceLocation) -> Bool {
    guard let selectedLocation else { return true }
    return Self.selectionIdentity(for: selectedLocation) == Self.selectionIdentity(for: location)
  }

  nonisolated static func selectionIdentity(for location: WorkspaceLocation) -> String {
    let kind: String
    switch location {
    case .agenda:
      kind = "agenda"
    case .assigned:
      kind = "assigned"
    case .search:
      kind = "search"
    case .backlink:
      kind = "backlink"
    case .aiChatThreadRecord:
      kind = "openClaw"
    case .meeting:
      kind = "meeting"
    }
    return [
      kind,
      location.file,
      "\(location.lineForEditor)",
      location.title
    ].joined(separator: "\u{1F}")
  }

  func scheduleAgendaRefresh(preserveSelection: Bool = true, updatesStatus: Bool = false) {
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      await refreshAgenda(preserveSelection: preserveSelection, updatesStatus: updatesStatus)
    }
  }

  func applyDeferredStableAutosaveForActiveBlock() -> Bool {
    guard let editingBlockID,
          let deferred = deferredStableAutosaves.removeValue(forKey: editingBlockID)
    else {
      return false
    }

    if selectedEntrySource?.id == deferred.source.id {
      selectedEntrySource = deferred.source
    }

    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: deferred.block,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = deferred.block.id
    return true
  }

  func restoreActiveBlockOriginal() {
    guard let editingBlockID,
          let original = activeBlockOriginals[editingBlockID]
    else {
      return
    }
    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: original,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = original.id
  }

  func resetBlockEditing() {
    let wasEditingBlock = editingBlockID != nil
    editingBlockID = nil
    editableBlockText = ""
    activeBlockDrafts.removeAll()
    activeBlockOriginals.removeAll()
    activeBlockInitialSelections.removeAll()
    deferredStableAutosaves.removeAll()
    if wasEditingBlock, pendingAgendaRefreshAfterBlockEditing {
      pendingAgendaRefreshAfterBlockEditing = false
      scheduleAgendaRefresh(preserveSelection: true)
    }
  }

  func resetBlockState() {
    selectedBlockID = nil
    pendingBlockSelection = nil
    transientDraftBlock = nil
    resetBlockEditing()
  }

  var activeEditingBlock: OrgEditableBlock? {
    guard let editingBlockID else { return nil }
    return selectedRenderedBlocks.first { $0.id == editingBlockID }
  }

  nonisolated static func directTypingInsertionText(from event: NSEvent) -> String? {
    guard let characters = event.characters,
          !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
    else {
      return nil
    }
    return characters
  }

  nonisolated static func editingDraft(
    _ block: OrgEditableBlock,
    appending text: String
  ) -> String? {
    guard !text.isEmpty else { return nil }
    switch block.rendered {
    case .heading:
      return headingEditingDraft(block.rawText, appending: text)
    case .paragraph, .listItem:
      return block.rawText + text
    default:
      return nil
    }
  }

  nonisolated private static func headingEditingDraft(
    _ rawText: String,
    appending text: String
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first,
          let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#)
    else {
      return nil
    }

    let nsFirst = first as NSString
    let fullRange = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: fullRange),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    var rest = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    var tagsSuffix = ""
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(rest[tagRange])
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var prefixTokens: [String] = []
    if let firstToken = tokens.first,
       allHeadingTodoKeywords.contains(firstToken.uppercased()) {
      prefixTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }
    if let firstToken = tokens.first,
       firstToken.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      prefixTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }

    let title = tokens.joined(separator: " ")
    let updatedTitle = title.isEmpty ? text : title + text
    lines[0] = "\(prefix)\((prefixTokens + [updatedTitle]).joined(separator: " "))\(tagsSuffix)"
    return lines.joined(separator: "\n")
  }

  func discardTransientDraft(status: String? = nil) {
    guard let draft = transientDraftBlock else {
      resetBlockEditing()
      return
    }
    selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
    let existingIDs = Set(selectedRenderedBlocks.map(\.id))
    selectedRenderedBlocks.append(contentsOf: draft.coveredBlocks.filter { !existingIDs.contains($0.id) })
    selectedRenderedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    if selectedBlockID == draft.block.id {
      selectedBlockID = nil
    }
    transientDraftBlock = nil
    resetBlockEditing()
    if let status {
      statusText = status
    }
  }

  func activateTransientDraft(_ draft: TransientDraftBlock) {
    let coveredIDs = Set(draft.coveredBlocks.map(\.id))
    selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
    selectedRenderedBlocks.removeAll { coveredIDs.contains($0.id) }
    selectedRenderedBlocks.append(draft.block)
    selectedRenderedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    selectedBlockID = draft.block.id
    editingBlockID = draft.block.id
    editableBlockText = draft.block.rawText
    activeBlockDrafts[draft.block.id] = draft.block.rawText
    revealRenderedBlockIfHiddenByFold(draft.block.id)
    requestDetailReveal(toBlock: draft.block.id)
  }

  private func revealRenderedBlockIfHiddenByFold(_ blockID: OrgEditableBlock.ID) {
    var nextFoldedIDs = foldedRenderedBlockIDs
    while let ancestorID = OrgRenderedFoldTree.foldedAncestorID(
      hiding: blockID,
      foldedBlockIDs: nextFoldedIDs,
      blocks: selectedRenderedBlocks
    ) {
      nextFoldedIDs.remove(ancestorID)
    }
    if nextFoldedIDs != foldedRenderedBlockIDs {
      foldedRenderedBlockIDs = nextFoldedIDs
    }
  }

  func saveTransientDraftBlock(_ draft: TransientDraftBlock) async {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    guard let replacementBody = Self.normalizedTransientDraftText(editingDraftText(for: draft.block), for: draft.block) else {
      discardTransientDraft(status: "Draft discarded")
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    let replacement = "\(draft.replacementPrefix)\(replacementBody)\(draft.replacementSuffix)"
    do {
      let undoSnapshot = await fileUndoSnapshot(for: draft.file)
      try await replaceDocumentSourceRange(
        file: draft.file,
        startLine: draft.insertionLine,
        endLineExclusive: draft.replacementEndLineExclusive,
        replacement: replacement
      )
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: draft.file)
      await recordFileUndo(from: undoSnapshot)
      transientDraftBlock = nil
      selectedRenderedBlocks.removeAll { $0.id == draft.block.id }
      if selectedBlockID == draft.block.id {
        selectedBlockID = nil
      }
      invalidateCanonicalDocumentCache(for: draft.file)
      resetBlockEditing()
      isEditingEntry = false
      pendingBlockSelection = PendingBlockSelection(
        file: draft.file,
        line: draft.insertionLine + draft.selectionLineOffset,
        mode: .containingOrNearest
      )
      statusText = encryptedCount > 0
        ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        : "Saved block \(relativePath(draft.file)):\(draft.insertionLine)"
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Block save failed"
    }
  }

  func replaceBlockSourceAndFinish(
    source: EntrySource,
    block: OrgEditableBlock,
    replacement: String,
    status: String,
    selectLine: Int? = nil,
    selectionMode: PendingBlockSelectionMode = .containingOrNearest
  ) async throws {
    let normalizedReplacement = Self.normalizeLineEndings(replacement)
    let updatedSource = try await Task.detached(priority: .userInitiated) {
      try Self.replacingSourceBlock(
        block,
        in: source,
        with: normalizedReplacement
      )
    }.value
    let currentRenderedBlocks = selectedRenderedBlocks
    let undoSnapshot = await fileUndoSnapshot(for: source.file)
    try await replaceDocumentSourceRange(
      file: source.file,
      startLine: block.startLine,
      endLineExclusive: block.endLineExclusive,
      replacement: normalizedReplacement,
      expectedOriginal: block.rawText
    )
    let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

    if encryptedCount > 0 {
      await recordFileUndo(from: undoSnapshot)
      guard selectedEntrySource?.id == source.id else { return }
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      statusText = "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      return
    }

    let updatedBlocks = await Task.detached(priority: .userInitiated) {
      Self.locallyUpdatingRenderedBlocks(
        currentRenderedBlocks,
        replacing: block,
        with: normalizedReplacement
      )
    }.value

    guard selectedEntrySource?.id == source.id else {
      await recordFileUndo(from: undoSnapshot)
      return
    }

    await recordFileUndo(from: undoSnapshot)
    invalidateCanonicalDocumentCache(for: source.file)
    transientDraftBlock = nil
    resetBlockEditing()
    isEditingEntry = false
    selectedEntrySource = updatedSource
    let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
    selectedRenderedBlocks = updatedVisibleBlocks
    if let selectLine {
      selectedBlockID = blockForSelectionLine(
        max(1, selectLine),
        mode: selectionMode,
        in: updatedVisibleBlocks
      )?.id
    }
    statusText = status
    scheduleAgendaRefresh(preserveSelection: true)
  }

  var selectableBlocks: [OrgEditableBlock] {
    guard let source = selectedEntrySource else { return [] }
    return OrgRenderedFoldTree.visibleBlocks(
      selectedRenderedBlocks,
      foldedBlockIDs: foldedRenderedBlockIDs
    ).filter { block in
      block.isEditable
        && block.startLine >= source.startLine
        && block.endLineExclusive <= source.endLineExclusive
    }
  }

  func previousMergeTarget(before block: OrgEditableBlock) -> OrgEditableBlock? {
    let sortedBlocks = Self.sortEditableBlocksForDisplay(selectedRenderedBlocks)
    guard let currentIndex = sortedBlocks.firstIndex(where: { $0.id == block.id }) else {
      return sortedBlocks.last { candidate in
        candidate.endLineExclusive <= block.startLine
          && Self.isMergeablePreviousTextBlock(candidate)
      }
    }

    guard currentIndex > 0 else { return nil }
    for candidate in sortedBlocks[..<currentIndex].reversed()
      where Self.isMergeablePreviousTextBlock(candidate) {
      return candidate
    }
    return nil
  }

  func blockForSelectionLine(
    _ line: Int,
    mode: PendingBlockSelectionMode,
    in blocks: [OrgEditableBlock]
  ) -> OrgEditableBlock? {
    let editableBlocks = blocks.filter(\.isEditable)
    switch mode {
    case .containingOrNearest:
      if let containing = editableBlocks.first(where: { $0.startLine <= line && line < $0.endLineExclusive }) {
        return containing
      }
      if let next = editableBlocks.first(where: { $0.startLine >= line }) {
        return next
      }
    case .nextOrNearest:
      if let next = editableBlocks.first(where: { $0.startLine >= line }) {
        return next
      }
      if let containing = editableBlocks.first(where: { $0.startLine <= line && line < $0.endLineExclusive }) {
        return containing
      }
    }
    return editableBlocks.last
  }

  var movableBlocks: [OrgEditableBlock] {
    guard let source = selectedEntrySource else { return [] }
    return selectedRenderedBlocks.filter { block in
      guard block.isEditable,
            block.startLine >= source.startLine,
            block.endLineExclusive <= source.endLineExclusive
      else {
        return false
      }
      return !(source.isSubtree && block.startLine == source.startLine)
    }
  }

  func moveTarget(for block: OrgEditableBlock, direction: OrgBlockMoveDirection) -> OrgEditableBlock? {
    let blocks = movableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return nil }
    switch direction {
    case .up:
      guard index > 0 else { return nil }
      return blocks[index - 1]
    case .down:
      guard index < blocks.count - 1 else { return nil }
      return blocks[index + 1]
    }
  }

  func transientDraftEditableBlock(
    startLine: Int,
    endLineExclusive: Int,
    rawText: String,
    rendered: OrgRenderedBlock
  ) -> OrgEditableBlock {
    transientDraftIDCounter += 1
    return OrgEditableBlock(
      id: "transient-draft:\(transientDraftIDCounter):\(startLine):\(endLineExclusive)",
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      rawText: rawText,
      rendered: rendered
    )
  }

  func insertionDraftBlock(
    for kind: OrgInsertBlockKind,
    after previousBlock: OrgEditableBlock,
    in source: EntrySource,
    initialText: String? = nil
  ) -> TransientDraftBlock {
    let rawText = initialText ?? insertionDraftRawText(for: kind, after: previousBlock, in: source)
    let insertionLine = previousBlock.endLineExclusive
    return TransientDraftBlock(
      file: source.file,
      insertionLine: insertionLine,
      replacementEndLineExclusive: insertionLine,
      replacementPrefix: "\n",
      replacementSuffix: "",
      selectionLineOffset: 1,
      block: transientDraftEditableBlock(
        startLine: insertionLine,
        endLineExclusive: insertionLine,
        rawText: rawText,
        rendered: insertionDraftRenderedBlock(for: kind, rawText: rawText, after: previousBlock, in: source)
      ),
      coveredBlocks: []
    )
  }

  func appendDraftBlock(
    kind: OrgInsertBlockKind,
    in source: EntrySource
  ) -> TransientDraftBlock {
    let rawText = appendDraftRawText(for: kind)
    let isSourceEmpty = source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let insertionLine = isSourceEmpty ? source.startLine : max(source.startLine, source.endLineExclusive)
    let replacementEndLineExclusive = isSourceEmpty
      ? max(source.startLine, source.endLineExclusive)
      : insertionLine
    let replacementPrefix = isSourceEmpty ? "" : "\n"
    let selectionLineOffset = replacementPrefix.isEmpty ? 0 : 1
    return TransientDraftBlock(
      file: source.file,
      insertionLine: insertionLine,
      replacementEndLineExclusive: replacementEndLineExclusive,
      replacementPrefix: replacementPrefix,
      replacementSuffix: "",
      selectionLineOffset: selectionLineOffset,
      block: transientDraftEditableBlock(
        startLine: insertionLine,
        endLineExclusive: insertionLine,
        rawText: rawText,
        rendered: appendDraftRenderedBlock(for: kind, rawText: rawText)
      ),
      coveredBlocks: []
    )
  }

  private func appendDraftRawText(for kind: OrgInsertBlockKind) -> String {
    switch kind {
    case .paragraph:
      return ""
    case .heading:
      return "* "
    case .todo:
      return "* TODO "
    case .table:
      return """
      | Name | Value |
      |------+-------|
      |      |       |
      """
    case .divider:
      return "-----"
    case .image:
      return mediaDraftRawText(kind: .image, content: "")
    case .video:
      return mediaDraftRawText(kind: .video, content: "")
    case .properties:
      return """
      :PROPERTIES:
      :KEY:
      :END:
      """
    case .quote:
      return """
      #+begin_quote

      #+end_quote
      """
    case .source:
      return """
      #+begin_src sh

      #+end_src
      """
    }
  }

  private func appendDraftRenderedBlock(for kind: OrgInsertBlockKind, rawText: String) -> OrgRenderedBlock {
    switch kind {
    case .paragraph:
      return .paragraph("")
    case .heading:
      return .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "", tags: []))
    case .todo:
      return .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: nil, title: "", tags: []))
    case .table:
      return .table(OrgEditableTable(rawText: rawText).renderedBlock)
    case .divider:
      return .horizontalRule
    case .image, .video:
      return .paragraph(rawText)
    case .properties:
      return .properties(OrgEditablePropertyDrawer(rawText: rawText).renderedRows)
    case .quote:
      return .quote([])
    case .source:
      let source = OrgEditableSourceBlock(rawText: rawText)
      return .source(language: source.renderedLanguage, lines: source.renderedLines)
    }
  }

  private func insertionDraftRawText(
    for kind: OrgInsertBlockKind,
    after block: OrgEditableBlock,
    in source: EntrySource
  ) -> String {
    let headingLevel = insertionHeadingLevel(after: block, in: source)
    let stars = String(repeating: "*", count: max(1, headingLevel))
    switch kind {
    case .paragraph:
      return ""
    case .heading:
      return "\(stars) "
    case .todo:
      return "\(stars) TODO "
    case .table:
      return """
      | Name | Value |
      |------+-------|
      |      |       |
      """
    case .divider:
      return "-----"
    case .image:
      return mediaDraftRawText(kind: .image, content: "")
    case .video:
      return mediaDraftRawText(kind: .video, content: "")
    case .properties:
      return """
      :PROPERTIES:
      :KEY:
      :END:
      """
    case .quote:
      return """
      #+begin_quote

      #+end_quote
      """
    case .source:
      return """
      #+begin_src sh

      #+end_src
      """
    }
  }

  private func insertionDraftRenderedBlock(
    for kind: OrgInsertBlockKind,
    rawText: String,
    after block: OrgEditableBlock,
    in source: EntrySource
  ) -> OrgRenderedBlock {
    let headingLevel = insertionHeadingLevel(after: block, in: source)
    switch kind {
    case .paragraph:
      return .paragraph("")
    case .heading:
      return .heading(OrgHeadingBlock(level: headingLevel, todo: nil, priority: nil, title: "", tags: []))
    case .todo:
      return .heading(OrgHeadingBlock(level: headingLevel, todo: "TODO", priority: nil, title: "", tags: []))
    case .table:
      return .table(OrgEditableTable(rawText: rawText).renderedBlock)
    case .divider:
      return .horizontalRule
    case .image, .video:
      return .paragraph(rawText)
    case .properties:
      return .properties(OrgEditablePropertyDrawer(rawText: rawText).renderedRows)
    case .quote:
      return .quote([])
    case .source:
      let source = OrgEditableSourceBlock(rawText: rawText)
      return .source(language: source.renderedLanguage, lines: source.renderedLines)
    }
  }

  func conversionDraftBlock(
    for kind: OrgInsertBlockKind,
    replacing block: OrgEditableBlock,
    in source: EntrySource,
    draft: String
  ) -> TransientDraftBlock {
    let rawText = conversionDraftRawText(for: kind, replacing: block, in: source, draft: draft)
    return TransientDraftBlock(
      file: source.file,
      insertionLine: block.startLine,
      replacementEndLineExclusive: block.endLineExclusive,
      replacementPrefix: "",
      replacementSuffix: "",
      selectionLineOffset: 0,
      block: transientDraftEditableBlock(
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive,
        rawText: rawText,
        rendered: draftRenderedBlock(for: kind, rawText: rawText, fallbackLine: block.startLine, fallbackBlock: block, in: source)
      ),
      coveredBlocks: [block]
    )
  }

  private func conversionDraftRawText(
    for kind: OrgInsertBlockKind,
    replacing block: OrgEditableBlock,
    in source: EntrySource,
    draft: String
  ) -> String {
    let content = slashCommandContent(from: draft)
    guard !content.isEmpty else {
      return insertionDraftRawText(for: kind, after: block, in: source)
    }

    let headingLevel = insertionHeadingLevel(after: block, in: source)
    let stars = String(repeating: "*", count: max(1, headingLevel))
    switch kind {
    case .paragraph:
      return content
    case .heading:
      return "\(stars) \(singleLineTitle(content, fallback: ""))"
    case .todo:
      return "\(stars) TODO \(singleLineTitle(content, fallback: ""))"
    case .table:
      if content.contains("|") {
        return content
      }
      return insertionDraftRawText(for: .table, after: block, in: source)
    case .divider:
      return "-----"
    case .image:
      return mediaDraftRawText(kind: .image, content: content)
    case .video:
      return mediaDraftRawText(kind: .video, content: content)
    case .properties:
      return insertionDraftRawText(for: .properties, after: block, in: source)
    case .quote:
      return """
      #+begin_quote
      \(content)
      #+end_quote
      """
    case .source:
      return """
      #+begin_src sh
      \(content)
      #+end_src
      """
    }
  }

  private func mediaDraftRawText(kind: OrgMediaAttachment.Kind, content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[["),
       OrgMediaAttachment.standalone(raw: trimmed) != nil {
      return trimmed
    }

    let placeholderTarget: String
    let placeholderLabel: String
    switch kind {
    case .image:
      placeholderTarget = "images/image.png"
      placeholderLabel = "Image"
    case .video:
      placeholderTarget = "videos/video.mp4"
      placeholderLabel = "Video"
    }

    guard !trimmed.isEmpty else {
      return OrgEditableMediaLink(kind: kind, target: placeholderTarget, label: placeholderLabel).formattedRawText
    }

    if let attachment = OrgMediaAttachment.standalone(raw: trimmed) {
      return OrgEditableMediaLink(kind: kind, target: attachment.target, label: attachment.displayName).formattedRawText
    }

    if trimmed.range(of: #"\.(?:png|jpe?g|gif|tiff?|bmp|heic|heif|webp|mov|mp4|m4v|avi|webm)(?:[#?].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return OrgEditableMediaLink(kind: kind, target: trimmed).formattedRawText
    }

    return OrgEditableMediaLink(kind: kind, target: placeholderTarget, label: trimmed).formattedRawText
  }

  private func draftRenderedBlock(
    for kind: OrgInsertBlockKind,
    rawText: String,
    fallbackLine: Int,
    fallbackBlock: OrgEditableBlock,
    in source: EntrySource
  ) -> OrgRenderedBlock {
    if kind == .paragraph,
       rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .paragraph("")
    }
    if let rendered = OrgEntryRenderer.parseEditable(rawText, baseLine: fallbackLine).first?.rendered {
      return rendered
    }
    return insertionDraftRenderedBlock(for: kind, rawText: rawText, after: fallbackBlock, in: source)
  }

  private func slashCommandContent(from draft: String) -> String {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return trimmed }

    let remainder = trimmed.dropFirst()
    guard let contentStart = remainder.firstIndex(where: { $0.isWhitespace }) else {
      return ""
    }

    return String(remainder[contentStart...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func singleLineTitle(_ text: String, fallback: String) -> String {
    let title = text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? fallback : title
  }

  private func insertionHeadingLevel(after block: OrgEditableBlock, in source: EntrySource) -> Int {
    if source.isSubtree,
       let rootLevel = Self.firstHeadingLevel(in: source.text) {
      return min(6, rootLevel + 1)
    }

    if case .heading(let heading) = block.rendered {
      return heading.level
    }

    if let previousHeading = selectedRenderedBlocks
      .filter({ $0.startLine <= block.startLine })
      .last(where: { candidate in
        if case .heading = candidate.rendered { return true }
        return false
      }),
      case .heading(let heading) = previousHeading.rendered {
      return heading.level
    }

    return 1
  }

  nonisolated private static func firstHeadingLevel(in text: String) -> Int? {
    for line in normalizeLineEndings(text).split(separator: "\n", omittingEmptySubsequences: false) {
      if let level = headingLevel(String(line)) {
        return level
      }
    }
    return nil
  }

  func sourceBlockRunKey(for block: OrgEditableBlock) -> String {
    let file = selectedEntrySource?.file ?? selectedLocation?.file ?? ""
    return "\(file):\(block.id)"
  }

  @discardableResult
  func supersedeDailyNoteNavigation() -> UInt64 {
    dailyNoteNavigationGeneration &+= 1
    dailyNoteActivationTask?.cancel()
    dailyNoteActivationTask = nil
    homeActivationTask?.cancel()
    homeActivationTask = nil
    return dailyNoteNavigationGeneration
  }

  func cancelPendingDailyNoteNavigation() {
    guard dailyNoteActivationTask != nil || homeActivationTask != nil else { return }
    _ = supersedeDailyNoteNavigation()
  }

  public func openDailyNote(_ target: DailyNoteTarget) {
    startDailyNoteNavigation(date: Self.date(for: target))
  }

  public func openDailyNoteFromSidebar(_ target: DailyNoteTarget) {
    openDailyNote(target)
  }

  public func presentDailyNoteDatePicker() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    dailyNotePickerDate = Date()
    isDailyNoteDatePickerPresented = true
  }

  public func openDailyNoteFromDatePicker() {
    let date = dailyNotePickerDate
    isDailyNoteDatePickerPresented = false
    startDailyNoteNavigation(date: date)
  }

  private func startDailyNoteNavigation(date: Date) {
    guard let corpusRoot,
          let context = captureDocumentCorpusContext()
    else {
      statusText = "No corpus selected"
      return
    }

    let generation = supersedeDailyNoteNavigation()
    dailyNoteActivationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.openDailyNote(
        date: date,
        corpusRoot: corpusRoot,
        context: context,
        generation: generation
      )
    }
  }

  func openDailyNote(
    date: Date,
    corpusRoot: URL,
    context: WorkspaceDocumentCorpusContext,
    generation: UInt64
  ) async {
    let url = await dailyNotePath(corpusRoot: corpusRoot, date: date)
    await openDailyNote(
      at: url,
      corpusRoot: corpusRoot,
      context: context,
      generation: generation,
      allowsCreation: !automaticDailyNoteCreationDisabled
    )
  }

  func openDailyNote(
    at url: URL,
    corpusRoot: URL,
    context: WorkspaceDocumentCorpusContext,
    generation: UInt64,
    allowsCreation: Bool
  ) async {
    guard !Task.isCancelled,
          dailyNoteNavigationGeneration == generation,
          isCurrentDocumentCorpusContext(context)
    else { return }
    do {
      if allowsCreation {
        try await ensureDailyNoteExists(at: url, context: context)
      } else if !(await dailyNoteExists(at: url)) {
        dailyNoteActivationTask = nil
        presentMissingDailyNote(
          at: url,
          corpusRoot: corpusRoot,
          opensHome: false,
          surface: selectedSurface,
          recordsHistory: true
        )
        return
      }
      let file = await Task.detached(priority: .userInitiated) {
        Self.corpusFileOffMain(for: url, corpusRoot: corpusRoot)
      }.value
      guard !Task.isCancelled,
            dailyNoteNavigationGeneration == generation,
            isCurrentDocumentCorpusContext(context)
      else { return }
      dailyNoteActivationTask = nil
      upsertCorpusFile(file)
      // Daily navigation replaces only the document, regardless of whether it
      // came from the sidebar, a keyboard shortcut, or the date picker.
      selectCorpusFile(file, surface: selectedSurface)
      if selectedSurface == .files {
        isWorkspaceSurfacePaneClosed = true
      }
      activeWorkspacePane = .detail
      statusText = "Opened \(file.relativePath)"
    } catch {
      guard !Task.isCancelled,
            dailyNoteNavigationGeneration == generation,
            isCurrentDocumentCorpusContext(context)
      else { return }
      dailyNoteActivationTask = nil
      errorText = error.localizedDescription
      statusText = "Could not open \(url.lastPathComponent)"
    }
  }

  public func openHome() {
    guard let corpusRoot else {
      if selectedSurface != .home
        || expandedWorkspaceSurface != nil
        || isWorkspaceSurfacePaneClosed
        || isWorkspaceDetailPaneClosed
        || isWorkspaceDetailPaneExpanded {
        recordCurrentNavigationDestination()
      }
      expandedWorkspaceSurface = nil
      isWorkspaceSurfacePaneClosed = false
      isWorkspaceDetailPaneClosed = false
      isWorkspaceDetailPaneExpanded = false
      navigateToSurface(.home, recordsHistory: false)
      statusText = "No corpus selected"
      return
    }

    guard let context = captureDocumentCorpusContext() else { return }
    let generation = supersedeDailyNoteNavigation()
    homeActivationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let url = await self.dailyNotePath(corpusRoot: corpusRoot, date: Date())
      await self.finishOpeningHome(
        url: url,
        corpusRoot: corpusRoot,
        context: context,
        generation: generation
      )
    }
  }

  private func finishOpeningHome(
    url: URL,
    corpusRoot: URL,
    context: WorkspaceDocumentCorpusContext,
    generation: UInt64,
    allowsCreation: Bool? = nil
  ) async {
    guard !Task.isCancelled,
          dailyNoteNavigationGeneration == generation,
          isCurrentDocumentCorpusContext(context)
    else { return }
    do {
      let shouldCreate = allowsCreation ?? !automaticDailyNoteCreationDisabled
      if shouldCreate {
        try await ensureDailyNoteExists(at: url, context: context)
      } else if !(await dailyNoteExists(at: url)) {
        homeActivationTask = nil
        presentMissingDailyNote(
          at: url,
          corpusRoot: corpusRoot,
          opensHome: true,
          surface: .home,
          recordsHistory: true
        )
        return
      }
      let file = await Task.detached(priority: .userInitiated) {
        Self.corpusFileOffMain(for: url, corpusRoot: corpusRoot)
      }.value
      guard !Task.isCancelled,
            dailyNoteNavigationGeneration == generation,
            isCurrentDocumentCorpusContext(context)
      else { return }
      homeActivationTask = nil
      currentHomeDailyNotePath = file.path
      upsertCorpusFile(file)
      let thread = AIChatThreadRecord(
        title: file.name,
        file: file.path,
        line: 1,
        zone: file.directory.isEmpty ? "daily" : file.directory,
        modifiedAt: file.modifiedAt,
        idValue: nil
      )
      let location = WorkspaceLocation.aiChatThreadRecord(thread)
      if !isCurrentNavigationDestination(location: location, surface: .home, mode: .page)
        || expandedWorkspaceSurface != nil
        || isWorkspaceSurfacePaneClosed
        || isWorkspaceDetailPaneClosed
        || isWorkspaceDetailPaneExpanded {
        recordCurrentNavigationDestination()
      }
      selectedCorpusFileID = file.id
      selectedAIChatThreadRecordID = nil
      expandedWorkspaceSurface = nil
      isWorkspaceSurfacePaneClosed = false
      isWorkspaceDetailPaneClosed = false
      isWorkspaceDetailPaneExpanded = false
      activateDetailLocation(location, mode: .page, surface: .home, recordsHistory: false)
      statusText = "Home"
    } catch {
      guard !Task.isCancelled,
            dailyNoteNavigationGeneration == generation,
            isCurrentDocumentCorpusContext(context)
      else { return }
      homeActivationTask = nil
      errorText = error.localizedDescription
      statusText = "Could not open \(url.lastPathComponent)"
    }
  }

  public func createMissingDailyNote() {
    guard !isCreatingMissingDailyNote,
          let missingDailyNote,
          let corpusRoot,
          let context = captureDocumentCorpusContext()
    else { return }

    let url = URL(fileURLWithPath: missingDailyNote.file).standardizedFileURL
    if selectedSurface != missingDailyNote.surface {
      selectedSurface = missingDailyNote.surface
    }
    let generation = supersedeDailyNoteNavigation()
    isCreatingMissingDailyNote = true
    if missingDailyNote.opensHome {
      homeActivationTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.isCreatingMissingDailyNote = false }
        await self.finishOpeningHome(
          url: url,
          corpusRoot: corpusRoot,
          context: context,
          generation: generation,
          allowsCreation: true
        )
      }
    } else {
      dailyNoteActivationTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.isCreatingMissingDailyNote = false }
        await self.openDailyNote(
          at: url,
          corpusRoot: corpusRoot,
          context: context,
          generation: generation,
          allowsCreation: true
        )
      }
    }
  }

  public func ensureHomeDetailReady() {
    if expandedWorkspaceSurface != nil { expandedWorkspaceSurface = nil }
    if isWorkspaceSurfacePaneClosed { isWorkspaceSurfacePaneClosed = false }
    if isWorkspaceDetailPaneClosed { isWorkspaceDetailPaneClosed = false }
    if isWorkspaceDetailPaneExpanded { isWorkspaceDetailPaneExpanded = false }
    guard isTodayHomeDetailSelected else {
      guard homeActivationTask == nil else { return }
      openHome()
      return
    }
  }

  private var isTodayHomeDetailSelected: Bool {
    if selectedSurface == .home,
       missingDailyNote?.opensHome == true {
      return true
    }
    guard selectedSurface == .home,
          selectedEntrySourceMode == .page,
          let selectedLocation,
          let currentHomeDailyNotePath
    else {
      return false
    }
    return URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path
      == currentHomeDailyNotePath
  }

  public var canStartAIChatVoiceNoteRecording: Bool {
    !isRecordingAIChatVoiceNote
      && !isTranscribingAIChatVoiceNote
      && !isRecordingMeeting
      && !isProcessingMeeting
  }

  public func toggleAIChatVoiceNoteRecording() async {
    if isRecordingAIChatVoiceNote {
      await stopAIChatVoiceNoteRecording(action: .insertIntoComposer)
    } else {
      await startAIChatVoiceNoteRecording()
    }
  }

  public func startAIChatVoiceNoteRecording() async {
    guard !isRecordingAIChatVoiceNote else { return }
    guard !isTranscribingAIChatVoiceNote else {
      aiChatVoiceStatusText = "Finish transcribing the current dictation first."
      aiChatStatusText = aiChatVoiceStatusText
      return
    }
    guard !isRecordingMeeting && !isProcessingMeeting else {
      aiChatVoiceStatusText = "Finish the current meeting recording first."
      aiChatStatusText = aiChatVoiceStatusText
      return
    }

    ensureAIChatThread()
    guard let threadID = selectedAIChatThreadID,
          let thread = aiChatThreads.first(where: { $0.id == threadID })
    else {
      aiChatVoiceStatusText = "Open an AI chat before dictating."
      aiChatStatusText = aiChatVoiceStatusText
      return
    }
    let origin = AIChatDictationOrigin(
      threadID: threadID,
      threadTitle: thread.title,
      runtime: thread.runtime,
      workspaceContext: threadScopedAIChatWorkspaceContext(for: thread),
      context: captureAIChatCorpusContext()
    )

    let audioURL = Self.aiChatVoiceNoteURL()
    do {
      activeAIChatDictationOrigin = origin
      try await aiChatVoiceRecorder.startRecording(to: audioURL)
      activeAIChatVoiceNoteURL = audioURL
      isRecordingAIChatVoiceNote = true
      aiChatVoiceStatusText = "Recording dictation for \(origin.threadTitle)..."
      aiChatStatusText = aiChatVoiceStatusText
      startAIChatVoiceMetering()
    } catch {
      activeAIChatVoiceNoteURL = nil
      activeAIChatDictationOrigin = nil
      isRecordingAIChatVoiceNote = false
      stopAIChatVoiceMetering()
      errorText = error.localizedDescription
      aiChatVoiceStatusText = "Dictation failed: \(error.localizedDescription)"
      aiChatStatusText = aiChatVoiceStatusText
    }
  }

  public func stopAIChatVoiceNoteRecording(
    action: AIChatDictationCompletionAction = .insertIntoComposer
  ) async {
    guard let audioURL = activeAIChatVoiceNoteURL,
          let origin = activeAIChatDictationOrigin
    else {
      aiChatVoiceStatusText = "No active AI chat dictation recording."
      aiChatStatusText = aiChatVoiceStatusText
      return
    }
    defer { activeAIChatDictationOrigin = nil }

    let duration: TimeInterval
    do {
      duration = try aiChatVoiceRecorder.stopRecording()
    } catch {
      activeAIChatVoiceNoteURL = nil
      activeAIChatDictationOrigin = nil
      isRecordingAIChatVoiceNote = false
      isTranscribingAIChatVoiceNote = false
      stopAIChatVoiceMetering()
      stopAIChatVoiceTranscriptionProgress()
      reportFailedAIChatDictation(
        audioURL: audioURL,
        message: "Dictation stop failed: \(error.localizedDescription)"
      )
      return
    }
    activeAIChatVoiceNoteURL = nil
    isRecordingAIChatVoiceNote = false
    stopAIChatVoiceMetering()
    await finishAIChatDictation(audioURL: audioURL, duration: duration, origin: origin, action: action)
  }

  func finishAIChatDictationForTesting(
    audioURL: URL,
    duration: TimeInterval,
    threadID: UUID
  ) async {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else { return }
    let origin = AIChatDictationOrigin(
      threadID: threadID,
      threadTitle: thread.title,
      runtime: thread.runtime,
      workspaceContext: threadScopedAIChatWorkspaceContext(for: thread),
      context: captureAIChatCorpusContext()
    )
    await finishAIChatDictation(
      audioURL: audioURL,
      duration: duration,
      origin: origin,
      action: .insertIntoComposer
    )
  }

  /// Keeps the recording of a dictation that produced no text and surfaces
  /// the failure as a visible error, so a long dictation is never lost.
  private func reportFailedAIChatDictation(audioURL: URL, message: String) {
    var visibleMessage = message
    if let keptURL = Self.retainFailedAIChatDictationAudio(
      audioURL,
      in: aiChatDictationRecoveryDirectory
    ) {
      visibleMessage += " The recording was kept at \(keptURL.path)."
    }
    errorText = visibleMessage
    aiChatVoiceStatusText = visibleMessage
    aiChatStatusText = visibleMessage
  }

  nonisolated static var defaultAIChatDictationRecoveryDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/org2/failed-dictations", isDirectory: true)
  }

  nonisolated static func retainFailedAIChatDictationAudio(_ audioURL: URL, in directory: URL) -> URL? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: audioURL.path) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
    let destination = directory.appendingPathComponent(
      "dictation-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(ext)"
    )
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try fileManager.moveItem(at: audioURL, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private func finishAIChatDictation(
    audioURL: URL,
    duration: TimeInterval,
    origin: AIChatDictationOrigin,
    action: AIChatDictationCompletionAction
  ) async {
    guard duration >= 0.2 else {
      try? FileManager.default.removeItem(at: audioURL)
      aiChatVoiceStatusText = "Dictation was too short."
      aiChatStatusText = aiChatVoiceStatusText
      return
    }

    isTranscribingAIChatVoiceNote = true
    aiChatVoiceStatusText = "Transcribing dictation for \(origin.threadTitle) locally..."
    aiChatStatusText = aiChatVoiceStatusText
    startAIChatVoiceTranscriptionProgress(audioDuration: duration)

    let transcript = await transcribeAudioForAIChatVoiceNote(audioURL)
    isTranscribingAIChatVoiceNote = false
    stopAIChatVoiceTranscriptionProgress()
    let dictatedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard transcript.status == .complete, !dictatedText.isEmpty else {
      let suffix = transcript.errorMessage.map { ": \($0)" } ?? ""
      reportFailedAIChatDictation(
        audioURL: audioURL,
        message: "Dictation transcription \(transcript.status.label)\(suffix)."
      )
      return
    }
    // Text is in hand; the audio is no longer needed.
    try? FileManager.default.removeItem(at: audioURL)
    guard isCurrentAIChatCorpusContext(origin.context) else {
      returnAIChatDictationToOriginComposer(dictatedText, origin: origin)
      return
    }

    switch action {
    case .insertIntoComposer:
      if insertAIChatDictationIntoDraft(dictatedText, in: origin.threadID) {
        aiChatVoiceStatusText = "Dictation added to \(origin.threadTitle)."
      } else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictatedText, forType: .string)
        aiChatVoiceStatusText =
          "The original AI chat is no longer available. The dictation was copied to the clipboard."
        errorText = aiChatVoiceStatusText
      }
      aiChatStatusText = aiChatVoiceStatusText
    case .send:
      aiChatVoiceStatusText = "Sending dictated note in \(origin.threadTitle)..."
      aiChatStatusText = aiChatVoiceStatusText
      let accepted = await sendAIChatDictation(
        dictatedText,
        to: origin.threadID,
        workspaceContext: origin.workspaceContext,
        context: origin.context
      )
      guard isCurrentAIChatCorpusContext(origin.context) else {
        if !accepted {
          returnAIChatDictationToOriginComposer(dictatedText, origin: origin)
        }
        return
      }
      if !accepted {
        returnAIChatDictationToOriginComposer(dictatedText, origin: origin)
        aiChatVoiceStatusText = "Dictation could not be sent and was returned to \(origin.threadTitle)'s composer."
        aiChatStatusText = aiChatVoiceStatusText
      }
    }
  }

  public func chooseAIChatImageAttachments() {
    chooseAIChatAttachments(allowedContentTypes: [.image])
  }

  public func chooseAIChatAttachments() {
    chooseAIChatAttachments(allowedContentTypes: nil)
  }

  private func chooseAIChatAttachments(allowedContentTypes: [UTType]?) {
    if let aiChatAttachmentPanel {
      NSApplication.shared.activate(ignoringOtherApps: true)
      aiChatAttachmentPanel.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if let allowedContentTypes {
      panel.allowedContentTypes = allowedContentTypes
    }
    panel.prompt = "Attach"
    panel.message = "Choose files or images to add to this message."
    aiChatAttachmentPanel = panel
    panel.begin { [weak self, weak panel] response in
      let selectedURLs = response == .OK ? panel?.urls ?? [] : []
      Task { @MainActor [weak self, weak panel] in
        guard let self, self.aiChatAttachmentPanel === panel else { return }
        self.aiChatAttachmentPanel = nil
        guard response == .OK else { return }
        self.enqueueAIChatAttachmentPreparation(
          urls: selectedURLs,
          imagesOnly: allowedContentTypes == [.image]
        )
      }
    }
  }

  private func enqueueAIChatAttachmentPreparation(
    urls: [URL],
    imagesOnly: Bool
  ) {
    guard !urls.isEmpty else { return }
    let originThreadID = selectedAIChatThreadID
    let originContext = captureAIChatCorpusContext()
    let previous = aiChatAttachmentPreparationTail
    aiChatStatusText = urls.count == 1
      ? "Attaching \(urls[0].lastPathComponent)…"
      : "Attaching \(urls.count) files…"
    aiChatAttachmentPreparationTail = Task { @MainActor [weak self] in
      _ = await previous?.value
      guard let self else { return }
      let results = await Task.detached(priority: .userInitiated) {
        urls.map { url in
          do {
            let attachment = try imagesOnly
              ? Self.aiChatImageAttachment(from: url)
              : Self.aiChatAttachment(from: url)
            return AIChatAttachmentPreparationResult(
              fileName: url.lastPathComponent,
              attachment: attachment,
              errorDescription: nil
            )
          } catch {
            return AIChatAttachmentPreparationResult(
              fileName: url.lastPathComponent,
              attachment: nil,
              errorDescription: error.localizedDescription
            )
          }
        }
      }.value
      self.finishAIChatAttachmentPreparation(
        results,
        originThreadID: originThreadID,
        originContext: originContext
      )
    }
  }

  private func finishAIChatAttachmentPreparation(
    _ results: [AIChatAttachmentPreparationResult],
    originThreadID: UUID?,
    originContext: AIChatCorpusContextToken
  ) {
    let isCurrentComposer = isCurrentAIChatAttachmentContext(originContext)
      && selectedAIChatThreadID == originThreadID
    let originAttachments: [AIChatAttachment]
    if let originThreadID {
      let key = aiChatComposerKey(for: originThreadID, context: originContext)
      originAttachments = aiChatAttachmentsByComposerKey[key]
        ?? (isCurrentComposer ? aiChatPendingAttachments : [])
    } else {
      originAttachments = isCurrentComposer ? aiChatPendingAttachments : []
    }

    var attachments = originAttachments
    for result in results {
      if let attachment = result.attachment {
        guard !attachments.contains(where: { $0.hasSameContent(as: attachment) }) else { continue }
        attachments.append(attachment)
      } else if let errorDescription = result.errorDescription {
        errorText = errorDescription
        aiChatStatusText = "Could not attach \(result.fileName)"
      }
    }

    if let originThreadID {
      cacheAIChatAttachments(attachments, for: originThreadID, context: originContext)
    }
    guard isCurrentComposer else { return }
    aiChatPendingAttachments = attachments
    if !attachments.isEmpty {
      aiChatStatusText = "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s") ready"
    }
  }

  func waitForAIChatAttachmentPreparationForTesting() async {
    await aiChatAttachmentPreparationTail?.value
  }

  func enqueueAIChatAttachmentPreparationForTesting(
    urls: [URL],
    imagesOnly: Bool = false
  ) {
    enqueueAIChatAttachmentPreparation(urls: urls, imagesOnly: imagesOnly)
  }

  func advanceAIChatTranscriptLoadGenerationForTesting() {
    aiChatTranscriptLoadGeneration &+= 1
  }

  public func attachAIChatImages(urls: [URL]) {
    addAIChatAttachments(urls: urls, makeAttachment: Self.aiChatImageAttachment)
  }

  public func attachAIChatFiles(urls: [URL]) {
    addAIChatAttachments(urls: urls, makeAttachment: Self.aiChatAttachment)
  }

  private func addAIChatAttachments(
    urls: [URL],
    makeAttachment: (URL) throws -> AIChatAttachment
  ) {
    var attachments = aiChatPendingAttachments
    for url in urls {
      do {
        let attachment = try makeAttachment(url)
        guard !attachments.contains(where: { $0.hasSameContent(as: attachment) }) else {
          continue
        }
        attachments.append(attachment)
      } catch {
        errorText = error.localizedDescription
        aiChatStatusText = "Could not attach \(url.lastPathComponent)"
      }
    }
    aiChatPendingAttachments = attachments
    if let selectedAIChatThreadID {
      cacheAIChatAttachments(attachments, for: selectedAIChatThreadID)
    }
    if !attachments.isEmpty {
      aiChatStatusText = "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s") ready"
    }
  }

  @discardableResult
  public func attachAIChatAttachment(data: Data, fileName: String, mimeType: String) -> Bool {
    do {
      let attachment = try Self.aiChatAttachment(
        data: data,
        fileName: fileName,
        mimeType: mimeType
      )
      guard !aiChatPendingAttachments.contains(where: {
        $0.hasSameContent(as: attachment)
      }) else { return true }
      aiChatPendingAttachments.append(attachment)
      if let selectedAIChatThreadID {
        cacheAIChatAttachments(aiChatPendingAttachments, for: selectedAIChatThreadID)
      }
      aiChatStatusText = "\(aiChatPendingAttachments.count) attachment\(aiChatPendingAttachments.count == 1 ? "" : "s") ready"
      return true
    } catch {
      errorText = error.localizedDescription
      aiChatStatusText = "Could not attach \(fileName)"
      return false
    }
  }

  public func removeAIChatPendingAttachment(_ attachment: AIChatAttachment) {
    aiChatPendingAttachments.removeAll { $0.id == attachment.id }
    if let selectedAIChatThreadID {
      cacheAIChatAttachments(aiChatPendingAttachments, for: selectedAIChatThreadID)
    }
  }

  public func clearAIChatPendingAttachments() {
    aiChatPendingAttachments = []
    if let selectedAIChatThreadID {
      cacheAIChatAttachments([], for: selectedAIChatThreadID)
    }
  }

  public func sendAIChatMessage() async {
    let text = aiChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = aiChatPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    ensureAIChatThread()
    guard let threadID = selectedAIChatThreadID else { return }
    let context = captureAIChatCorpusContext()
    let submission = captureAIChatComposerSubmission(
      threadID: threadID,
      draft: aiChatDraft,
      attachments: attachments,
      context: context
    )
    let result = submitAIChatMessage(
      text,
      attachments: attachments,
      in: threadID,
      context: context
    )
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(result)
    if case .enqueued = outcome {
      clearAcceptedAIChatComposerSubmission(submission)
    } else {
      preserveRejectedAIChatComposerSubmission(submission)
    }
  }

  public func sendAIChatMessage(text rawText: String) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    ensureAIChatThread()
    guard let threadID = selectedAIChatThreadID else { return }
    let context = captureAIChatCorpusContext()
    let submission = captureAIChatComposerSubmission(
      threadID: threadID,
      draft: rawText,
      attachments: [],
      context: context
    )
    let result = submitAIChatMessage(
      text,
      attachments: [],
      in: threadID,
      context: context
    )
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(result)
    if case .enqueued = outcome {
      clearAcceptedAIChatComposerSubmission(submission)
    } else {
      preserveRejectedAIChatComposerSubmission(submission)
    }
  }

  @discardableResult
  func insertAIChatDictationIntoDraft(_ rawText: String, in threadID: UUID) -> Bool {
    let dictatedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !dictatedText.isEmpty,
          aiChatThreads.contains(where: { $0.id == threadID })
    else { return false }

    let updatedDraft = Self.aiChatDraftByAppendingDictation(
      existing: aiChatDraft(for: threadID),
      dictatedText: dictatedText
    )
    cacheAIChatDraft(updatedDraft, for: threadID)
    if selectedAIChatThreadID == threadID {
      aiChatDraft = updatedDraft
    }
    return true
  }

  @discardableResult
  func sendAIChatDictation(
    _ rawText: String,
    to threadID: UUID,
    workspaceContext: AIChatWorkspaceContext? = nil
  ) async -> Bool {
    await sendAIChatDictation(
      rawText,
      to: threadID,
      workspaceContext: workspaceContext,
      context: captureAIChatCorpusContext()
    )
  }

  @discardableResult
  private func sendAIChatDictation(
    _ rawText: String,
    to threadID: UUID,
    workspaceContext: AIChatWorkspaceContext?,
    context: AIChatCorpusContextToken
  ) async -> Bool {
    let contextToken = context
    guard isCurrentAIChatCorpusContext(contextToken) else { return false }
    let dictatedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !dictatedText.isEmpty,
          let thread = aiChatThreads.first(where: { $0.id == threadID }),
          !thread.isSettled
    else { return false }

    let existingDraft = aiChatDraft(for: threadID)
    let text = Self.aiChatDraftByAppendingDictation(
      existing: existingDraft,
      dictatedText: dictatedText
    )
    let submission = captureAIChatComposerSubmission(
      threadID: threadID,
      draft: existingDraft,
      attachments: [],
      context: contextToken
    )
    let context = workspaceContext ?? threadScopedAIChatWorkspaceContext(for: thread)
    let result = submitAIChatMessage(
      text,
      attachments: [],
      in: threadID,
      workspaceContext: context,
      context: contextToken
    )
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(result)
    if case .enqueued = outcome {
      clearAcceptedAIChatComposerSubmission(submission)
      return true
    }
    preserveRejectedAIChatComposerSubmission(submission)
    return false
  }

  private func returnAIChatDictationToOriginComposer(
    _ dictatedText: String,
    origin: AIChatDictationOrigin
  ) {
    let existing = aiChatDraft(for: origin.threadID, context: origin.context)
    let updated = Self.aiChatDraftByAppendingDictation(
      existing: existing,
      dictatedText: dictatedText
    )
    cacheAIChatDraft(updated, for: origin.threadID, context: origin.context)
    if isCurrentAIChatCorpusContext(origin.context),
       selectedAIChatThreadID == origin.threadID {
      aiChatDraft = updated
    }
  }

  public var openClawGatewayConnectionState: OpenClawGatewayConnectionState {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return .disconnected }
    return openClawGatewayStateByThreadID[threadID] ?? .disconnected
  }

  public var openClawGatewayConnectionDetail: String? {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return nil }
    return openClawGatewayDetailByThreadID[threadID]
  }

  public var aiChatLastEventAt: Date? {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return nil }
    return aiChatLastEventAtByThreadID[threadID]
  }

  public var aiChatActiveRunID: String? {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return nil }
    return aiChatActiveRunIDByThreadID[threadID]
  }

  public var selectedAIChatStreamingReply: String {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return "" }
    return aiChatLiveState.streamingReply(for: threadID)
  }

  public func aiChatStreamingReply(for threadID: UUID) -> String {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return "" }
    return aiChatLiveState.streamingReply(for: threadID)
  }

  public var selectedAIChatExposedReasoning: String {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return "" }
    return aiChatLiveState.reasoning(for: threadID)
  }

  public func aiChatReasoning(for threadID: UUID) -> String {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return "" }
    return aiChatLiveState.reasoning(for: threadID)
  }

  public func aiChatLivePresentationSnapshot(
    for threadID: UUID
  ) -> AIChatLivePresentationSnapshot {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return .empty }
    return aiChatLiveState.presentationSnapshot(for: threadID)
  }

  public var selectedAIChatRunActivities: [AIChatRunActivity] {
    guard let threadID = selectedAIChatThreadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return [] }
    return aiChatRunActivitiesByThreadID[threadID] ?? []
  }

  public func aiChatRunActivities(for threadID: UUID) -> [AIChatRunActivity] {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return [] }
    return aiChatRunActivitiesByThreadID[threadID] ?? []
  }

  public func aiChatActiveDestinationID(for threadID: UUID) -> String? {
    if isAIChatRuntimeStateVisible(for: threadID),
       let activeDestinationID = activeSharedRoomDestinationByThreadID[threadID] {
      return activeDestinationID
    }
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      return nil
    }
    return aiChatActiveDestinationID(for: thread)
  }

  /// The same answer for a thread the caller already holds. Callers iterating
  /// every thread use this; looking each one up by ID scanned (and copied)
  /// the whole thread array per thread, quadratic on a long chat history.
  public func aiChatActiveDestinationID(for thread: AIChatThread) -> String? {
    let threadID = thread.id
    if isAIChatRuntimeStateVisible(for: threadID),
       let activeDestinationID = activeSharedRoomDestinationByThreadID[threadID] {
      return activeDestinationID
    }
    guard thread.isSharedRoom else { return thread.destinationID }
    // An unloaded room has no send in flight on this host. Reading its
    // messages would load it from disk as a side effect; the thread list asks
    // about every room on every phone poll, and those loads evicted other
    // threads and re-sorted the whole history each time.
    guard !unloadedAIChatThreadIDs.contains(threadID) else { return nil }
    return aiChatMessages(for: threadID)
      .first(where: {
        $0.role == .user
          && $0.deliveryStatus == .sending
          && !$0.isRoomDispatchCopy
      })?
      .targetDestinationID
  }

  public func isAIChatThreadRunning(_ threadID: UUID) -> Bool {
    (drainingAIChatThreadIDs.contains(threadID)
      && isAIChatRuntimeStateVisible(for: threadID))
      || aiChatSendingThreadIDs.contains(threadID)
      || aiChatRemoteLiveTurn(for: threadID) != nil
      || aiChatThreads.first(where: { $0.id == threadID }).map { thread in
        thread.pendingTurn.map { pendingTurn in
          thread.messages.contains { message in
            message.id == pendingTurn.userMessageID
              && message.role == .user
              && message.deliveryStatus == .sending
          }
        } == true
          || thread.messages.contains { message in
            message.role == .user
              && message.deliveryStatus == .sending
              && message.deliveryKind != .followUp
              // A host whose fresh presence no longer reports the turn has
              // finished it; its reply is on the way through synchronization.
              && isAIChatMessageActiveOnRemoteHost(message, in: threadID) != false
          }
      } == true
  }

  /// Reports only work this process can currently drive or recover. Persisted
  /// `sending` messages are portable transcript state and may have originated
  /// on another synced host, so they are not sufficient for a remote-control
  /// client to offer live status or controls through this host.
  public func isAIChatThreadRunningOnCurrentHost(_ threadID: UUID) -> Bool {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return false }
    return drainingAIChatThreadIDs.contains(threadID)
      || aiChatSendingThreadIDs.contains(threadID)
      || aiChatDrainTasksByThreadID[threadID] != nil
      || aiChatRecoveryTasksByThreadID[threadID] != nil
  }

  /// The persisted send that keeps a chat counted as running, mirroring the
  /// message clauses of `isAIChatThreadRunning`. Room dispatch copies are
  /// included: an agent-requested hand-off has no visible bubble of its own.
  func aiChatBlockingSend(in threadID: UUID) -> AIChatMessage? {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else { return nil }
    let preferredIDs = [activeAIChatUserMessageIDByThreadID[threadID], thread.pendingTurn?.userMessageID]
      .compactMap { $0 }
    for id in preferredIDs {
      if let message = thread.messages.first(where: {
        $0.id == id && $0.role == .user && $0.deliveryStatus == .sending
      }) {
        return message
      }
    }
    return thread.messages.first { message in
      message.role == .user
        && message.deliveryStatus == .sending
        && message.deliveryKind != .followUp
        && isAIChatMessageActiveOnRemoteHost(message, in: threadID) != false
    }
  }

  /// What a chat that counts as running is waiting on when nothing streams:
  /// no send this process presents and no host reporting the turn live.
  /// New messages queue behind such a turn, so it must stay visible and
  /// stoppable. Without this the sidebar said Working while the transcript
  /// showed no activity and offered no way to stop it.
  public func aiChatUnobservedTurn(for threadID: UUID) -> AIChatUnobservedTurn? {
    guard isAIChatThreadRunning(threadID),
          !aiChatSendingThreadIDs.contains(threadID),
          aiChatRemoteLiveTurn(for: threadID) == nil,
          let thread = aiChatThreads.first(where: { $0.id == threadID })
    else { return nil }
    let blocking = aiChatBlockingSend(in: threadID)
    let destination = aiChatDestinationTitle(
      blocking?.targetDestinationID
        ?? activeSharedRoomDestinationByThreadID[threadID]
        ?? thread.destinationID
    )
    guard let blocking else {
      return AIChatUnobservedTurn(
        messageID: nil,
        title: "\(destination) is working",
        detail: "Celorga is preparing this turn.",
        canRecheck: false
      )
    }
    if blocking.deliveryIsUnconfirmed {
      return AIChatUnobservedTurn(
        messageID: blocking.id,
        title: "\(destination) delivery is unconfirmed",
        detail: "Celorga lost track of whether \(destination) started this turn. "
          + "Recheck follows it without sending it again; Stop releases the chat.",
        canRecheck: true
      )
    }
    let startingHost = blocking.provenance.flatMap { provenance -> String? in
      guard let ref = provenance.executionHostRef, ref != aiChatHostIdentity.ref else { return nil }
      return provenance.executionHostName ?? ref
    }
    return AIChatUnobservedTurn(
      messageID: blocking.id,
      title: "Waiting for \(destination)",
      detail: startingHost.map {
        "This turn started on \($0), which is not reporting progress. Stop releases the chat."
      } ?? "No Celorga host is reporting progress for this turn. Stop releases the chat.",
      canRecheck: false
    )
  }

  public func aiChatConnectionState(for threadID: UUID) -> OpenClawGatewayConnectionState {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return .disconnected }
    return openClawGatewayStateByThreadID[threadID] ?? .disconnected
  }

  public func aiChatConnectionDetail(for threadID: UUID) -> String? {
    guard isAIChatRuntimeStateVisible(for: threadID) else { return nil }
    return openClawGatewayDetailByThreadID[threadID]
  }

  public var selectedAIChatRuntime: AIChatRuntime {
    guard let selectedAIChatThreadID,
          let thread = aiChatThreads.first(where: { $0.id == selectedAIChatThreadID })
    else {
      return defaultAIChatDestination.runtime
    }
    return thread.runtime
  }

  /// Display name of the selected chat's destination, such as a configured
  /// Dot or remote host. Use this, not the runtime family, to name who replies.
  public var selectedAIChatDestinationTitle: String {
    selectedAIChatDestination.title
  }

  public var enabledAIChatDestinations: [AIChatDestinationConfiguration] {
    aiChatDestinations.filter(\.isEnabled)
  }

  public func aiChatDestination(id: String) -> AIChatDestinationConfiguration? {
    aiChatDestinations.first(where: { $0.id == id })
  }

  /// The destination used when nothing more specific was chosen: the first
  /// enabled destination in the user's configured order. No runtime, including
  /// the built-in OpenClaw Gateway, is privileged as an implicit fallback.
  public var defaultAIChatDestination: AIChatDestinationConfiguration {
    enabledAIChatDestinations.first
      ?? aiChatDestinations.first
      ?? AIChatDestinationConfiguration.defaults[0]
  }

  public var selectedAIChatDestination: AIChatDestinationConfiguration {
    guard let thread = selectedAIChatThread else {
      return defaultAIChatDestination
    }
    return aiChatDestination(id: thread.destinationID)
      ?? aiChatDestinations.first(where: { $0.runtime == thread.runtime })
      ?? AIChatDestinationConfiguration.defaults.first(where: { $0.runtime == thread.runtime })!
  }

  public func aiChatDestinationTitle(_ destinationID: String) -> String {
    aiChatDestination(id: destinationID)?.title ?? destinationID
  }

  public var aiChatDestinationTitlesByID: [String: String] {
    Dictionary(uniqueKeysWithValues: aiChatDestinations.map { ($0.id, $0.title) })
  }

  public func aiChatDestinationRuntime(_ destinationID: String) -> AIChatRuntime {
    aiChatDestination(id: destinationID)?.runtime
      ?? {
        switch destinationID {
        case AIChatDestinationConfiguration.localCodexID: .codex
        case AIChatDestinationConfiguration.localClaudeID: .claude
        case AIChatDestinationConfiguration.localPiID: .pi
        case AIChatDestinationConfiguration.localOpenCodeID: .openCode
        default: .openClaw
        }
      }()
  }

  public func addAIChatDestination(
    adapter: AIChatDestinationAdapter = .codexRemote
  ) -> String {
    let destination = makeAIChatDestinationDraft(adapter: adapter)
    updateAIChatDestination(destination)
    return destination.id
  }

  public func makeAIChatDestinationDraft(
    adapter: AIChatDestinationAdapter = .codexRemote
  ) -> AIChatDestinationConfiguration {
    uniquelyMentioned(AIChatDestinationConfiguration.defaults.first(where: {
      $0.adapter == adapter && aiChatDestination(id: $0.id) == nil
    }) ?? AIChatDestinationConfiguration(
      name: adapter.defaultName,
      mention: adapter.defaultMention,
      adapter: adapter,
      endpoint: adapter.defaultEndpoint
    ))
  }

  public func makeAIChatDestinationDraft(
    preset: AIChatProviderPreset
  ) -> AIChatDestinationConfiguration {
    uniquelyMentioned(AIChatDestinationConfiguration(preset: preset))
  }

  private func uniquelyMentioned(
    _ draft: AIChatDestinationConfiguration
  ) -> AIChatDestinationConfiguration {
    let existingMentions = Set(aiChatDestinations.map { $0.mention.lowercased() })
    var destination = draft
    destination.isEnabled = true
    var suffix = 1
    let baseMention = destination.mention
    var mention = baseMention
    while existingMentions.contains(mention) {
      suffix += 1
      mention = "\(baseMention)-\(suffix)"
    }
    destination.mention = mention
    return destination
  }

  public func updateAIChatDestination(_ destination: AIChatDestinationConfiguration) {
    var normalized = destination
    normalized.name = destination.name.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.mention = AIChatDestinationConfiguration.normalizedMention(destination.mention)
    normalized.endpoint = destination.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.agentID = destination.agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.workspaceRoot = destination.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = destination.model?.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.model = model?.isEmpty == false ? model : nil
    // The built-in OpenClaw destination is the configurable default gateway.
    // Keep its agent inherited from OpenClaw Chat settings; explicit agent
    // targets belong in separate named destinations.
    if normalized.id == AIChatDestinationConfiguration.openClawID {
      normalized.agentID = ""
    }
    guard !aiChatDestinations.contains(where: {
      $0.id != normalized.id && $0.mention.caseInsensitiveCompare(normalized.mention) == .orderedSame
    }) else {
      aiChatDestinationSettingsError = "Every AI destination needs a unique @mention."
      return
    }
    normalized.isEnabled = true
    if let index = aiChatDestinations.firstIndex(where: { $0.id == normalized.id }) {
      aiChatDestinations[index] = normalized
    } else {
      aiChatDestinations.append(normalized)
    }
    aiChatDestinationSettingsError = nil
    invalidateCodexClient(forDestinationID: normalized.id)
    invalidateCLIChatClient(forDestinationID: normalized.id)
    removeCachedAIChatConfiguration(destinationID: normalized.id)
    persistAIChatDestinations()
  }

  @discardableResult
  public func removeAIChatDestination(_ destinationID: String) -> Bool {
    guard !aiChatThreads.contains(where: {
      $0.destinationID == destinationID || $0.roomDestinationIDs.contains(destinationID)
    }) else {
      aiChatDestinationSettingsError = "This destination is used by an existing chat. Delete that chat before deleting its destination."
      return false
    }
    aiChatDestinations.removeAll(where: { $0.id == destinationID })
    invalidateCodexClient(forDestinationID: destinationID)
    invalidateCLIChatClient(forDestinationID: destinationID)
    removeCachedAIChatConfiguration(destinationID: destinationID)
    try? AIChatDestinationCredentials.deleteToken(destinationID: destinationID)
    aiChatDestinationSettingsError = nil
    persistAIChatDestinations()
    return true
  }

  public func aiChatDestinationHasToken(_ destinationID: String) -> Bool {
    AIChatDestinationCredentials.containsToken(destinationID: destinationID)
  }

  public func saveAIChatDestinationToken(_ token: String, destinationID: String) {
    do {
      let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.isEmpty {
        try AIChatDestinationCredentials.deleteToken(destinationID: destinationID)
      } else {
        try AIChatDestinationCredentials.saveToken(normalized, destinationID: destinationID)
      }
      invalidateCodexClient(forDestinationID: destinationID)
      removeCachedAIChatConfiguration(destinationID: destinationID)
      aiChatDestinationSettingsError = nil
    } catch {
      aiChatDestinationSettingsError = error.localizedDescription
    }
  }

  private func persistAIChatDestinations() {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults),
          let data = try? JSONEncoder().encode(aiChatDestinations)
    else { return }
    defaults.set(data, forKey: aiChatDestinationsKey)
  }

  nonisolated static func restoreAIChatDestinations(
    from defaults: UserDefaults,
    key: String
  ) -> [AIChatDestinationConfiguration] {
    let stored = defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([AIChatDestinationConfiguration].self, from: $0)
    }
    let destinations = (stored ?? AIChatDestinationConfiguration.defaults)
      .filter(\.isEnabled)
    var seen = Set<String>()
    return destinations.map { destination in
      var normalized = destination
      normalized.isEnabled = true
      normalized.mention = AIChatDestinationConfiguration.normalizedMention(destination.mention)
      if normalized.adapter == .codexManagedRemote,
         normalized.name == "Managed Remote Codex" {
        normalized.name = "Remote Codex"
      }
      // Early destination builds persisted `main` here, which silently
      // overrode the user's configured OpenClaw Chat Agent. Treat the built-in
      // destination as inherited and migrate that value away on restore.
      if normalized.id == AIChatDestinationConfiguration.openClawID {
        normalized.agentID = ""
      }
      if seen.contains(normalized.mention) {
        normalized.mention += "-\(seen.count + 1)"
      }
      seen.insert(normalized.mention)
      return normalized
    }
  }

  public var selectedAIChatIsSharedRoom: Bool {
    selectedAIChatThread?.isSharedRoom == true
  }

  public var selectedAIChatAudience: AIChatAudience {
    guard let thread = selectedAIChatThread else { return .openClaw }
    return thread.isSharedRoom ? .thread : AIChatAudience(runtime: thread.runtime)
  }

  public var selectedAIChatDisplayTitle: String {
    selectedAIChatIsSharedRoom ? "Shared Room" : selectedAIChatDestination.title
  }

  public var selectedAIChatActiveRuntime: AIChatRuntime {
    aiChatDestinationRuntime(selectedAIChatActiveDestinationID)
  }

  public var selectedAIChatActiveDestinationID: String {
    guard let threadID = selectedAIChatThreadID else { return selectedAIChatDestination.id }
    return activeSharedRoomDestinationByThreadID[threadID] ?? selectedAIChatDestination.id
  }

  public var selectedAIChatActiveRoomRoundID: UUID? {
    guard selectedAIChatIsSharedRoom,
          let threadID = selectedAIChatThreadID,
          let messageID = activeAIChatUserMessageIDByThreadID[threadID]
    else {
      return nil
    }
    return aiChatMessages(for: threadID)
      .first(where: { $0.id == messageID })?
      .roomRoundID
  }

  public var canChangeSelectedAIChatRuntime: Bool {
    guard let selectedAIChatThread else { return false }
    return selectedAIChatThread.canChangeAIRuntime
      && !isSendingAIChatMessage
  }

  public var selectedAIChatModel: String? {
    selectedAIChatThread?.model
  }

  public var selectedAIChatReasoningEffort: String? {
    selectedAIChatThread?.reasoningEffort
  }

  public var canChangeSelectedAIChatConfiguration: Bool {
    selectedAIChatThread.map { !$0.isSharedRoom } == true
      && !isSendingAIChatMessage
  }

  public var selectedAIChatModelLabel: String {
    let model = selectedAIChatModel ?? aiChatEffectiveModel
    guard let model else { return "Model" }
    return aiChatModelOptions.first(where: { $0.id == model })?.label
      ?? model.split(separator: "/").last.map(String.init)
      ?? model
  }

  public func selectedAIChatRoomModel(for runtime: AIChatRuntime) -> String? {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return nil }
    return thread.roomModels.model(for: runtime)
  }

  public var selectedAIChatRoomDestinationIDs: [String] {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return [] }
    return thread.roomDestinationIDs
  }

  public func selectedAIChatRoomModel(forDestinationID destinationID: String) -> String? {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return nil }
    return thread.model(forDestinationID: destinationID)
  }

  public func selectedAIChatRoomModelLabel(forDestinationID destinationID: String) -> String {
    guard let model = selectedAIChatRoomModel(forDestinationID: destinationID) else { return "Default" }
    return aiChatDestinationModelOptions[destinationID]?
      .first(where: { $0.id == model })?
      .label
      ?? model.split(separator: "/").last.map(String.init)
      ?? model
  }

  public func selectedAIChatRoomReasoningEffort(forDestinationID destinationID: String) -> String? {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return nil }
    return thread.roomReasoningEffortsByDestination[destinationID]
  }

  /// Reasoning efforts a shared-room destination accepts for its selected
  /// (or default) model. Empty when the destination has no effort control.
  public func selectedAIChatRoomReasoningOptions(
    forDestinationID destinationID: String
  ) -> [AIChatReasoningOption] {
    guard let destination = aiChatDestination(id: destinationID) else { return [] }
    return Self.aiChatRoomReasoningOptions(
      adapter: destination.adapter,
      selectedModel: selectedAIChatRoomModel(forDestinationID: destinationID),
      models: aiChatDestinationModelOptions[destinationID] ?? [],
      preset: destination.providerPreset
    )
  }

  nonisolated static func aiChatRoomReasoningOptions(
    adapter: AIChatDestinationAdapter,
    selectedModel: String?,
    models: [AIChatModelOption],
    preset: AIChatProviderPreset? = nil
  ) -> [AIChatReasoningOption] {
    if let preset { return preset.reasoningOptions }
    switch adapter {
    case .codexLocal, .codexRemote, .codexManagedRemote:
      let option = selectedModel.flatMap { selected in
        models.first(where: { $0.id == selected })
      } ?? models.first(where: \.isDefault)
      return option?.reasoningOptions ?? []
    case .piLocal, .piRemote, .openCodeLocal, .openCodeRemote:
      return cliHarnessReasoningOptions
    case .openClaw:
      // OpenClaw reports thinking levels per session; rooms offer the
      // standard levels when the model reasons. The Gateway still validates.
      let option = selectedModel.flatMap { selected in
        models.first(where: { $0.id == selected })
      }
      if let option, !option.supportsReasoning { return [] }
      return cliHarnessReasoningOptions
    case .claudeLocal, .openAI, .anthropic, .openRouter, .ollama, .openAIDot:
      return []
    }
  }

  public func selectedAIChatRoomReasoningLabel(forDestinationID destinationID: String) -> String? {
    guard let effort = selectedAIChatRoomReasoningEffort(forDestinationID: destinationID) else {
      return nil
    }
    return selectedAIChatRoomReasoningOptions(forDestinationID: destinationID)
      .first(where: { $0.id == effort })?.label
      ?? Self.aiChatReasoningLabel(effort)
  }

  public func setSelectedAIChatRoomReasoningEffort(
    _ reasoningEffort: String?,
    forDestinationID destinationID: String
  ) {
    guard let selectedAIChatThreadID,
          !isAIChatThreadRunning(selectedAIChatThreadID),
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].isSharedRoom,
          aiChatThreads[index].roomDestinationIDs.contains(destinationID),
          aiChatThreads[index].roomReasoningEffortsByDestination[destinationID] != reasoningEffort
    else {
      return
    }
    var nextEfforts = aiChatThreads[index].roomReasoningEffortsByDestination
    nextEfforts[destinationID] = reasoningEffort
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(roomReasoningEffortsByDestination: nextEfforts)
    persistAIChatTranscript()
    aiChatStatusText = reasoningEffort == nil
      ? "\(aiChatDestinationTitle(destinationID)) will use its default reasoning"
      : "\(aiChatDestinationTitle(destinationID)) will use \(selectedAIChatRoomReasoningLabel(forDestinationID: destinationID) ?? reasoningEffort!) reasoning"
  }

  public func selectedAIChatRoomModelLabel(for runtime: AIChatRuntime) -> String {
    guard let model = selectedAIChatRoomModel(for: runtime) else { return "Default" }
    return aiChatRoomModelOptions[runtime]?
      .first(where: { $0.id == model })?
      .label
      ?? model.split(separator: "/").last.map(String.init)
      ?? model
  }

  public var selectedAIChatReasoningLabel: String {
    let reasoningEffort = selectedAIChatReasoningEffort ?? aiChatDefaultReasoningEffort
    guard let reasoningEffort else { return "Reasoning" }
    return aiChatReasoningOptions.first(where: {
      $0.id == reasoningEffort
    })?.label ?? Self.aiChatReasoningLabel(reasoningEffort)
  }

  public func setSelectedAIChatRuntime(_ runtime: AIChatRuntime) {
    guard let destination = enabledAIChatDestinations.first(where: { $0.runtime == runtime }) else {
      return
    }
    setSelectedAIChatDestination(destination.id)
  }

  var selectedChatAgentRef: String? {
    aiChatThreads.first(where: { $0.id == selectedAIChatThreadID })?.agentRef
  }

  var selectedChatAgent: AgentProfileItem? {
    agentProfiles.first(where: { $0.id == selectedChatAgentRef })
  }

  var canChangeChatAgent: Bool {
    guard let thread = aiChatThreads.first(where: { $0.id == selectedAIChatThreadID }) else { return false }
    return !thread.isSharedRoom && !isAIChatThreadRunning(thread.id)
  }

  func setSelectedChatAgent(_ profile: AgentProfileItem?) {
    guard canChangeChatAgent else { return }
    if let runtime = profile?.preferredChatRuntime,
       canChangeSelectedAIChatRuntime,
       let destination = preferredAIChatDestination(for: runtime),
       destination.id != selectedAIChatDestination.id {
      setSelectedAIChatDestination(destination.id)
    }
    guard let index = aiChatThreads.firstIndex(where: { $0.id == selectedAIChatThreadID }) else { return }
    aiChatThreads[index] = aiChatThreads[index].replacingAIChatMetadata(agentRef: .some(profile?.id))
    persistAIChatTranscript()
  }

  private func preferredAIChatDestination(for runtime: AIChatRuntime) -> AIChatDestinationConfiguration? {
    let defaultID = AIChatDestinationConfiguration.defaultID(for: runtime)
    return enabledAIChatDestinations.first(where: { $0.id == defaultID })
      ?? enabledAIChatDestinations.first(where: { $0.runtime == runtime })
  }

  public func setSelectedAIChatDestination(_ destinationID: String) {
    guard canChangeSelectedAIChatRuntime,
          let destination = aiChatDestination(id: destinationID),
          destination.isEnabled,
          let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].destinationID != destinationID
    else {
      return
    }
    let runtime = destination.runtime
    let lastConfiguration = preferredAIChatConfiguration(forDestinationID: destinationID)
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(
        runtime: runtime,
        destinationID: destinationID,
        runtimeThreadID: .some(nil),
        runtimeThreadIDsByDestination: [:],
        model: .some(lastConfiguration?.model),
        reasoningEffort: .some(lastConfiguration?.reasoningEffort)
      )
    if !applyCachedAIChatConfiguration(for: aiChatThreads[index]) {
      aiChatModelOptions = []
      aiChatReasoningOptions = []
      aiChatEffectiveModel = nil
      aiChatDefaultReasoningEffort = nil
    }
    aiChatStatusText = "Ready for a \(destination.title) message"
    sortAIChatThreadsForDisplay()
    persistAIChatTranscript()
    Task { @MainActor [weak self] in
      await self?.refreshAIChatConfiguration()
    }
  }

  /// The enabled agent that receives this shared room's messages when they
  /// have no @mention, or `nil` when such messages only post context.
  func aiChatRoomDefaultDestinationID(for thread: AIChatThread) -> String? {
    guard let destinationID = thread.roomDefaultDestination,
          aiChatDestination(id: destinationID)?.isEnabled == true
    else { return nil }
    return destinationID
  }

  /// Agents a shared-room message reaches, in order: its @mentions, an
  /// explicit audience, or else the room's default agent.
  func aiChatRoomTargets(
    for text: String,
    in thread: AIChatThread,
    audience: AIChatAudience? = nil
  ) -> (destinationIDs: [String], normalizedText: String) {
    let routing = AIChatDestinationRouting(
      text,
      destinations: enabledAIChatDestinations,
      allDestinationIDs: thread.roomDestinationIDs
    )
    var destinationIDs = routing.destinationIDs
    if destinationIDs.isEmpty, let audience {
      destinationIDs = audience.runtimes.map(AIChatDestinationConfiguration.defaultID(for:))
    }
    if destinationIDs.isEmpty, let defaultDestinationID = aiChatRoomDefaultDestinationID(for: thread) {
      destinationIDs = [defaultDestinationID]
    }
    return (destinationIDs, routing.normalizedText)
  }

  public var selectedAIChatRoomDefaultDestinationID: String? {
    selectedAIChatThread.flatMap(aiChatRoomDefaultDestinationID(for:))
  }

  /// Agents a shared-room message reaches: its @mentions, or else the room's
  /// default agent. Empty means the message only posts context.
  public func selectedAIChatRoomTargetDestinationIDs(for text: String) -> [String] {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return [] }
    let routing = AIChatDestinationRouting(
      text,
      destinations: enabledAIChatDestinations,
      allDestinationIDs: thread.roomDestinationIDs
    )
    if !routing.destinationIDs.isEmpty { return routing.destinationIDs }
    return aiChatRoomDefaultDestinationID(for: thread).map { [$0] } ?? []
  }

  /// Chooses the agent that receives un-mentioned messages in the open
  /// shared room. `nil` makes such messages post context only. An @mention
  /// still routes just that message and never changes this default.
  public func setSelectedAIChatRoomDefaultDestination(_ destinationID: String?) {
    guard let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: { $0.id == selectedAIChatThreadID }),
          aiChatThreads[index].isSharedRoom
    else { return }
    if let destinationID {
      guard aiChatDestination(id: destinationID)?.isEnabled == true else { return }
    }
    let thread = aiChatThreads[index]
    let storedValue = destinationID ?? AIChatThread.noRoomDefaultDestinationID
    guard thread.roomDefaultDestinationID != storedValue else { return }
    var participants = thread.roomDestinationIDs
    if let destinationID, !participants.contains(destinationID) {
      participants.append(destinationID)
    }
    aiChatThreads[index] = thread.replacingAIChatMetadata(
      roomDestinationIDs: participants,
      roomDefaultDestinationID: .some(storedValue)
    )
    persistAIChatTranscript()
    aiChatStatusText = destinationID.map {
      "Messages without an @mention go to \(aiChatDestinationTitle($0))"
    } ?? "Messages without an @mention post context only"
  }

  public var selectedAIChatRoomAgentTurnLimit: Int? {
    guard let thread = selectedAIChatThread, thread.isSharedRoom else { return nil }
    return aiChatRoomAgentTurnLimit(for: thread)
  }

  /// Whether the open room follows the app-wide limit rather than its own.
  public var selectedAIChatRoomUsesDefaultAgentTurnLimit: Bool {
    selectedAIChatThread?.roomAgentTurnLimit == nil
  }

  /// The room's own limit, or the app-wide default from Settings → AI Chat.
  public func aiChatRoomAgentTurnLimit(for thread: AIChatThread) -> Int {
    thread.roomAgentTurnLimit ?? aiChatDefaultRoomAgentTurnLimit
  }

  /// Sets how many agent-requested turns may run back to back in the open
  /// shared room before a person must reply. `0` turns hand-offs off and
  /// `nil` restores the default.
  public func setSelectedAIChatRoomAgentTurnLimit(_ limit: Int?) {
    guard let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: { $0.id == selectedAIChatThreadID }),
          aiChatThreads[index].isSharedRoom
    else { return }
    let stored = limit.map { min(max($0, 0), AIChatThread.maxRoomAgentTurnLimit) }
    guard aiChatThreads[index].roomAgentTurnLimit != stored else { return }
    aiChatThreads[index] = aiChatThreads[index].replacingAIChatMetadata(
      roomAgentTurnLimit: .some(stored)
    )
    persistAIChatTranscript()
    let effective = aiChatRoomAgentTurnLimit(for: aiChatThreads[index])
    aiChatStatusText = effective == 0
      ? "Agents can no longer start each other's turns in this room"
      : "Agents can start up to \(effective) turn\(effective == 1 ? "" : "s") in a row"
  }

  /// Queues the turns an agent message asks for in a shared room: room agents
  /// it @mentions (`mentionedIn`) or explicitly requested responder tokens
  /// (`responderTokens`, from a background post). Returns the transcript with
  /// hidden dispatch messages (and any refusal notice) appended, plus the
  /// dispatch IDs to enqueue once that transcript is stored.
  func appendingAIChatAgentTurnRequests(
    to messages: [AIChatMessage],
    in thread: AIChatThread,
    from request: AIChatMessage,
    requesterLabel: String,
    requesterDestinationID: String?,
    mentionedIn reply: String? = nil,
    responderTokens: [String] = []
  ) -> (messages: [AIChatMessage], dispatchIDs: [UUID]) {
    guard thread.isSharedRoom else { return (messages, []) }
    let destinations = enabledAIChatDestinations
    var requestedIDs: [String] = []
    var notices: [String] = []
    if let reply {
      requestedIDs = AIChatAgentTurnRequests.requestedDestinationIDs(
        inReply: reply,
        authorDestinationID: requesterDestinationID,
        roomDestinationIDs: thread.roomDestinationIDs,
        destinations: destinations
      )
    }
    if !responderTokens.isEmpty {
      let resolved = AIChatAgentTurnRequests.resolveResponderTokens(
        responderTokens,
        roomDestinationIDs: thread.roomDestinationIDs,
        destinations: destinations
      )
      for id in resolved.destinationIDs where !requestedIDs.contains(id) && id != requesterDestinationID {
        requestedIDs.append(id)
      }
      if !resolved.unresolved.isEmpty {
        let names = resolved.unresolved.map { "@\($0)" }.joined(separator: ", ")
        notices.append("\(requesterLabel) asked \(names) to respond, but no enabled agent has that name.")
      }
    }
    guard !requestedIDs.isEmpty || !notices.isEmpty else { return (messages, []) }

    let limit = aiChatRoomAgentTurnLimit(for: thread)
    let used = AIChatAgentTurnRequests.consecutiveRequestedTurnCount(in: messages)
    let admitted = AIChatAgentTurnRequests.admittedCount(
      requested: requestedIDs.count,
      alreadyUsed: used,
      limit: limit
    )
    let refused = Array(requestedIDs.dropFirst(admitted))
    let accepted = Array(requestedIDs.prefix(admitted))
    // An agent that only mentions another agent while hand-offs are off
    // stays quiet; an explicit request always explains why nothing ran.
    if !refused.isEmpty, limit > 0 || !responderTokens.isEmpty {
      let names = refused.map(aiChatDestinationTitle).joined(separator: " + ")
      notices.append(limit == 0
        ? "\(requesterLabel) asked \(names) to respond, but agent hand-offs are off in this room."
        : "\(requesterLabel) asked \(names) to respond, but agents already started \(limit) turn\(limit == 1 ? "" : "s") in a row here. Reply to let them continue, or raise the limit in the room's Default menu or Settings → AI Chat.")
    }

    // An explicitly requested agent outside the room joins it, as it would
    // when a person @mentions it.
    let joining = accepted.filter { !thread.roomDestinationIDs.contains($0) }
    if !joining.isEmpty,
       let index = aiChatThreads.firstIndex(where: { $0.id == thread.id }) {
      let current = aiChatThreads[index]
      let participants = (current.roomDestinationIDs + joining).reduce(into: [String]()) {
        if !$0.contains($1) { $0.append($1) }
      }
      aiChatThreads[index] = current.replacingAIChatMetadata(roomDestinationIDs: participants)
    }

    var nextMessages = messages
    var dispatchIDs: [UUID] = []
    let createdAt = max(Date(), request.createdAt)
    for destinationID in accepted {
      var provenance = aiChatUserMessageProvenance(origin: nil, routedTo: nil, at: createdAt)
      provenance.originClient = .automation
      provenance.requestedByLabel = requesterLabel
      provenance.requestedByDestinationID = requesterDestinationID
      provenance.requestedByMessageID = request.id
      let dispatch = AIChatMessage(
        role: .user,
        content: request.content,
        createdAt: createdAt,
        deliveryStatus: .sending,
        deliveryKind: .turn,
        audience: AIChatAudience(runtime: aiChatDestinationRuntime(destinationID)),
        targetRuntime: aiChatDestinationRuntime(destinationID),
        audienceDestinationIDs: [destinationID],
        targetDestinationID: destinationID,
        isRoomDispatchCopy: true,
        roomRoundID: UUID(),
        provenance: provenance
      )
      nextMessages.append(dispatch)
      dispatchIDs.append(dispatch.id)
    }
    for notice in notices {
      nextMessages.append(AIChatMessage(role: .system, content: notice, createdAt: createdAt))
    }
    return (nextMessages, dispatchIDs)
  }

  /// Enqueues stored agent-requested dispatches and starts the room's queue
  /// unless a running drain (or another host's turn) will reach them.
  func enqueueAIChatAgentTurnRequests(_ dispatchIDs: [UUID], in threadID: UUID) {
    guard !dispatchIDs.isEmpty else { return }
    for id in dispatchIDs { enqueueAIChatUserMessage(id, in: threadID) }
    let names = aiChatMessages(for: threadID)
      .filter { dispatchIDs.contains($0.id) }
      .compactMap { $0.targetDestinationID.map(aiChatDestinationTitle) }
    if selectedAIChatThreadID == threadID, !names.isEmpty {
      aiChatStatusText = "Asking \(names.joined(separator: " + "))…"
    }
    guard !drainingAIChatThreadIDs.contains(threadID) else { return }
    if let ownerID = aiChatThreads.first(where: { $0.id == threadID })?.pendingTurn?.dispatchOwnerID,
       ownerID != Self.aiChatDispatchOwnerID {
      return
    }
    Task { @MainActor [weak self] in await self?.drainAIChatSendQueue(for: threadID) }
  }

  public func setSelectedAIChatAudience(_ audience: AIChatAudience) {
    guard let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].isSharedRoom,
          aiChatThreads[index].roomAudience != audience,
          !isSendingAIChatMessage
    else { return }
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(roomAudience: audience)
    persistAIChatTranscript()
    aiChatStatusText = "Next message will go to \(audience.title)"
  }

  public func setSelectedAIChatModel(_ model: String?) {
    guard canChangeSelectedAIChatConfiguration,
          let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].model != model
            || aiChatThreads[index].reasoningEffort != nil
    else {
      return
    }
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(
        model: .some(model),
        reasoningEffort: .some(nil)
      )
    persistLastAIChatConfiguration(
      destinationID: aiChatThreads[index].destinationID,
      model: model,
      reasoningEffort: nil
    )
    aiChatReasoningOptions = reasoningOptions(
      for: model,
      runtime: aiChatThreads[index].runtime
    )
    aiChatDefaultReasoningEffort = defaultReasoningEffort(
      for: model,
      runtime: aiChatThreads[index].runtime
    )
    persistAIChatTranscript()
    Task { @MainActor [weak self] in
      await self?.refreshAIChatConfiguration(applySelection: true)
    }
  }

  public func setSelectedAIChatRoomModel(_ model: String?, for runtime: AIChatRuntime) {
    guard let destinationID = selectedAIChatRoomDestinationIDs.first(where: {
      aiChatDestinationRuntime($0) == runtime
    }) else { return }
    setSelectedAIChatRoomModel(model, forDestinationID: destinationID)
  }

  public func setSelectedAIChatRoomModel(_ model: String?, forDestinationID destinationID: String) {
    guard let selectedAIChatThreadID,
          !isAIChatThreadRunning(selectedAIChatThreadID),
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].isSharedRoom,
          aiChatThreads[index].model(forDestinationID: destinationID) != model
    else {
      return
    }
    var nextModels = aiChatThreads[index].roomModelsByDestination
    nextModels[destinationID] = model
    if model == nil { nextModels.removeValue(forKey: destinationID) }
    // A different model may not support the previous effort, so the
    // destination returns to its default effort, as in single-agent chats.
    var nextEfforts = aiChatThreads[index].roomReasoningEffortsByDestination
    nextEfforts.removeValue(forKey: destinationID)
    let runtime = aiChatDestinationRuntime(destinationID)
    let legacyModels = aiChatThreads[index].roomModels.replacingModel(model, for: runtime)
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(
        roomModels: legacyModels,
        roomModelsByDestination: nextModels,
        roomReasoningEffortsByDestination: nextEfforts
      )
    persistAIChatTranscript()
    aiChatStatusText = model == nil
      ? "\(aiChatDestinationTitle(destinationID)) will use its default model"
      : "\(aiChatDestinationTitle(destinationID)) will use \(selectedAIChatRoomModelLabel(forDestinationID: destinationID))"
  }

  public func setSelectedAIChatReasoningEffort(_ reasoningEffort: String?) {
    guard canChangeSelectedAIChatConfiguration,
          let selectedAIChatThreadID,
          let index = aiChatThreads.firstIndex(where: {
            $0.id == selectedAIChatThreadID
          }),
          aiChatThreads[index].reasoningEffort != reasoningEffort
    else {
      return
    }
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(reasoningEffort: .some(reasoningEffort))
    persistLastAIChatConfiguration(
      destinationID: aiChatThreads[index].destinationID,
      model: aiChatThreads[index].model,
      reasoningEffort: reasoningEffort
    )
    persistAIChatTranscript()
    guard aiChatThreads[index].runtime == .openClaw else { return }
    Task { @MainActor [weak self] in
      await self?.refreshAIChatConfiguration(applySelection: true)
    }
  }

  public func refreshAIChatConfiguration(
    applySelection: Bool = false,
    forceModelCatalogReload: Bool = false
  ) async {
    refreshCorpusAgentSkills()
    guard let thread = selectedAIChatThread else {
      aiChatModelOptions = []
      aiChatRoomModelOptions = [:]
      aiChatReasoningOptions = []
      aiChatEffectiveModel = nil
      aiChatDefaultReasoningEffort = nil
      return
    }
    if CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_CORPUS") != nil {
      // The synthetic docs corpus already carries the model labels we want to
      // show. Avoid querying any configured local or remote agent destination
      // while an offscreen documentation capture is rendering.
      aiChatModelOptions = []
      aiChatRoomModelOptions = [:]
      aiChatDestinationModelOptions = [:]
      aiChatReasoningOptions = []
      aiChatEffectiveModel = thread.model
      aiChatDefaultReasoningEffort = thread.reasoningEffort
      isRefreshingAIChatConfiguration = false
      return
    }
    aiChatConfigurationGeneration &+= 1
    let generation = aiChatConfigurationGeneration
    let threadID = thread.id
    isRefreshingAIChatConfiguration = true
    defer {
      if generation == aiChatConfigurationGeneration {
        isRefreshingAIChatConfiguration = false
      }
    }

    if thread.isSharedRoom {
      aiChatModelOptions = []
      aiChatReasoningOptions = []
      aiChatEffectiveModel = nil
      aiChatDefaultReasoningEffort = nil
      let destinationIDs = thread.roomDestinationIDs
      let cachedPairs: [(String, [AIChatModelOption])] = thread.roomDestinationIDs.compactMap { destinationID in
        guard let models = aiChatConfigurationCatalogCache[destinationID]?.models,
              !models.isEmpty
        else { return nil }
        return (destinationID, models)
      }
      let cachedLoaded = Dictionary(uniqueKeysWithValues: cachedPairs)
      let refreshed = await withTaskGroup(
        of: (String, [AIChatModelOption]?).self,
        returning: [String: [AIChatModelOption]].self
      ) { group in
        for destinationID in destinationIDs {
          group.addTask { [weak self] in
            guard let self else { return (destinationID, nil) }
            return (
              destinationID,
              try? await self.modelsForAIChatDestination(
                destinationID,
                forceCodexModelCatalogReload: forceModelCatalogReload
              )
            )
          }
        }
        var result: [String: [AIChatModelOption]] = [:]
        for await (destinationID, models) in group {
          if let models, !models.isEmpty { result[destinationID] = models }
        }
        return result
      }
      guard generation == aiChatConfigurationGeneration,
            selectedAIChatThreadID == threadID
      else {
        return
      }
      for (destinationID, models) in refreshed {
        cacheAIChatModelCatalog(destinationID: destinationID, models: models)
      }
      let loaded = cachedLoaded.merging(refreshed) { _, fresh in fresh }
      aiChatDestinationModelOptions = loaded
      aiChatRoomModelOptions = Dictionary(uniqueKeysWithValues: AIChatRuntime.allCases.compactMap { runtime in
        destinationIDs.first(where: { aiChatDestinationRuntime($0) == runtime })
          .flatMap { loaded[$0] }
          .map { (runtime, $0) }
      })
      return
    }

    do {
      let models: [AIChatModelOption]
      let effectiveModel: String?
      let reasoningOptions: [AIChatReasoningOption]
      let defaultReasoningEffort: String?
      let resolvedReasoningConfiguration: Bool
      switch selectedAIChatDestination.adapter {
      case .codexLocal, .codexRemote, .codexManagedRemote:
        models = try await modelsForAIChatDestination(
          thread.destinationID,
          forceCodexModelCatalogReload: forceModelCatalogReload
        )
        let selectedModel = thread.model.flatMap { selected in
          models.first(where: { $0.id == selected })
        } ?? models.first(where: \.isDefault)
        effectiveModel = selectedModel?.id
        reasoningOptions = selectedModel?.reasoningOptions ?? []
        defaultReasoningEffort = selectedModel?.defaultReasoningEffort
        resolvedReasoningConfiguration = true
      case .claudeLocal:
        models = try await modelsForAIChatDestination(thread.destinationID)
        effectiveModel = thread.model
        reasoningOptions = []
        defaultReasoningEffort = nil
        resolvedReasoningConfiguration = true
      case .piLocal, .piRemote, .openCodeLocal, .openCodeRemote:
        models = try await modelsForAIChatDestination(thread.destinationID)
        effectiveModel = thread.model ?? selectedAIChatDestination.model
        reasoningOptions = Self.cliHarnessReasoningOptions
        defaultReasoningEffort = nil
        resolvedReasoningConfiguration = true
      case .openClaw:
        let settings = openClawSettings(forDestinationID: thread.destinationID, allowKeychainRead: true)
        let client = OpenClawGatewayClient(settings: settings)
        models = try await client.listModels()
        let configuration: OpenClawAIChatSessionConfiguration?
        if applySelection || thread.model != nil || thread.reasoningEffort != nil {
          configuration = try await client.patchSessionConfiguration(
            sessionKey: thread.sessionKey,
            agentID: OpenClawChatClient.openClawAgentHeaderValue(
              for: aiChatDestination(id: thread.destinationID)?.agentID.isEmpty == false
                ? aiChatDestination(id: thread.destinationID)!.agentID
                : openClawAgentID
            ),
            model: thread.model,
            reasoningEffort: thread.reasoningEffort
          )
        } else {
          configuration = try await client.sessionConfiguration(sessionKey: thread.sessionKey)
        }
        effectiveModel = configuration?.model
        reasoningOptions = configuration?.reasoningOptions ?? []
        defaultReasoningEffort = configuration?.defaultReasoningEffort
        resolvedReasoningConfiguration = configuration != nil
      case .openAI, .anthropic, .openRouter, .ollama:
        models = try await modelsForAIChatDestination(thread.destinationID)
        effectiveModel = thread.model
          ?? selectedAIChatDestination.model
          ?? models.first(where: \.isDefault)?.id
        let preset = aiChatDestination(id: thread.destinationID)?.providerPreset
        reasoningOptions = preset?.reasoningOptions ?? []
        defaultReasoningEffort = preset?.defaultReasoningEffort
        resolvedReasoningConfiguration = true
      case .openAIDot:
        // A dot chooses its own model in ChatGPT.
        models = []
        effectiveModel = nil
        reasoningOptions = []
        defaultReasoningEffort = nil
        resolvedReasoningConfiguration = true
      }

      guard generation == aiChatConfigurationGeneration,
            selectedAIChatThreadID == threadID
      else {
        return
      }
      let cached = aiChatConfigurationCatalogCache[thread.destinationID]
      let displayedModels = models.isEmpty ? cached?.models ?? [] : models
      let displayedEffectiveModel = effectiveModel ?? cached?.effectiveModel
      let canUseCachedReasoning = cached?.requestedModel == thread.model
      let displayedReasoningOptions = resolvedReasoningConfiguration
        ? reasoningOptions
        : canUseCachedReasoning ? cached?.reasoningOptions ?? [] : []
      let displayedDefaultReasoningEffort = resolvedReasoningConfiguration
        ? defaultReasoningEffort
        : canUseCachedReasoning ? cached?.defaultReasoningEffort : nil
      aiChatModelOptions = displayedModels
      aiChatEffectiveModel = displayedEffectiveModel
      aiChatReasoningOptions = displayedReasoningOptions
      aiChatDefaultReasoningEffort = displayedDefaultReasoningEffort
      cacheAIChatConfiguration(
        destinationID: thread.destinationID,
        requestedModel: thread.model,
        models: displayedModels,
        effectiveModel: displayedEffectiveModel,
        reasoningOptions: displayedReasoningOptions,
        defaultReasoningEffort: displayedDefaultReasoningEffort
      )
    } catch {
      guard generation == aiChatConfigurationGeneration,
            selectedAIChatThreadID == threadID
      else {
        return
      }
      // Catalog discovery is an enhancement. Preserve the last successful
      // choices through a temporary runtime or Gateway outage.
    }
  }
}
