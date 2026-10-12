import AppKit
import SwiftUI

struct OrgRenderedEntrySourceContext: Equatable, Sendable {
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let isSubtree: Bool
  let isEditable: Bool

  init(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    isSubtree: Bool,
    isEditable: Bool
  ) {
    self.file = file
    self.startLine = startLine
    self.endLineExclusive = endLineExclusive
    self.isSubtree = isSubtree
    self.isEditable = isEditable
  }

  init(_ source: EntrySource) {
    self.file = source.file
    self.startLine = source.startLine
    self.endLineExclusive = source.endLineExclusive
    self.isSubtree = source.isSubtree
    self.isEditable = source.isEditable
  }

  func overridingEditable(_ isEditable: Bool) -> OrgRenderedEntrySourceContext {
    OrgRenderedEntrySourceContext(
      file: file,
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      isSubtree: isSubtree,
      isEditable: isEditable
    )
  }

  var id: String {
    "\(file):\(startLine):\(endLineExclusive)"
  }
}

struct OrgRenderedEntryView: View, Equatable {
  @Environment(WorkspaceStore.self) private var store
  let blocks: [OrgEditableBlock]
  let blocksRenderSignature: String
  let source: OrgRenderedEntrySourceContext?
  let corpusRoot: URL?
  let selectedBlockID: OrgEditableBlock.ID?
  let selectedBlockIndex: Int?
  let editingBlockID: OrgEditableBlock.ID?
  let foldedBlockIDs: Set<OrgEditableBlock.ID>
  let detailScrollRequest: DetailScrollRequest?
  let sourceBlockRunsRenderSignature: String
  let sourceBlockRuns: [String: SourceBlockRunState]
  let searchHighlightQuery: String?
  @State private var renderedBlockWindow: Range<Int>?
  @State private var renderWindowResetKey = ""
  @State private var moveAvailability = OrgRenderedEntryMoveAvailability.empty

  init(
    blocks: [OrgEditableBlock],
    blocksRenderSignature: String,
    source: OrgRenderedEntrySourceContext?,
    corpusRoot: URL?,
    selectedBlockID: OrgEditableBlock.ID?,
    selectedBlockIndex: Int?,
    editingBlockID: OrgEditableBlock.ID?,
    foldedBlockIDs: Set<OrgEditableBlock.ID> = [],
    detailScrollRequest: DetailScrollRequest? = nil,
    sourceBlockRunsRenderSignature: String,
    sourceBlockRuns: [String: SourceBlockRunState],
    searchHighlightQuery: String? = nil
  ) {
    self.blocks = blocks
    self.blocksRenderSignature = blocksRenderSignature
    self.source = source
    self.corpusRoot = corpusRoot
    self.selectedBlockID = selectedBlockID
    self.selectedBlockIndex = selectedBlockIndex
    self.editingBlockID = editingBlockID
    self.foldedBlockIDs = foldedBlockIDs
    self.detailScrollRequest = detailScrollRequest
    self.sourceBlockRunsRenderSignature = sourceBlockRunsRenderSignature
    self.sourceBlockRuns = sourceBlockRuns
    self.searchHighlightQuery = searchHighlightQuery
  }

  nonisolated static func == (lhs: OrgRenderedEntryView, rhs: OrgRenderedEntryView) -> Bool {
    lhs.blocksRenderSignature == rhs.blocksRenderSignature
      && lhs.source == rhs.source
      && lhs.corpusRoot == rhs.corpusRoot
      && lhs.selectedBlockID == rhs.selectedBlockID
      && lhs.selectedBlockIndex == rhs.selectedBlockIndex
      && lhs.editingBlockID == rhs.editingBlockID
      && lhs.foldedBlockIDs == rhs.foldedBlockIDs
      && lhs.detailScrollRequest == rhs.detailScrollRequest
      && lhs.sourceBlockRunsRenderSignature == rhs.sourceBlockRunsRenderSignature
      && lhs.searchHighlightQuery == rhs.searchHighlightQuery
  }

  var body: some View {
    let sourceFile = source?.file
    let isSourceEditable = source?.isEditable == true
    let displayBlocks = OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: foldedBlockIDs)
    let selectedDisplayBlockIndex = selectedBlockID.flatMap { id in
      displayBlocks.firstIndex { $0.id == id }
    }
    let resetKey = Self.renderWindowResetKey(for: source)
    let visibleWindow = Self.visibleWindow(
      requestedWindow: renderedBlockWindow,
      blocks: displayBlocks,
      selectedBlockIndex: selectedDisplayBlockIndex
    )
    let visibleRange = visibleWindow.range
    let visibleBlocks = displayBlocks[visibleWindow.range]
    let visibleRows = visibleBlocks.filter(OrgRenderedBlockDisplayPolicy.isVisible)
    let allowsHoverChrome = Self.allowsHoverChrome(blockCount: displayBlocks.count)
    let moveAvailabilitySignature = OrgRenderedEntryMoveAvailability.signature(
      blocksSignature: "\(blocksRenderSignature):folds:\(foldedBlockIDs.sorted().joined(separator: ","))",
      source: source,
      visibleRange: visibleRange
    )
    let moveAvailabilityValues = moveAvailability.signature == moveAvailabilitySignature ? moveAvailability.values : [:]

    LazyVStack(alignment: .leading, spacing: 3) {
      if visibleWindow.hasPrevious {
        ProgressiveRenderFooter(
          visibleRange: visibleWindow.displayRange,
          totalCount: visibleWindow.totalCount,
          direction: .previous,
          autoLoadsOnAppear: false,
          loadMore: expandRenderedBlocks
        )
      }

      ForEach(visibleRows) { block in
        renderedRow(
          for: block,
          sourceFile: sourceFile,
          isSourceEditable: isSourceEditable,
          allowsHoverChrome: allowsHoverChrome,
          moveAvailabilityValues: moveAvailabilityValues
        )
      }

      if visibleWindow.hasNext {
        ProgressiveRenderFooter(
          visibleRange: visibleWindow.displayRange,
          totalCount: visibleWindow.totalCount,
          direction: .next,
          autoLoadsOnAppear: Self.shouldAutoExpandNextFooter(visibleWindow: visibleWindow),
          loadMore: expandRenderedBlocks
        )
      }

      if isSourceEditable && !visibleWindow.hasNext {
        RenderedPageBlankWritingArea {
          Task { await store.beginAppendingSectionAtEnd() }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.orgInlineSearchHighlightQuery, searchHighlightQuery)
    .onAppear {
      resetRenderedBlockLimitIfNeeded(resetKey: resetKey)
      refreshMoveAvailabilityIfNeeded(signature: moveAvailabilitySignature, source: source, visibleRange: visibleRange)
    }
    .onChange(of: resetKey) { _, newResetKey in
      resetRenderedBlockLimitIfNeeded(resetKey: newResetKey)
    }
    .onChange(of: selectedBlockID) { _, _ in
      if let selectedBlockIndex,
         let renderedBlockWindow,
         !renderedBlockWindow.contains(selectedBlockIndex) {
        self.renderedBlockWindow = nil
      }
    }
    .onChange(of: moveAvailabilitySignature) { _, newSignature in
      refreshMoveAvailabilityIfNeeded(signature: newSignature, source: source, visibleRange: visibleRange)
    }
  }

  private func renderedRow(
    for block: OrgEditableBlock,
    sourceFile: String?,
    isSourceEditable: Bool,
    allowsHoverChrome: Bool,
    moveAvailabilityValues: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability]
  ) -> some View {
    OrgRenderedEntryRow(
      block: block,
      isSourceEditable: isSourceEditable,
      isSelected: selectedBlockID == block.id,
      isEditing: editingBlockID == block.id,
      isFoldable: OrgRenderedFoldTree.isFoldable(block, in: blocks),
      isFolded: foldedBlockIDs.contains(block.id),
      canMoveUp: moveAvailabilityValues[block.id]?.up == true,
      canMoveDown: moveAvailabilityValues[block.id]?.down == true,
      sourceFile: sourceFile,
      corpusRoot: corpusRoot,
      allowsHoverChrome: allowsHoverChrome,
      searchHighlightQuery: searchHighlightQuery,
      actions: actions(for: block),
      inlineActions: inlineActions(for: block, isSourceEditable: isSourceEditable)
    )
    .equatable()
    .id(block.id)
    .background(DetailBlockRevealBridge(blockID: block.id, request: detailScrollRequest))
  }

  private func resetRenderedBlockLimitIfNeeded(resetKey: String) {
    guard resetKey != renderWindowResetKey else { return }
    renderWindowResetKey = resetKey
    renderedBlockWindow = nil
  }

  private func refreshMoveAvailabilityIfNeeded(
    signature: String,
    source: OrgRenderedEntrySourceContext?,
    visibleRange: Range<Int>
  ) {
    guard moveAvailability.signature != signature else { return }
    moveAvailability = OrgRenderedEntryMoveAvailability.make(
      for: OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: foldedBlockIDs),
      source: source,
      visibleRange: visibleRange,
      precomputedSignature: signature
    )
  }

  private func expandRenderedBlocks(_ direction: OrgRenderedBlockWindowExpansionDirection) {
    let visibleWindow = Self.visibleWindow(
      requestedWindow: renderedBlockWindow,
      blocks: OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: foldedBlockIDs),
      selectedBlockIndex: selectedBlockID.flatMap { id in
        OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: foldedBlockIDs).firstIndex { $0.id == id }
      }
    )
    renderedBlockWindow = visibleWindow.expanding(
      direction,
      by: Self.renderedBlockPageSize(for: visibleWindow.totalCount),
      totalCount: visibleWindow.totalCount
    )
  }

  private func actions(for block: OrgEditableBlock) -> RenderedBlockActions {
    RenderedBlockActions(
      select: {
        store.selectBlock(block)
      },
      beginEditing: {
        store.beginEditingSource(for: block)
      },
      beginEditingAt: { selection in
        store.beginEditingSource(for: block, selection: selection)
      },
      initialSelection: {
        store.initialSelectionForEditingBlock(block)
      },
      insert: { kind in
        Task { await store.insertBlock(after: block, kind: kind) }
      },
      move: { direction in
        Task { await store.moveBlock(block, direction: direction) }
      },
      askAI: {
        store.askAIChatAboutBlock(block)
      },
      duplicate: {
        Task { await store.duplicateBlock(block) }
      },
      delete: {
        Task { await store.deleteBlock(block) }
      },
      toggleFold: {
        store.toggleRenderedBlockFold(block)
      }
    )
  }

  private func inlineActions(for block: OrgEditableBlock, isSourceEditable: Bool) -> RenderedBlockInlineActions {
    let decryptSubtree: (@MainActor @Sendable () async -> OrgCryptRunResult)? = {
      guard isSourceEditable,
            OrgCrypt.armorSummary(block.rawText) != nil
      else {
        return nil
      }
      let line = OrgRenderedCryptTarget.headingLine(for: block, in: blocks)
      return {
        await store.runOrgCrypt(.decrypt, line: line)
      }
    }()
    let peekSubtree: (@MainActor @Sendable () -> Void)? = {
      guard OrgCrypt.armorSummary(block.rawText) != nil else { return nil }
      let line = block.startLine
      return { @MainActor @Sendable in
        let _: Task<Void, Never> = Task { await store.peekOrgCrypt(line: line) }
      }
    }()

    guard block.isEditable else {
      return RenderedBlockInlineActions(
        isSourceEditable: isSourceEditable,
        decryptSubtree: decryptSubtree,
        toggleHeadingTodo: nil,
        setHeadingPriority: nil,
        setHeadingTags: nil,
        setPlanningBlock: nil,
        setPropertyValue: nil,
        toggleListItemCheckbox: nil,
        sourceBlockRunRenderSignature: "",
        sourceBlockRunState: nil,
        runSourceBlock: nil,
        copySourceBlock: nil,
        peekSubtree: peekSubtree
      )
    }
    let runnableSourceLanguage: String? = {
      if Self.isRunnableSourceBlock(block),
         case .source(let language, _) = block.rendered {
        return language
      }
      return nil
    }()
    let sourceBlockRunState = runnableSourceLanguage != nil ? sourceBlockRuns[store.sourceBlockRunKey(for: block)] : nil
    let runSourceBlock: (@MainActor @Sendable () -> Void)?
    if runnableSourceLanguage != nil {
      runSourceBlock = { @MainActor @Sendable in
        let _: Task<Void, Never> = Task { await store.runSourceBlock(block) }
      }
    } else {
      runSourceBlock = nil
    }
    return RenderedBlockInlineActions(
      isSourceEditable: isSourceEditable,
      decryptSubtree: decryptSubtree,
      toggleHeadingTodo: {
        Task { await store.toggleHeadingTodo(block) }
      },
      setHeadingPriority: { priority in
        Task { await store.setHeadingPriority(block, priority: priority) }
      },
      setHeadingTags: { tags in
        Task { await store.setHeadingTags(block, tags: tags) }
      },
      setPlanningBlock: { kind, value in
        Task { await store.setPlanningBlock(block, kind: kind, value: value) }
      },
      setPropertyValue: { key, value in
        Task { await store.setPropertyValue(block, key: key, value: value) }
      },
      toggleListItemCheckbox: {
        Task { await store.toggleListItemCheckbox(block) }
      },
      sourceBlockRunRenderSignature: WorkspaceStore.sourceBlockRunRenderSignature(for: sourceBlockRunState),
      sourceBlockRunState: sourceBlockRunState,
      runSourceBlock: runSourceBlock,
      copySourceBlock: nil,
      peekSubtree: peekSubtree
    )
  }

  nonisolated static func visibleWindow(
    requestedWindow: Range<Int>?,
    blocks: [OrgEditableBlock],
    selectedBlockIndex: Int?
  ) -> OrgRenderedBlockWindow {
    guard !blocks.isEmpty else {
      return OrgRenderedBlockWindow(range: 0..<0, totalCount: 0)
    }

    if let requestedWindow {
      return OrgRenderedBlockWindow(
        range: clampedWindow(requestedWindow, totalCount: blocks.count, selectedBlockIndex: selectedBlockIndex),
        totalCount: blocks.count
      )
    }

    if let selectedBlockIndex,
       blocks.indices.contains(selectedBlockIndex),
       selectedBlockIndex >= selectedBlockAnchorThreshold {
      return OrgRenderedBlockWindow(
        range: anchoredWindow(around: selectedBlockIndex, totalCount: blocks.count),
        totalCount: blocks.count
      )
    }

    return OrgRenderedBlockWindow(
      range: 0..<min(blocks.count, initialRenderedBlockLimit(for: blocks.count)),
      totalCount: blocks.count
    )
  }

  nonisolated static func renderWindowResetKey(for source: EntrySource?) -> String {
    guard let source else { return "none" }
    return "\(source.file):\(source.startLine):\(source.isSubtree):\(source.isEditable)"
  }

  nonisolated static func renderWindowResetKey(for source: OrgRenderedEntrySourceContext?) -> String {
    guard let source else { return "none" }
    return "\(source.file):\(source.startLine):\(source.isSubtree):\(source.isEditable)"
  }

  nonisolated static func allowsHoverChrome(blockCount: Int) -> Bool {
    blockCount <= hoverChromeBlockLimit
  }

  nonisolated static func shouldAutoExpandNextFooter(visibleWindow: OrgRenderedBlockWindow) -> Bool {
    guard visibleWindow.hasNext else { return false }
    if visibleWindow.totalCount >= largePageBlockThreshold {
      return visibleWindow.range.lowerBound == 0
    }
    return visibleWindow.range.upperBound <= initialRenderedBlockLimit(for: visibleWindow.totalCount)
  }

  nonisolated static func isRunnableSourceBlock(_ block: OrgEditableBlock) -> Bool {
    if case .source(let language, _) = block.rendered {
      return SourceBlockRunPlan.plan(for: language) != nil
    }
    return false
  }

  nonisolated static func initialRenderedBlockLimit(for blockCount: Int) -> Int {
    blockCount >= largePageBlockThreshold ? largePageRenderedBlockLimit : defaultRenderedBlockLimit
  }

  nonisolated static func renderedBlockPageSize(for blockCount: Int) -> Int {
    blockCount >= largePageBlockThreshold ? largePageRenderedBlockLimit : defaultRenderedBlockLimit
  }

  nonisolated private static let defaultRenderedBlockLimit = 80
  nonisolated private static let largePageRenderedBlockLimit = 48
  nonisolated private static let largePageBlockThreshold = 1_000
  nonisolated private static let hoverChromeBlockLimit = 180
  nonisolated private static let selectedBlockAnchorThreshold = 120
  nonisolated private static let selectedBlockLookbehind = 24
  nonisolated private static let selectedBlockLookahead = 48

  nonisolated private static func anchoredWindow(around selectedIndex: Int, totalCount: Int) -> Range<Int> {
    let start = max(0, selectedIndex - selectedBlockLookbehind)
    let end = min(totalCount, selectedIndex + selectedBlockLookahead + 1)
    return start..<max(start, end)
  }

  nonisolated private static func clampedWindow(
    _ window: Range<Int>,
    totalCount: Int,
    selectedBlockIndex: Int?
  ) -> Range<Int> {
    let start = min(max(0, window.lowerBound), totalCount)
    let end = min(max(start, window.upperBound), totalCount)

    if let selectedBlockIndex,
       selectedBlockIndex >= 0,
       selectedBlockIndex < totalCount {
      if selectedBlockIndex < start || selectedBlockIndex >= end {
        return anchoredWindow(around: selectedBlockIndex, totalCount: totalCount)
      }
    }

    return start..<max(start, end)
  }
}

private struct DetailBlockRevealBridge: NSViewRepresentable {
  let blockID: OrgEditableBlock.ID
  let request: DetailScrollRequest?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let request,
          context.coordinator.lastRequestID != request.id,
          case .revealBlock(let targetBlockID) = request.target,
          targetBlockID == blockID
    else {
      return
    }
    context.coordinator.lastRequestID = request.id

    DispatchQueue.main.async {
      guard let scrollView = view.enclosingScrollView,
            let documentView = scrollView.documentView
      else {
        return
      }

      let rowRect = view.convert(view.bounds, to: documentView)
      guard !rowRect.isEmpty else { return }
      let paddedRowRect = rowRect.insetBy(dx: 0, dy: -18)
      guard !scrollView.documentVisibleRect.contains(paddedRowRect) else { return }
      documentView.scrollToVisible(paddedRowRect)
    }
  }

  final class Coordinator {
    var lastRequestID: Int?
  }
}

enum OrgRenderedCryptTarget {
  static func headingLine(for block: OrgEditableBlock, in blocks: [OrgEditableBlock]) -> Int {
    for candidate in blocks.reversed() where candidate.startLine <= block.startLine {
      if case .heading = candidate.rendered {
        return candidate.startLine
      }
    }
    return block.startLine
  }
}

enum OrgRenderedFoldTree {
  static func isFoldable(_ block: OrgEditableBlock, in blocks: [OrgEditableBlock]) -> Bool {
    childrenRange(for: block, in: blocks) != nil
  }

  static func visibleBlocks(
    _ blocks: [OrgEditableBlock],
    foldedBlockIDs: Set<OrgEditableBlock.ID>
  ) -> [OrgEditableBlock] {
    guard !foldedBlockIDs.isEmpty else { return blocks }
    var visible: [OrgEditableBlock] = []
    visible.reserveCapacity(blocks.count)
    var index = blocks.startIndex

    while index < blocks.endIndex {
      let block = blocks[index]
      visible.append(block)
      if foldedBlockIDs.contains(block.id),
         let range = childrenRange(startingAt: index, in: blocks) {
        index = range.upperBound
      } else {
        index += 1
      }
    }

    return visible
  }

  static func prunedFoldedIDs(
    _ foldedBlockIDs: Set<OrgEditableBlock.ID>,
    blocks: [OrgEditableBlock]
  ) -> Set<OrgEditableBlock.ID> {
    guard !foldedBlockIDs.isEmpty else { return [] }
    return Set(blocks.filter { foldedBlockIDs.contains($0.id) && isFoldable($0, in: blocks) }.map(\.id))
  }

  static func foldedAncestorID(
    hiding blockID: OrgEditableBlock.ID,
    foldedBlockIDs: Set<OrgEditableBlock.ID>,
    blocks: [OrgEditableBlock]
  ) -> OrgEditableBlock.ID? {
    guard let blockIndex = blocks.firstIndex(where: { $0.id == blockID }) else { return nil }
    for index in blocks.indices where foldedBlockIDs.contains(blocks[index].id) {
      guard let range = childrenRange(startingAt: index, in: blocks),
            range.contains(blockIndex)
      else {
        continue
      }
      return blocks[index].id
    }
    return nil
  }

  static func childrenRange(for block: OrgEditableBlock, in blocks: [OrgEditableBlock]) -> Range<Int>? {
    guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return nil }
    return childrenRange(startingAt: index, in: blocks)
  }

  private static func childrenRange(startingAt index: Int, in blocks: [OrgEditableBlock]) -> Range<Int>? {
    guard blocks.indices.contains(index), index + 1 < blocks.endIndex else { return nil }
    let endIndex: Int?
    switch blocks[index].rendered {
    case .heading(let heading):
      endIndex = headingChildrenEndIndex(after: index, level: heading.level, in: blocks)
    case .listItem(let indent, _, _, _):
      endIndex = listChildrenEndIndex(after: index, indent: indent, in: blocks)
    default:
      endIndex = nil
    }
    guard let endIndex, endIndex > index + 1 else { return nil }
    return (index + 1)..<endIndex
  }

  private static func headingChildrenEndIndex(after index: Int, level: Int, in blocks: [OrgEditableBlock]) -> Int {
    for candidate in (index + 1)..<blocks.endIndex {
      if case .heading(let nextHeading) = blocks[candidate].rendered,
         nextHeading.level <= level {
        return candidate
      }
    }
    return blocks.endIndex
  }

  private static func listChildrenEndIndex(after index: Int, indent: Int, in blocks: [OrgEditableBlock]) -> Int? {
    var hasChild = false
    for candidate in (index + 1)..<blocks.endIndex {
      guard case .listItem(let nextIndent, _, _, _) = blocks[candidate].rendered else {
        return hasChild ? candidate : nil
      }
      if nextIndent <= indent {
        return hasChild ? candidate : nil
      }
      hasChild = true
    }
    return hasChild ? blocks.endIndex : nil
  }
}

enum OrgRenderedBlockWindowExpansionDirection: Equatable, Sendable {
  case previous
  case next

  var title: String {
    switch self {
    case .previous: "Load previous"
    case .next: "Load more"
    }
  }

  var systemImage: String {
    switch self {
    case .previous: "arrow.up.circle"
    case .next: "arrow.down.circle"
    }
  }
}

struct OrgRenderedBlockWindow: Equatable, Sendable {
  let range: Range<Int>
  let totalCount: Int

  var hasPrevious: Bool {
    range.lowerBound > 0
  }

  var hasNext: Bool {
    range.upperBound < totalCount
  }

  var displayRange: String {
    guard !range.isEmpty else { return "0" }
    return "\(range.lowerBound + 1)-\(range.upperBound)"
  }

  func expanding(
    _ direction: OrgRenderedBlockWindowExpansionDirection,
    by count: Int,
    totalCount nextTotalCount: Int
  ) -> Range<Int> {
    let safeCount = max(1, count)
    let safeTotal = max(0, nextTotalCount)
    switch direction {
    case .previous:
      return max(0, range.lowerBound - safeCount)..<min(range.upperBound, safeTotal)
    case .next:
      return min(range.lowerBound, safeTotal)..<min(safeTotal, range.upperBound + safeCount)
    }
  }
}

private struct OrgRenderedEntryRow: View, Equatable {
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let isEditing: Bool
  let isFoldable: Bool
  let isFolded: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let sourceFile: String?
  let corpusRoot: URL?
  let allowsHoverChrome: Bool
  let searchHighlightQuery: String?
  let actions: RenderedBlockActions
  let inlineActions: RenderedBlockInlineActions

  nonisolated static func == (lhs: OrgRenderedEntryRow, rhs: OrgRenderedEntryRow) -> Bool {
    if lhs.isEditing || rhs.isEditing {
      return lhs.isEditing == rhs.isEditing
        && lhs.block.renderIdentity == rhs.block.renderIdentity
        && lhs.isSourceEditable == rhs.isSourceEditable
        && lhs.isSelected == rhs.isSelected
        && lhs.isFoldable == rhs.isFoldable
        && lhs.isFolded == rhs.isFolded
        && lhs.sourceFile == rhs.sourceFile
        && lhs.corpusRoot == rhs.corpusRoot
        && lhs.allowsHoverChrome == rhs.allowsHoverChrome
        && lhs.searchHighlightQuery == rhs.searchHighlightQuery
        && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
        && lhs.inlineActions.sourceBlockRunRenderSignature == rhs.inlineActions.sourceBlockRunRenderSignature
    }
    return lhs.block.renderIdentity == rhs.block.renderIdentity
      && lhs.isSourceEditable == rhs.isSourceEditable
      && lhs.isSelected == rhs.isSelected
      && lhs.isEditing == rhs.isEditing
      && lhs.isFoldable == rhs.isFoldable
      && lhs.isFolded == rhs.isFolded
      && lhs.canMoveUp == rhs.canMoveUp
      && lhs.canMoveDown == rhs.canMoveDown
      && lhs.sourceFile == rhs.sourceFile
      && lhs.corpusRoot == rhs.corpusRoot
      && lhs.allowsHoverChrome == rhs.allowsHoverChrome
      && lhs.searchHighlightQuery == rhs.searchHighlightQuery
      && lhs.inlineActions.isSourceEditable == rhs.inlineActions.isSourceEditable
      && lhs.inlineActions.sourceBlockRunRenderSignature == rhs.inlineActions.sourceBlockRunRenderSignature
  }

  var body: some View {
    if LiveRenderedTextEditingPolicy.usesDirectEditor(block: block, isSourceEditable: isSourceEditable) {
      EditableRenderedBlockView(
        block: block,
        isSourceEditable: isSourceEditable,
        isSelected: isSelected,
        isFoldable: isFoldable,
        isFolded: isFolded,
        canMoveUp: canMoveUp,
        canMoveDown: canMoveDown,
        allowsHoverChrome: allowsHoverChrome,
        actions: actions
      ) {
        LiveRenderedTextBlockEditor(block: block, initialSelection: actions.initialSelection())
      }
    } else if isEditing {
      InlineBlockEditorView(
        block: block,
        initialSelection: actions.initialSelection()
      )
    } else {
      EditableRenderedBlockView(
        block: block,
        isSourceEditable: isSourceEditable,
        isSelected: isSelected,
        isFoldable: isFoldable,
        isFolded: isFolded,
        canMoveUp: canMoveUp,
        canMoveDown: canMoveDown,
        allowsHoverChrome: allowsHoverChrome,
        actions: actions
      ) {
        RenderedBlockView(
          block: block.rendered,
          rawText: block.rawText,
          editableBlock: block,
          sourceFile: sourceFile,
          corpusRoot: corpusRoot,
          searchHighlightQuery: searchHighlightQuery,
          inlineActions: inlineActions
        )
        .equatable()
      }
    }
  }
}

struct OrgRenderedEntryBlockMoveAvailability: Equatable, Sendable {
  let up: Bool
  let down: Bool
}

struct OrgRenderedEntryMoveAvailability: Sendable {
  let signature: String
  let values: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability]

  static let empty = OrgRenderedEntryMoveAvailability(signature: "empty", values: [:])

  static func make(
    for blocks: [OrgEditableBlock],
    source: OrgRenderedEntrySourceContext?,
    visibleRange: Range<Int>? = nil,
    precomputedSignature: String? = nil
  ) -> OrgRenderedEntryMoveAvailability {
    let signature = precomputedSignature ?? signature(for: blocks, source: source, visibleRange: visibleRange)
    guard let source, source.isEditable else {
      return OrgRenderedEntryMoveAvailability(signature: signature, values: [:])
    }

    let targetRange = clampedVisibleRange(visibleRange, totalCount: blocks.count)
    guard let movableBounds = movableBounds(in: blocks, source: source) else {
      return OrgRenderedEntryMoveAvailability(signature: signature, values: [:])
    }
    var values: [OrgEditableBlock.ID: OrgRenderedEntryBlockMoveAvailability] = [:]
    values.reserveCapacity(targetRange.count)
    for index in targetRange {
      let block = blocks[index]
      guard isMovable(block, in: source) else { continue }
      values[block.id] = OrgRenderedEntryBlockMoveAvailability(
        up: index > movableBounds.first,
        down: index < movableBounds.last
      )
    }

    return OrgRenderedEntryMoveAvailability(signature: signature, values: values)
  }

  static func signature(
    for blocks: [OrgEditableBlock],
    source: OrgRenderedEntrySourceContext?,
    visibleRange: Range<Int>? = nil
  ) -> String {
    signature(blocksSignature: Self.blocksSignature(for: blocks), source: source, visibleRange: visibleRange)
  }

  static func signature(
    blocksSignature: String,
    source: OrgRenderedEntrySourceContext?,
    visibleRange: Range<Int>? = nil
  ) -> String {
    let rangeSignature: String = {
      guard let visibleRange else { return "all" }
      return "\(visibleRange.lowerBound)..<\(visibleRange.upperBound)"
    }()
    guard let source, source.isEditable else {
      return "read-only:\(source?.id ?? "none"):\(rangeSignature)"
    }
    return "editable:\(source.id):\(source.isSubtree):\(source.isEditable):\(rangeSignature):\(blocksSignature)"
  }

  private static func blocksSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.id)
      hasher.combine(block.startLine)
      hasher.combine(block.endLineExclusive)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  private static func clampedVisibleRange(_ visibleRange: Range<Int>?, totalCount: Int) -> Range<Int> {
    guard let visibleRange else {
      return 0..<totalCount
    }
    let start = min(max(0, visibleRange.lowerBound), totalCount)
    let end = min(max(start, visibleRange.upperBound), totalCount)
    return start..<end
  }

  private static func isMovable(_ block: OrgEditableBlock, in source: OrgRenderedEntrySourceContext) -> Bool {
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      return false
    }
    return !(source.isSubtree && block.startLine == source.startLine)
  }

  private static func movableBounds(
    in blocks: [OrgEditableBlock],
    source: OrgRenderedEntrySourceContext
  ) -> (first: Int, last: Int)? {
    guard let first = blocks.indices.first(where: { isMovable(blocks[$0], in: source) }) else {
      return nil
    }
    let last = blocks.indices.reversed().first(where: { isMovable(blocks[$0], in: source) }) ?? first
    return (first, last)
  }
}

private struct ProgressiveRenderFooter: View {
  let visibleRange: String
  let totalCount: Int
  let direction: OrgRenderedBlockWindowExpansionDirection
  let autoLoadsOnAppear: Bool
  let loadMore: (OrgRenderedBlockWindowExpansionDirection) -> Void
  @State private var lastAutoLoadToken: String?

  var body: some View {
    let autoLoadToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: visibleRange,
      totalCount: totalCount,
      direction: direction
    )
    Button {
      loadMore(direction)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: direction.systemImage)
        Text("Showing blocks \(visibleRange) of \(totalCount)")
          .font(.caption.weight(.medium))
        Text(direction.title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .onAppear {
      triggerAutoLoadIfNeeded(token: autoLoadToken)
    }
    .onChange(of: autoLoadToken) { _, newToken in
      triggerAutoLoadIfNeeded(token: newToken)
    }
  }

  private func triggerAutoLoadIfNeeded(token: String) {
    guard ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: autoLoadsOnAppear,
      lastTriggeredToken: lastAutoLoadToken,
      currentToken: token
    ) else {
      return
    }
    lastAutoLoadToken = token
    loadMore(direction)
  }
}

enum ProgressiveRenderFooterAutoLoad {
  static func token(
    visibleRange: String,
    totalCount: Int,
    direction: OrgRenderedBlockWindowExpansionDirection
  ) -> String {
    "\(direction):\(visibleRange):\(totalCount)"
  }

  static func shouldTrigger(
    autoLoadsOnAppear: Bool,
    lastTriggeredToken: String?,
    currentToken: String
  ) -> Bool {
    autoLoadsOnAppear && lastTriggeredToken != currentToken
  }
}

enum RenderedRowChrome {
  static let controlsReserveWidth: CGFloat = 92

  static func rendersControls(isVisible: Bool) -> Bool {
    true
  }

  static func rendersControlLayer(
    isSourceEditable: Bool,
    allowsHoverChrome: Bool,
    isSelected: Bool
  ) -> Bool {
    isSourceEditable && (allowsHoverChrome || isSelected)
  }

  static func contentTrailingPadding(
    isSourceEditable: Bool,
    allowsHoverChrome: Bool,
    isSelected: Bool
  ) -> CGFloat {
    guard isSourceEditable else { return 0 }
    return allowsHoverChrome || isSelected ? controlsReserveWidth : 0
  }

  static func controlsOpacity(isVisible: Bool) -> Double {
    isVisible ? 1 : 0
  }

  static func allowsHitTesting(isVisible: Bool) -> Bool {
    isVisible
  }
}

enum RenderedBlockEditingPolicy {
  static func startsEditingOnSingleClick(block _: OrgEditableBlock, isSourceEditable _: Bool) -> Bool {
    false
  }
}

enum LiveRenderedTextEditingPolicy {
  static func usesDirectEditor(block _: OrgEditableBlock, isSourceEditable _: Bool) -> Bool {
    false
  }
}

enum RenderedBlockInteractionPolicy {
  static func usesRowTapGestures(block: OrgEditableBlock, isSourceEditable: Bool) -> Bool {
    guard isSourceEditable else { return false }
    if OrgCrypt.armorSummary(block.rawText) != nil {
      return false
    }
    return true
  }

  static func showsRowChrome(for block: OrgEditableBlock) -> Bool {
    guard OrgCrypt.armorSummary(block.rawText) == nil else {
      return false
    }
    return OrgRenderedBlockDisplayPolicy.showsRowChrome(for: block)
  }
}

enum OrgRenderedBlockDisplayPolicy {
  static func isVisible(_ block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .blank:
      return false
    case .properties:
      return true
    case .heading, .planning, .quote, .source, .table, .horizontalRule, .listItem, .paragraph, .keyword:
      return true
    }
  }

  static func showsRowChrome(for block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .blank:
      return false
    case .heading, .planning, .properties, .quote, .source, .table, .horizontalRule, .listItem, .paragraph, .keyword:
      return true
    }
  }

  static func verticalPadding(for block: OrgEditableBlock) -> CGFloat {
    switch block.rendered {
    case .heading:
      return 1
    case .properties, .planning, .keyword:
      return 1
    case .blank:
      return 0
    case .paragraph, .quote, .source, .table, .horizontalRule, .listItem:
      return 3
    }
  }

  static func leadingPadding(for block: OrgEditableBlock) -> CGFloat {
    switch block.rendered {
    case .paragraph:
      return 0
    case .blank, .heading, .planning, .properties, .quote, .source, .table, .horizontalRule, .listItem, .keyword:
      return 6
    }
  }
}

private struct EditableRenderedBlockView<Content: View>: View {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.openWorkspaceWebLink) private var openWorkspaceWebLink
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  let block: OrgEditableBlock
  let isSourceEditable: Bool
  let isSelected: Bool
  let isFoldable: Bool
  let isFolded: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let allowsHoverChrome: Bool
  let actions: RenderedBlockActions
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    Group {
      if allowsHoverChrome {
        rowContent
          .onHover { hovering in
            isHovered = hovering
          }
      } else {
        rowContent
      }
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    let content = rowInnerContent
      .padding(.leading, OrgRenderedBlockDisplayPolicy.leadingPadding(for: block))
      .padding(.trailing, 6)
      .padding(.vertical, OrgRenderedBlockDisplayPolicy.verticalPadding(for: block))
      .background(backgroundColor, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .stroke(selectionStrokeColor)
      )

    if usesRowTapGestures {
      content
        .contentShape(Rectangle())
        .onTapGesture {
          actions.select()
          if RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: isSourceEditable) {
            actions.beginEditing()
          }
        }
        .contextMenu {
          contextMenuContent
        }
    } else {
      content
        .contextMenu {
          contextMenuContent
        }
    }
  }

  @ViewBuilder
  private var rowInnerContent: some View {
    if rendersControlLayer {
      ZStack(alignment: .topTrailing) {
        renderedContent

        if RenderedRowChrome.rendersControls(isVisible: showsControls) {
          rowControls
            .opacity(RenderedRowChrome.controlsOpacity(isVisible: showsControls))
            .allowsHitTesting(RenderedRowChrome.allowsHitTesting(isVisible: showsControls))
        }
      }
    } else {
      renderedContent
    }
  }

  private var renderedContent: some View {
    HStack(alignment: .top, spacing: 4) {
      if showsDisclosureSlot {
        Button {
          actions.toggleFold()
        } label: {
          Image(systemName: isFolded ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isFoldable ? 1 : 0)
        .help(isFolded ? "Expand" : "Collapse")
        .disabled(!isFoldable)
        .padding(.top, disclosureTopPadding)
      }

      content
        .padding(.trailing, contentTrailingPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
          if let activation = rowTextActivation {
            RenderedRowTextActivationOverlay(
              text: activation.text,
              font: activation.font,
              linkResolver: orgRoamLinkResolver,
              activateLink: openRenderedLink
            ) { selection in
              actions.select()
              actions.beginEditingAt(selection)
            }
            .padding(.leading, activation.leadingOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
          }
        }
        .environment(\.orgInlineTextSelectionEnabled, !usesRowTapGestures)
        .environment(\.orgInlineTextActivation, inlineTextActivation)
        .environment(\.orgInlineTextLinkActivation, linkActivation)
    }
  }

  private var disclosureTopPadding: CGFloat {
    switch block.rendered {
    case .heading:
      return 7
    case .listItem:
      return 4
    case .blank, .horizontalRule, .keyword, .paragraph, .planning, .properties, .quote, .source, .table:
      return 0
    }
  }

  private var backgroundColor: Color {
    guard isSourceEditable else { return .clear }
    guard !usesDirectRenderedTextEditor else { return .clear }
    if isSelected {
      return WorkspaceDesign.selectedFill
    }
    if showsChrome, allowsHoverChrome && isHovered {
      return WorkspaceDesign.panelFill
    }
    return .clear
  }

  private var selectionStrokeColor: Color {
    guard isSelected, !usesDirectRenderedTextEditor else { return .clear }
    return Color.accentColor.opacity(0.20)
  }

  private var showsControls: Bool {
    isSourceEditable && (isSelected || (allowsHoverChrome && isHovered))
  }

  private var rendersControlLayer: Bool {
    guard showsChrome else { return false }
    return RenderedRowChrome.rendersControlLayer(
      isSourceEditable: isSourceEditable,
      allowsHoverChrome: allowsHoverChrome,
      isSelected: isSelected
    )
  }

  private var contentTrailingPadding: CGFloat {
    guard showsChrome else { return 0 }
    return RenderedRowChrome.contentTrailingPadding(
      isSourceEditable: isSourceEditable,
      allowsHoverChrome: allowsHoverChrome,
      isSelected: isSelected
    )
  }

  private var showsChrome: Bool {
    RenderedBlockInteractionPolicy.showsRowChrome(for: block)
  }

  private var usesDirectRenderedTextEditor: Bool {
    LiveRenderedTextEditingPolicy.usesDirectEditor(block: block, isSourceEditable: isSourceEditable)
  }

  private var showsDisclosureSlot: Bool {
    switch block.rendered {
    case .heading, .listItem:
      return true
    case .blank, .horizontalRule, .keyword, .paragraph, .planning, .properties, .quote, .source, .table:
      return false
    }
  }

  private var rowControls: some View {
    HStack(spacing: 3) {
      Menu {
        ForEach(OrgInsertBlockKind.allCases) { kind in
          Button {
            actions.insert(kind)
          } label: {
            Label(kind.title, systemImage: kind.systemImage)
          }
        }
      } label: {
        Image(systemName: "plus")
          .font(.caption.weight(.semibold))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.small)
      .foregroundStyle(.secondary)
      .help("Add block after line \(block.displayRange)")

      if block.isEditable {
        Button {
          actions.beginEditing()
        } label: {
          Image(systemName: "pencil")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help("Edit line \(block.displayRange)")

        Menu {
          Button {
            actions.move(.up)
          } label: {
            Label("Move Up", systemImage: "arrow.up")
          }
          .disabled(!canMoveUp)

          Button {
            actions.move(.down)
          } label: {
            Label("Move Down", systemImage: "arrow.down")
          }
          .disabled(!canMoveDown)

          Divider()

          Button {
            actions.duplicate()
          } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
          }

          Button(role: .destructive) {
            actions.delete()
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("Block actions")
      }
    }
    .fixedSize()
    .frame(width: RenderedRowChrome.controlsReserveWidth, alignment: .trailing)
  }

  @ViewBuilder
  private var contextMenuContent: some View {
    Button {
      actions.askAI()
    } label: {
      Label("Ask AI", systemImage: "sparkles")
    }

    if isSourceEditable {
      Divider()

      if block.isEditable {
        Button {
          actions.beginEditing()
        } label: {
          Label("Edit", systemImage: "pencil")
        }
      }

      Menu {
        ForEach(OrgInsertBlockKind.allCases) { kind in
          Button {
            actions.insert(kind)
          } label: {
            Label(kind.title, systemImage: kind.systemImage)
          }
        }
      } label: {
        Label("Insert After", systemImage: "plus")
      }

      if block.isEditable {
        Divider()

        Button {
          actions.move(.up)
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!canMoveUp)

        Button {
          actions.move(.down)
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!canMoveDown)

        Button {
          actions.duplicate()
        } label: {
          Label("Duplicate", systemImage: "plus.square.on.square")
        }

        Button(role: .destructive) {
          actions.delete()
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }

  private var usesRowTapGestures: Bool {
    guard !usesDirectRenderedTextEditor else { return false }
    return RenderedBlockInteractionPolicy.usesRowTapGestures(block: block, isSourceEditable: isSourceEditable)
  }

  private var inlineTextActivation: OrgInlineTextActivation? {
    guard usesRowTapGestures,
          supportsInlineTextActivation,
          RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: isSourceEditable)
    else {
      return nil
    }
    return OrgInlineTextActivation { selection in
      actions.select()
      actions.beginEditingAt(selection)
    }
  }

  private var linkActivation: OrgInlineTextLinkActivation {
    OrgInlineTextLinkActivation { url in
      openRenderedLink(url)
    }
  }

  private func openRenderedLink(_ url: URL) {
    if let reference = AIChatFileReference.fromDeepLinkURL(url) {
      openOrgFileReference(reference)
      return
    }

    if url.isFileURL {
      openOrgFileReference(AIChatFileReference(path: url.path, line: nil))
      return
    }

    if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
      openWorkspaceWebLink(url)
    }
  }

  private var supportsInlineTextActivation: Bool {
    switch block.rendered {
    case .heading, .keyword, .listItem, .paragraph:
      return true
    case .blank, .horizontalRule, .planning, .properties, .quote, .source, .table:
      return false
    }
  }

  private var rowTextActivation: RenderedRowTextActivation? {
    guard usesRowTapGestures,
          RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: isSourceEditable),
          OrgCrypt.armorSummary(block.rawText) == nil
    else {
      return nil
    }

    switch block.rendered {
    case .paragraph:
      return RenderedRowTextActivation(text: block.rawText, font: .body, leadingOffset: 0)
    case .heading(let heading):
      return RenderedRowTextActivation(
        text: OrgRenderedLineDisplayCache.headingTitle(rawText: block.rawText, fallback: heading.title),
        font: Self.headingFont(for: heading.level),
        leadingOffset: Self.headingTitleLeadingOffset(heading)
      )
    case .blank, .horizontalRule, .keyword, .listItem, .planning, .properties, .quote, .source, .table:
      return nil
    }
  }

  private static func headingFont(for level: Int) -> Font {
    switch level {
    case 1:
      return .title3.weight(.semibold)
    case 2:
      return .headline.weight(.semibold)
    case 3:
      return .callout.weight(.semibold)
    default:
      return .body.weight(.semibold)
    }
  }

  private static func headingTitleLeadingOffset(_ heading: OrgHeadingBlock) -> CGFloat {
    var offset = CGFloat(max(0, heading.level - 1)) * 10
    if heading.todo != nil {
      offset += 48
    }
    if heading.priority != nil {
      offset += 62
    }
    return offset
  }
}

private struct RenderedRowTextActivation {
  let text: String
  let font: Font
  let leadingOffset: CGFloat
}

private struct RenderedRowTextActivationOverlay: NSViewRepresentable {
  let text: String
  let font: Font
  let linkResolver: OrgRoamLinkResolver
  let activateLink: @MainActor (URL) -> Void
  let activate: @MainActor (NSRange) -> Void

  func makeNSView(context: Context) -> HitView {
    let view = HitView()
    view.text = text
    view.font = font
    view.linkResolver = linkResolver
    view.activateLink = activateLink
    view.activate = activate
    return view
  }

  func updateNSView(_ view: HitView, context: Context) {
    view.text = text
    view.font = font
    view.linkResolver = linkResolver
    view.activateLink = activateLink
    view.activate = activate
  }

  final class HitView: NSView {
    var text = ""
    var font = Font.body
    var linkResolver = OrgRoamLinkResolver.empty
    var activateLink: (@MainActor (URL) -> Void)?
    var activate: (@MainActor (NSRange) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
      guard event.type == .leftMouseDown else {
        super.mouseDown(with: event)
        return
      }
      let point = convert(event.locationInWindow, from: nil)
      if let activateLink,
         let url = OrgInlineTextLinkHitTester.linkURL(
          raw: text,
          linkResolver: linkResolver,
          font: font,
          lineSpacing: 2,
          bounds: bounds,
          point: point
         ) {
        activateLink(url)
        return
      }
      let range = OrgInlineTextSelectionMapper.selectionRange(
        in: text,
        font: font,
        lineSpacing: 2,
        bounds: bounds,
        point: point
      )
      activate?(range)
    }
  }
}

private struct RenderedPageBlankWritingArea: View {
  let beginAppendingSection: () -> Void
  @State private var isHovered = false

  var body: some View {
    Rectangle()
      .fill(Color.clear)
      .frame(maxWidth: .infinity, minHeight: 420)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .fill(isHovered ? WorkspaceDesign.subtleFill.opacity(0.45) : Color.clear)
      )
      .onHover { hovering in
        isHovered = hovering
      }
      .onTapGesture {
        beginAppendingSection()
      }
  }
}

private struct RenderedBlockActions {
  let select: () -> Void
  let beginEditing: () -> Void
  let beginEditingAt: (NSRange) -> Void
  let initialSelection: () -> NSRange?
  let insert: (OrgInsertBlockKind) -> Void
  let move: (OrgBlockMoveDirection) -> Void
  let askAI: () -> Void
  let duplicate: () -> Void
  let delete: () -> Void
  let toggleFold: () -> Void
}
