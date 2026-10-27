import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  public func deleteBackwardFromStartOfEditingBlock(_ block: OrgEditableBlock, draftText: String? = nil) async {
    let draft = Self.normalizeLineEndings(draftText ?? editingDraftText(for: block))
    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if transientDraftBlock?.block.id == block.id {
        let fallbackSelection = previousMergeTarget(before: block)
        discardTransientDraft(status: "Draft discarded")
        selectedBlockID = fallbackSelection?.id
        return
      }
      await deleteBlock(block)
      return
    }

    await mergeEditingBlockBackward(block, draftText: draft)
  }

  private func mergeEditingBlockBackward(_ block: OrgEditableBlock, draftText: String) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
            || transientDraftBlock?.block.id == block.id
    else {
      statusText = "Block cannot be merged"
      return
    }
    guard let previous = previousMergeTarget(before: block) else {
      statusText = "No previous text block"
      return
    }
    guard let replacement = Self.mergedTextBlockRawText(
      previous: previous,
      current: block,
      currentDraft: draftText
    ) else {
      statusText = "Blocks cannot be merged"
      return
    }

    let isTransientMerge = transientDraftBlock?.block.id == block.id
    let replacementStartLine = previous.startLine
    let replacementEndLineExclusive = isTransientMerge ? previous.endLineExclusive : block.endLineExclusive

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      let preparation = try await Task.detached(priority: .userInitiated) {
        (
          expectedOriginal: try Self.sourceText(
            in: source,
            startLine: replacementStartLine,
            endLineExclusive: replacementEndLineExclusive
          ),
          updatedSource: try Self.replacingSourceRange(
            in: source,
            startLine: replacementStartLine,
            endLineExclusive: replacementEndLineExclusive,
            replacement: replacement
          )
        )
      }.value
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: replacementStartLine,
        endLineExclusive: replacementEndLineExclusive,
        replacement: replacement,
        expectedOriginal: preparation.expectedOriginal
      )

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        OrgEntryRenderer.parseEditable(
          preparation.updatedSource.text,
          baseLine: preparation.updatedSource.startLine
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
      selectedEntrySource = preparation.updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: preparation.updatedSource)
      setSelectedRenderedBlocks(updatedVisibleBlocks, preservingMetadata: false)
      if let mergedBlock = blockForSelectionLine(
        previous.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      ) {
        selectedBlockID = mergedBlock.id
        editingBlockID = mergedBlock.id
        editableBlockText = mergedBlock.rawText
        activeBlockDrafts[mergedBlock.id] = mergedBlock.rawText
        activeBlockOriginals[mergedBlock.id] = mergedBlock
      }
      statusText = "Merged block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Merge failed"
    }
  }

  public func convertEditingBlock(_ block: OrgEditableBlock, to kind: OrgInsertBlockKind, draftText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }

    let draftText = draftText ?? editingDraftText(for: block)
    let draft = conversionDraftBlock(for: kind, replacing: block, in: source, draft: draftText)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Converted block to \(kind.title.lowercased()) draft"
  }

  public func insertBlock(after block: OrgEditableBlock, kind: OrgInsertBlockKind, initialText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }

    let draft = insertionDraftBlock(for: kind, after: block, in: source, initialText: initialText)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Started \(kind.title.lowercased()) draft in \(relativePath(source.file))"
  }

  public func toggleListItemCheckbox(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .listItem(_, _, let checkbox, _) = block.rendered,
          let checkbox,
          let replacement = Self.toggledListItemCheckboxRawText(block.rawText, current: checkbox)
    else {
      statusText = "List item has no checkbox"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: checkbox == .checked ? "Marked incomplete" : "Marked complete",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Checkbox update failed"
    }
  }

  @discardableResult
  public func setRenderedDocumentCheckbox(at line: Int, checked: Bool) async -> Bool {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return false
    }
    guard line >= source.startLine,
          line < source.endLineExclusive,
          let block = selectedRenderedBlocks.first(where: { candidate in
            guard candidate.startLine == line else { return false }
            if case .listItem(_, _, let checkbox, _) = candidate.rendered {
              return checkbox != nil
            }
            return false
          }),
          case .listItem(_, _, let current, _) = block.rendered,
          let current
    else {
      errorText = "The rendered checkbox no longer matches its source. The document was reloaded."
      statusText = "Checkbox update conflicted"
      if let selectedLocation { scheduleEntrySourceLoad(for: selectedLocation) }
      return false
    }

    let target: OrgListCheckbox = checked ? .checked : .unchecked
    guard current != target else {
      statusText = checked ? "Already complete" : "Already incomplete"
      if let selectedLocation { scheduleEntrySourceLoad(for: selectedLocation) }
      return false
    }
    guard let replacement = Self.listItemCheckboxRawText(block.rawText, state: target) else {
      errorText = "The rendered checkbox no longer matches its source. The document was reloaded."
      statusText = "Checkbox update conflicted"
      if let selectedLocation { scheduleEntrySourceLoad(for: selectedLocation) }
      return false
    }
    guard let context = captureDocumentCorpusContext(forFile: source.file) else {
      errorText = WorkspaceDocumentMutationError.outsideCorpus(
        file: source.file,
        root: corpusRoot?.path ?? "(none)"
      ).localizedDescription
      statusText = "Checkbox update failed"
      return false
    }
    let sourceMode = selectedEntrySourceMode

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let mutation: RenderedCheckboxMutation = try await performDocumentMutation(
        context: context,
        files: [source.file]
      ) { execution in
        let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: source.file))
        let output = try Self.textByReplacingSourceRange(
          in: snapshot.text,
          file: source.file,
          startLine: block.startLine,
          endLineExclusive: block.endLineExclusive,
          replacement: replacement,
          expectedOriginal: block.rawText
        )
        try await execution.commit(output, over: snapshot) { text, url, previous in
          try Self.commitDocumentText(
            text,
            url: url,
            previousText: previous,
            operation: "rendered checkbox update"
          )
        }
        let updatedSourceText = try Self.sourceRangeText(
          in: output,
          file: source.file,
          startLine: source.startLine,
          endLineExclusive: source.endLineExclusive
        )
        let updatedSource = EntrySource(
          file: source.file,
          startLine: source.startLine,
          endLineExclusive: source.endLineExclusive,
          text: updatedSourceText,
          isSubtree: source.isSubtree,
          isEditable: source.isEditable
        )
        let updatedBlocks = OrgEntryRenderer.parseEditable(
          updatedSource.text,
          baseLine: updatedSource.startLine
        )
        let previousForUndo = snapshot.text.utf8.count <= Self.workspaceUndoSnapshotMaxBytes
          && output.utf8.count <= Self.workspaceUndoSnapshotMaxBytes
          ? snapshot.text
          : nil
        return RenderedCheckboxMutation(
          previousForUndo: previousForUndo,
          next: output,
          source: updatedSource,
          blocks: updatedBlocks,
          blockMetadata: Self.renderedBlocksMetadata(for: updatedBlocks),
          fileContentDigest: Self.contentDigest(for: Data(output.utf8)),
          fileFreshnessSignature: Self.fileFreshnessSignature(for: snapshot.url),
          firstOrgID: Self.firstOrgID(in: updatedSource.text),
          sourceLineIndex: OrgSourceLineIndex(text: updatedSource.text as NSString)
        )
      }
      if let previous = mutation.previousForUndo {
        recordFileUndo(file: source.file, previous: previous, next: mutation.next)
      }
      invalidateCanonicalDocumentCache(for: source.file)
      if selectedEntrySource?.id == source.id {
        nextSelectedEntrySourceRenderIdentity = "file:\(mutation.fileContentDigest)|\(source.startLine)|\(source.endLineExclusive)"
        nextSelectedEntrySourceLineIndex = mutation.sourceLineIndex
        nextSelectedEntrySourceModifiedAt = mutation.fileFreshnessSignature?.contentModificationDate
        let previousSource = selectedEntrySource
        selectedEntrySource = mutation.source
        updateEditableEntryTextFromLoadedSourceIfSafe(mutation.source, previousSource: previousSource)
        cacheRenderedBlocks(
          mutation.blocks,
          metadata: mutation.blockMetadata,
          for: mutation.source,
          modifiedAt: mutation.fileFreshnessSignature?.contentModificationDate
        )
        applyRenderedBlocks(
          mutation.blocks,
          metadata: mutation.blockMetadata,
          for: mutation.source
        )
        if let selectedLocation,
           selectedEntrySourceMode == sourceMode {
          cacheEntrySource(
            mutation.source,
            for: selectedLocation,
            mode: sourceMode,
            modifiedAt: mutation.fileFreshnessSignature?.contentModificationDate,
            fileContentDigest: mutation.fileContentDigest,
            fileFreshnessSignature: mutation.fileFreshnessSignature,
            firstOrgID: mutation.firstOrgID,
            sourceLineIndex: mutation.sourceLineIndex
          )
        }
      }
      statusText = checked ? "Marked complete" : "Marked incomplete"
      scheduleAgendaRefresh(preserveSelection: true)
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Checkbox update failed"
      if selectedEntrySource?.id == source.id,
         let selectedLocation {
        scheduleEntrySourceLoad(for: selectedLocation)
      }
      return false
    }
  }

  public func toggleHeadingTodo(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading(let heading) = block.rendered, let currentStatus = heading.todo else {
      errorText = "This heading has no TODO state. Edit the heading to add one."
      return
    }
    guard let nextStatus = Self.nextHeadingTodoStatus(after: currentStatus, sequences: heading.todoSequences) else {
      errorText = "No next TODO state is configured for \(currentStatus). Check this file’s #+TODO: declaration."
      return
    }
    isSavingBlock = true
    defer { isSavingBlock = false }
    let target = HeadlineMutationTarget(file: source.file, line: block.startLine, title: heading.title)
    do {
      let context = try documentMutationContext(for: target)
      let cli = self.cli
      try await performDocumentMutation(context: context, files: [source.file]) { execution in
        let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
        let resolved = try await Self.canonicalTodoMutationTarget(target, text: snapshot.text, cli: cli)
        let replacement = try await Self.previewCLIDocumentMutation(
          cli: cli,
          arguments: ["todo", "set", "--file", snapshot.url.path, "--line", "\(resolved.line)", "--keyword", nextStatus],
          basedOn: snapshot
        )
        try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
          try Self.commitDocumentText(replacement, url: url, previousText: previous, operation: "TODO status update")
        }
      }
      statusText = "\(nextStatus) -> \(heading.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  public nonisolated static func nextHeadingTodoStatus(after current: String, sequences: [Org2TodoSequence] = []) -> String? {
    if let sequence = sequences.first(where: { $0.keywords.contains(current) }) {
      return sequence.terminal.contains(current)
        ? sequence.keywords.first(where: { !sequence.terminal.contains($0) }) ?? "TODO"
        : sequence.terminal.first ?? "DONE"
    }
    let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty else { return nil }
    if doneHeadingTodoKeywords.contains(normalized) {
      return "TODO"
    }
    if activeHeadingTodoKeywords.contains(normalized) {
      return "DONE"
    }
    return nil
  }

  public func setHeadingPriority(_ block: OrgEditableBlock, priority: String?) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading = block.rendered,
          let replacement = Self.headingRawTextSettingPriority(block.rawText, priority: priority)
    else {
      statusText = "Heading priority update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: priority.map { "[#\($0)] -> heading" } ?? "Priority cleared",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Priority update failed"
    }
  }

  public func setHeadingTags(_ block: OrgEditableBlock, tags: [String]) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .heading = block.rendered,
          let replacement = Self.headingRawTextSettingTags(block.rawText, tags: tags)
    else {
      statusText = "Heading tag update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: tags.isEmpty ? "Tags cleared" : "Tags -> \(tags.joined(separator: ", "))",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Tag update failed"
    }
  }

  public func setPlanningBlock(_ block: OrgEditableBlock, kind: String, value: String) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    guard case .planning = block.rendered,
          let replacement = Self.planningRawText(kind: kind, value: value)
    else {
      statusText = "Planning update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: "\(replacement) -> planning",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Planning update failed"
    }
  }

  public func setPropertyValue(_ block: OrgEditableBlock, key: String, value: String) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block is outside the selected source"
      return
    }
    let normalizedKey = Self.normalizedPropertyKey(key)
    guard normalizedKey != "ID" else {
      statusText = "ID property is read-only"
      return
    }
    guard case .properties = block.rendered,
          let replacement = Self.propertyDrawerRawTextSettingValue(
            block.rawText,
            key: normalizedKey,
            value: value
          )
    else {
      statusText = "Property update failed"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      try await replaceBlockSourceAndFinish(
        source: source,
        block: block,
        replacement: replacement,
        status: "\(normalizedKey) -> property",
        selectLine: block.startLine
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
  }

  public func duplicateBlock(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block cannot be duplicated"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      let replacement = "\n" + block.rawText
      let updatedSource = try await Task.detached(priority: .userInitiated) {
        try Self.replacingSourceRange(
          in: source,
          startLine: block.endLineExclusive,
          endLineExclusive: block.endLineExclusive,
          replacement: replacement
        )
      }.value
      let currentRenderedBlocks = selectedRenderedBlocks
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: block.endLineExclusive,
        endLineExclusive: block.endLineExclusive,
        replacement: replacement
      )

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyInsertingRenderedBlocks(
          currentRenderedBlocks,
          atLine: block.endLineExclusive,
          replacement: replacement
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
      selectedBlockID = blockForSelectionLine(
        block.endLineExclusive + 1,
        mode: .nextOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Duplicated block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Duplicate failed"
    }
  }

  @discardableResult
  public func deleteBlock(_ block: OrgEditableBlock) async -> Bool {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return false
    }
    guard block.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      statusText = "Block cannot be deleted"
      return false
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      let deletionRange = try await Task.detached(priority: .userInitiated) {
        try Self.deletionRange(for: block, in: source)
      }.value
      if source.isSubtree, block.startLine == source.startLine {
        try await deleteDocumentSourceRangeCleaningAdjacentBlank(
          file: source.file,
          startLine: deletionRange.startLine,
          endLineExclusive: deletionRange.endLineExclusive,
          allowDestructiveReplacement: true
        )
        await recordFileUndo(from: undoSnapshot)
        invalidateCanonicalDocumentCache(for: source.file)
        transientDraftBlock = nil
        resetBlockEditing()
        isEditingEntry = false
        selectedEntrySourceMode = .page
        if selectedLocation != nil {
          await reloadSelectedEntrySource()
        } else {
          selectedEntrySource = nil
          selectedRenderedBlocks = []
          selectedEntryHTML = nil
        }
        statusText = "Deleted entry in \(relativePath(source.file))"
        scheduleAgendaRefresh(preserveSelection: true)
        return true
      }

      let deletion = try await Task.detached(priority: .userInitiated) {
        try Self.deletingSourceRangeCleaningAdjacentBlank(
          in: source,
          startLine: deletionRange.startLine,
          endLineExclusive: deletionRange.endLineExclusive
        )
      }.value
      let currentRenderedBlocks = selectedRenderedBlocks
      let allowDestructiveDelete = deletion.source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      try await deleteDocumentSourceRangeCleaningAdjacentBlank(
        file: source.file,
        startLine: deletionRange.startLine,
        endLineExclusive: deletionRange.endLineExclusive,
        allowDestructiveReplacement: allowDestructiveDelete
      )

      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyDeletingRenderedBlocks(
          currentRenderedBlocks,
          startLine: deletion.startLine,
          endLineExclusive: deletion.endLineExclusive
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        await recordFileUndo(from: undoSnapshot)
        return true
      }

      await recordFileUndo(from: undoSnapshot)
      invalidateCanonicalDocumentCache(for: source.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = deletion.source
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: deletion.source)
      selectedRenderedBlocks = updatedVisibleBlocks
      let selectionLine: Int
      if case .heading = block.rendered {
        selectionLine = deletion.startLine
      } else {
        selectionLine = block.startLine
      }
      selectedBlockID = blockForSelectionLine(
        selectionLine,
        mode: .nextOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Deleted block in \(relativePath(source.file))"
      scheduleAgendaRefresh(preserveSelection: true)
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Delete failed"
      return false
    }
  }

  func deleteRenderedTextSelection(_ fragments: [OrgSyntaxTextSelectionDocumentFragment]) async {
    await replaceRenderedTextSelection(fragments, replacementText: "")
  }

  @discardableResult
  func beginRenderedTextSelectionReplacement(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) -> Bool {
    guard let preparation = prepareRenderedTextSelectionReplacement(
      fragments,
      replacementText: replacementText
    ) else {
      return false
    }
    Task { @MainActor [weak self] in
      await self?.finishRenderedTextSelectionWrite(preparation)
    }
    return true
  }

  func replaceRenderedTextSelection(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) async {
    guard let preparation = prepareRenderedTextSelectionReplacement(
      fragments,
      replacementText: replacementText
    ) else {
      return
    }
    await finishRenderedTextSelectionWrite(preparation)
  }

  private func prepareRenderedTextSelectionReplacement(
    _ fragments: [OrgSyntaxTextSelectionDocumentFragment],
    replacementText: String
  ) -> RenderedTextSelectionPreparation? {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return nil
    }
    guard !fragments.isEmpty else {
      statusText = "No editable selection"
      return nil
    }

    isSavingBlock = true
    return RenderedTextSelectionPreparation(
      fragments: fragments.map(RenderedTextSelectionFragment.init),
      replacementText: replacementText,
      source: source,
      blocks: selectedRenderedBlocks,
      sourceRevision: entrySourceRenderIdentities[source.id]
    )
  }

  private func finishRenderedTextSelectionWrite(
    _ preparation: RenderedTextSelectionPreparation
  ) async {
    defer { isSavingBlock = false }
    let plan = await Task.detached(priority: .userInitiated) {
      let pairs = Self.renderedTextSelectionPairs(
        preparation.fragments,
        in: preparation.blocks
      )
      guard !pairs.isEmpty else {
        return RenderedTextSelectionPlanResult.failure("No editable selection")
      }
      do {
        let replacement = try Self.renderedTextSelectionReplacement(
          pairs: pairs,
          allBlocks: preparation.blocks,
          in: preparation.source,
          replacementText: preparation.replacementText
        )
        let renderedBlocks = replacement.updatedSource.text.isEmpty
          ? []
          : Self.sortEditableBlocksForDisplay(OrgEntryRenderer.parseEditable(
              replacement.updatedSource.text,
              baseLine: replacement.updatedSource.startLine
            ))
        return .success(RenderedTextSelectionWrite(
          file: preparation.source.file,
          startLine: replacement.startLine,
          endLineExclusive: replacement.endLineExclusive,
          replacement: replacement.replacement,
          expectedOriginal: replacement.expectedOriginal,
          allowDestructiveReplacement: replacement.coversWholeDocument
            && replacement.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          failureStatus: preparation.replacementText.isEmpty
            ? "Delete selection failed"
            : "Replace selection failed",
          updatedSource: replacement.updatedSource,
          renderedBlocks: renderedBlocks,
          renderedBlocksMetadata: Self.renderedBlocksMetadata(for: renderedBlocks),
          caretSourceUTF16Offset: replacement.caretSourceUTF16Offset,
          undoSnapshot: Self.fileUndoSnapshotOffMain(for: preparation.source.file)
        ))
      } catch {
        return .failure(error.localizedDescription)
      }
    }.value

    guard case .success(let write) = plan else {
      if case .failure(let message) = plan {
        errorText = message == "No editable selection" ? nil : message
        statusText = message == "No editable selection"
          ? message
          : (preparation.replacementText.isEmpty
              ? "Delete selection failed"
              : "Replace selection failed")
      }
      return
    }
    guard selectedEntrySource?.id == preparation.source.id,
          entrySourceRenderIdentities[preparation.source.id] == preparation.sourceRevision
    else {
      statusText = "The selected file changed before the selection could be saved"
      return
    }

    do {
      try await replaceDocumentSourceRange(
        file: write.file,
        startLine: write.startLine,
        endLineExclusive: write.endLineExclusive,
        replacement: write.replacement,
        expectedOriginal: write.expectedOriginal,
        allowDestructiveReplacement: write.allowDestructiveReplacement
      )
      await recordFileUndo(from: write.undoSnapshot)
      guard selectedEntrySource?.id == preparation.source.id else { return }
      invalidateCanonicalDocumentCache(for: write.file)
      transientDraftBlock = nil
      resetBlockEditing()
      isEditingEntry = false
      selectedEntrySource = write.updatedSource
      pendingBlockSelection = PendingBlockSelection(
        file: write.file,
        line: write.startLine,
        mode: .nextOrNearest,
        beginEditing: !preparation.replacementText.isEmpty,
        initialSourceUTF16Offset: write.caretSourceUTF16Offset
      )
      selectedBlockID = nil
      if write.updatedSource.text.isEmpty {
        selectedRenderedBlocks = []
        pendingBlockSelection = nil
      } else {
        applyRenderedBlocks(
          write.renderedBlocks,
          metadata: write.renderedBlocksMetadata,
          for: write.updatedSource
        )
      }
      isRenderingEntrySource = false
      statusText = preparation.replacementText.isEmpty
        ? "Deleted selection in \(relativePath(write.file))"
        : "Replaced selection in \(relativePath(write.file))"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = write.failureStatus
    }
  }

  public func canMoveBlock(_ block: OrgEditableBlock, direction: OrgBlockMoveDirection) -> Bool {
    guard block.isEditable,
          let source = selectedEntrySource,
          source.isEditable,
          block.startLine >= source.startLine,
          block.endLineExclusive <= source.endLineExclusive
    else {
      return false
    }
    if source.isSubtree, block.startLine == source.startLine {
      return false
    }

    let blocks = movableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
    switch direction {
    case .up:
      return index > 0
    case .down:
      return index < blocks.count - 1
    }
  }

  public func moveBlock(_ block: OrgEditableBlock, direction: OrgBlockMoveDirection) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard canMoveBlock(block, direction: direction),
          let target = moveTarget(for: block, direction: direction)
    else {
      statusText = "Block cannot move \(direction == .up ? "up" : "down")"
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      let sourceSwap = try await Task.detached(priority: .userInitiated) {
        switch direction {
        case .up:
          return try Self.swappingSourceRanges(
            in: source,
            firstStartLine: target.startLine,
            firstEndLineExclusive: target.endLineExclusive,
            secondStartLine: block.startLine,
            secondEndLineExclusive: block.endLineExclusive
          )
        case .down:
          return try Self.swappingSourceRanges(
            in: source,
            firstStartLine: block.startLine,
            firstEndLineExclusive: block.endLineExclusive,
            secondStartLine: target.startLine,
            secondEndLineExclusive: target.endLineExclusive
          )
        }
      }.value
      switch direction {
      case .up:
        try await swapDocumentSourceRanges(
          file: source.file,
          firstStartLine: target.startLine,
          firstEndLineExclusive: target.endLineExclusive,
          secondStartLine: block.startLine,
          secondEndLineExclusive: block.endLineExclusive
        )
      case .down:
        try await swapDocumentSourceRanges(
          file: source.file,
          firstStartLine: block.startLine,
          firstEndLineExclusive: block.endLineExclusive,
          secondStartLine: target.startLine,
          secondEndLineExclusive: target.endLineExclusive
        )
      }
      let selectedLine: Int
      switch direction {
      case .up:
        selectedLine = target.startLine
      case .down:
        selectedLine = block.startLine + (target.endLineExclusive - target.startLine) + max(0, target.startLine - block.endLineExclusive)
      }
      let currentRenderedBlocks = selectedRenderedBlocks
      let updatedBlocks = await Task.detached(priority: .userInitiated) {
        Self.locallyMovingRenderedBlocks(
          currentRenderedBlocks,
          firstStartLine: direction == .up ? target.startLine : block.startLine,
          firstEndLineExclusive: direction == .up ? target.endLineExclusive : block.endLineExclusive,
          secondStartLine: direction == .up ? block.startLine : target.startLine,
          secondEndLineExclusive: direction == .up ? block.endLineExclusive : target.endLineExclusive
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
      selectedEntrySource = sourceSwap
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: sourceSwap)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        selectedLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Moved block \(direction == .up ? "up" : "down")"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Move failed"
    }
  }

  public func sourceBlockRunState(for block: OrgEditableBlock) -> SourceBlockRunState? {
    sourceBlockRuns[sourceBlockRunKey(for: block)]
  }

  public func runSourceBlock(_ block: OrgEditableBlock, rawText: String? = nil) async {
    guard let selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    guard case .source(let fallbackLanguage, let fallbackLines) = block.rendered else {
      statusText = "Select a source block first"
      return
    }

    let source = OrgEditableSourceBlock(
      rawText: rawText ?? block.rawText,
      fallbackLanguage: fallbackLanguage,
      fallbackLines: fallbackLines
    )
    let language = source.language.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = sourceBlockRunKey(for: block)
    guard let plan = SourceBlockRunPlan.plan(for: language) else {
      sourceBlockRuns[key] = SourceBlockRunState(
        status: .unsupported,
        language: language.isEmpty ? "source" : language,
        commandLabel: "",
        message: language.isEmpty
          ? "Add a supported source language to run this block."
          : "Running \(language) blocks is not supported yet."
      )
      return
    }

    let startedAt = Date()
    sourceBlockRuns[key] = SourceBlockRunState(
      status: .running,
      language: language,
      commandLabel: plan.commandLabel,
      startedAt: startedAt,
      message: "Running..."
    )

    let workingDirectory = URL(fileURLWithPath: selectedEntrySource.file)
      .deletingLastPathComponent()
      .standardizedFileURL

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try Self.executeSourceBlock(source, plan: plan, workingDirectory: workingDirectory)
      }.value
      guard self.sourceBlockRunKey(for: block) == key else { return }
      let finishedAt = Date()
      let status: SourceBlockRunStatus
      if result.timedOut {
        status = .timedOut
      } else if result.exitCode == 0 {
        status = .succeeded
      } else {
        status = .failed
      }
      sourceBlockRuns[key] = SourceBlockRunState(
        status: status,
        language: language,
        commandLabel: plan.commandLabel,
        startedAt: startedAt,
        finishedAt: finishedAt,
        duration: finishedAt.timeIntervalSince(startedAt),
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        message: result.timedOut ? "Timed out after \(Int(result.timeout))s" : nil
      )
    } catch {
      sourceBlockRuns[key] = SourceBlockRunState(
        status: .failed,
        language: language,
        commandLabel: plan.commandLabel,
        startedAt: startedAt,
        finishedAt: Date(),
        stderr: error.localizedDescription,
        message: "Run failed"
      )
    }
  }

  public func refreshAIChatThreadRecords(showsLoading: Bool = true) async {
    guard !isRefreshingAIChatThreadRecords else { return }

    guard let corpusRoot else {
      aiChatThreadRecords = []
      return
    }

    let sessionGeneration = corpusSessionGeneration
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.aiChat, default: 0]
    isRefreshingAIChatThreadRecords = true
    let shouldShowLoading = showsLoading || aiChatThreadRecords.isEmpty
    if shouldShowLoading {
      isLoadingAIChatThreadRecords = true
    }
    defer {
      if isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) {
        isRefreshingAIChatThreadRecords = false
        if shouldShowLoading { isLoadingAIChatThreadRecords = false }
      }
    }

    do {
      let threads = try await Task.detached(priority: .utility) {
        try Self.scanAIChatThreadRecords(corpusRoot: corpusRoot)
      }.value
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      aiChatThreadRecords = threads
      syncAIChatSelectionAfterRefresh()
      markWorkspaceSurfaceCleanIfUnchanged(.aiChat, generation: dirtyGeneration)
    } catch {
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      errorText = error.localizedDescription
      statusText = "Agent records scan failed"
    }
  }

  public func refreshAssignedWork(showsLoading: Bool = true) async {
    guard !isRefreshingAssignedWork else { return }

    guard let corpusRoot,
          let corpusContext = captureDocumentCorpusContext()
    else {
      assignedWorkItems = []
      return
    }

    assignedWorkRefreshRequestGeneration &+= 1
    let requestGeneration = assignedWorkRefreshRequestGeneration
    let requestID = UUID()
    activeAssignedWorkRefreshRequestID = requestID
    hasAttemptedAssignedWorkLoad = true
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.agenda, default: 0]
    isRefreshingAssignedWork = true
    let shouldShowLoading = showsLoading || assignedWorkItems.isEmpty
    if shouldShowLoading {
      isLoadingAssignedWork = true
    }
    defer {
      if activeAssignedWorkRefreshRequestID == requestID {
        activeAssignedWorkRefreshRequestID = nil
        isRefreshingAssignedWork = false
        if shouldShowLoading {
          isLoadingAssignedWork = false
        }
      }
    }

    for attempt in 0..<2 {
      let filesGeneration = corpusFilesGeneration
      let eventSerial = corpusFileEventSerial
      let files = corpusFiles
      let request = AssignedWorkRefreshContext(
        requestID: requestID,
        requestGeneration: requestGeneration,
        corpus: corpusContext,
        corpusFilesGeneration: filesGeneration,
        corpusFileEventSerial: eventSerial,
        dirtyGeneration: dirtyGeneration
      )
      let laneSnapshot = await documentMutationLane.rootMutationSnapshot(
        rootPath: corpusContext.mutationRootPath
      )

      do {
        let preparation = assignedWorkScanPreparationForTesting
        let cache = workspaceTodoScanCache
        let items = try await Task.detached(priority: .utility) {
          await preparation?()
          let scanFiles = files.isEmpty
            ? try Self.scanCorpusFiles(corpusRoot: corpusRoot)
            : files
          let headings = try await cache.scan(files: scanFiles)
          return Self.assignedWorkItems(headings: headings)
        }.value
        guard isCurrentAssignedWorkRefresh(request) else { return }
        let laneIsCurrent = await documentMutationLane.isCurrentAndQuiescent(laneSnapshot)
        guard corpusFilesGeneration == request.corpusFilesGeneration,
              corpusFileEventSerial == request.corpusFileEventSerial,
              laneIsCurrent
        else {
          if attempt == 0 {
            await Task.yield()
            continue
          }
          markWorkspaceSurfacesDirty([.agenda], refreshVisible: false)
          return
        }

        assignedWorkItems = items
        if let selectedAssignedWorkItemID,
           let item = items.first(where: { $0.id == selectedAssignedWorkItemID }) {
          if case .assigned = selectedLocation {
            selectedLocation = .assigned(item)
          }
        } else if selectedAssignedWorkItemID != nil {
          self.selectedAssignedWorkItemID = nil
          if case .assigned = selectedLocation {
            selectedLocation = nil
            backlinks = nil
          }
        }
        if selectedSurface == .agenda, agendaMode == .assigned {
          statusText = "\(items.count) all-time item\(items.count == 1 ? "" : "s")"
        }
        markWorkspaceSurfaceCleanIfUnchanged(.agenda, generation: request.dirtyGeneration)
        return
      } catch {
        guard isCurrentAssignedWorkRefresh(request) else { return }
        errorText = error.localizedDescription
        statusText = "Assigned work scan failed"
        return
      }
    }
  }

  public func refreshAssignedWorkIfNeeded() async {
    guard !hasAttemptedAssignedWorkLoad else { return }
    await refreshAssignedWork(showsLoading: false)
  }

  func rebuildAssignedWorkDisplayCache() {
    let terms = Self.filterTerms(from: agendaFilter)
    visibleAssignedWorkItems = assignedWorkSearchRows.compactMap { row in
      guard Self.matchesAssignedWorkStructuredFilters(
        row.item,
        assignee: agendaAssigneeFilter,
        status: agendaStatusFilter,
        priority: agendaPriorityFilter,
        topic: agendaTopicFilter
      ) else { return nil }
      guard !terms.isEmpty else { return row.item }
      return terms.allSatisfy { row.searchText.contains($0) } ? row.item : nil
    }
    assignedWorkSections = Self.groupAssignedWorkSections(visibleAssignedWorkItems)
  }

  nonisolated private static func matchesAssignedWorkStructuredFilters(
    _ item: AssignedWorkItem,
    assignee: String,
    status: String,
    priority: String,
    topic: String
  ) -> Bool {
    let normalizedAssignee = item.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
    if assignee == agendaUnassignedFilter {
      guard normalizedAssignee.isEmpty else { return false }
    } else if !assignee.isEmpty,
              normalizedAssignee.caseInsensitiveCompare(assignee) != .orderedSame {
      return false
    }

    let todo = item.todo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let propertyStatus = propertyValue("STATUS", in: item.properties) ?? item.status
    if status == agendaOpenStatusFilter {
      let normalizedTodo = todo.uppercased()
      guard !["DONE", "CANCELED", "CANCELLED"].contains(normalizedTodo) else { return false }
    } else if status == agendaCompletedStatusFilter {
      let normalizedTodo = todo.uppercased()
      guard ["DONE", "CANCELED", "CANCELLED"].contains(normalizedTodo) else { return false }
    } else if !status.isEmpty,
              todo.caseInsensitiveCompare(status) != .orderedSame,
              propertyStatus.caseInsensitiveCompare(status) != .orderedSame {
      return false
    }

    let itemPriority = propertyValue("PRIORITY", in: item.properties) ?? ""
    if priority == agendaNoPriorityFilter {
      guard itemPriority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    } else if !priority.isEmpty,
              itemPriority.caseInsensitiveCompare(priority) != .orderedSame {
      return false
    }

    if !topic.isEmpty,
       !item.tags.contains(where: { $0.caseInsensitiveCompare(topic) == .orderedSame }) {
      return false
    }
    return true
  }

  private static func groupAssignedWorkSections(_ items: [AssignedWorkItem]) -> [AssignedWorkSection] {
    let grouped = Dictionary(grouping: items) { item in
      "\(item.assignee)|\(Self.assignedWorkTodoGroupLabel(for: item))"
    }
    return grouped.keys.sorted { lhs, rhs in
      let left = lhs.split(separator: "|", maxSplits: 1).map(String.init)
      let right = rhs.split(separator: "|", maxSplits: 1).map(String.init)
      if left.first == right.first {
        return (left.dropFirst().first ?? "") < (right.dropFirst().first ?? "")
      }
      return (left.first ?? "") < (right.first ?? "")
    }.map { key in
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      let assignee = parts.first ?? "unassigned"
      let todo = parts.dropFirst().first ?? "TASK"
      let items = (grouped[key] ?? []).sorted {
        if $0.assignedAt == $1.assignedAt {
          return $0.headline < $1.headline
        }
        return ($0.assignedAt ?? "") > ($1.assignedAt ?? "")
      }
      return AssignedWorkSection(
        id: key,
        label: "\(assignee) / \(todo)",
        items: items
      )
    }
  }

  private static func assignedWorkTodoGroupLabel(for item: AssignedWorkItem) -> String {
    let todo = item.todo?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    return todo?.isEmpty == false ? todo! : "TASK"
  }

  static func assignedWorkFilterText(for item: AssignedWorkItem) -> String {
    [
      item.todo,
      item.headline,
      item.assignee,
      item.status,
      item.assignedAt,
      item.lastAgentUpdate,
      item.file,
      item.tags.joined(separator: " "),
      item.properties.map { "\($0.key) \($0.value)" }.joined(separator: " ")
    ].compactMap { $0 }.joined(separator: " ").lowercased()
  }

  public func selectAssignedWorkItem(_ item: AssignedWorkItem) {
    deactivateAgendaFilterFocus()
    select(.assigned(item), surface: .agenda)
  }

  public func selectAIChatThreadRecord(_ thread: AIChatThreadRecord) {
    openAIChatThreadRecord(thread, surface: .files)
  }

  func openAIChatThreadRecord(_ thread: AIChatThreadRecord, surface: WorkspaceSurface? = nil, mode: EntrySourceMode? = nil) {
    activateDetailLocation(.aiChatThreadRecord(thread), mode: mode, surface: surface, recordsHistory: true)
  }

  public func selectCorpusFile(_ file: CorpusFile, surface: WorkspaceSurface = .files) {
    let thread = AIChatThreadRecord(
      title: file.name,
      file: file.path,
      line: 1,
      zone: file.directory.isEmpty ? "corpus" : file.directory,
      modifiedAt: file.modifiedAt,
      idValue: nil
    )
    activateDetailLocation(.aiChatThreadRecord(thread), mode: .page, surface: surface, recordsHistory: true)
    if selectedCorpusFileID != file.id {
      selectedCorpusFileID = file.id
    }
    if selectedAIChatThreadRecordID != nil {
      selectedAIChatThreadRecordID = nil
    }
    statusText = "Opened \(file.relativePath)"
  }

  func activateSelectedCorpusFileFromList(_ file: CorpusFile) {
    guard selectedSurface == .files,
          !isWorkspaceSurfacePaneClosed,
          selectedCorpusFileID == file.id
    else { return }
    selectCorpusFile(file)
  }

  public func handleCorpusFileClick(
    _ file: CorpusFile,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    selectedCorpusFileIDsForAIContext = Self.updatedAIContextSelection(
      selectedCorpusFileIDsForAIContext,
      activeID: selectedCorpusFileID,
      clickedID: file.id,
      visibleIDs: filteredCorpusFiles.map(\.id),
      modifiers: modifiers
    )
    if selectedCorpusFileID == file.id {
      pendingNavigationSource = "file_list"
      selectCorpusFile(file)
    } else {
      selectedCorpusFileID = file.id
    }
  }

  public func isCorpusFileSelectedForAIContext(_ file: CorpusFile) -> Bool {
    selectedCorpusFileIDsForAIContext.isEmpty
      ? selectedCorpusFileID == file.id
      : selectedCorpusFileIDsForAIContext.contains(file.id)
  }

  public func reconcileCorpusFileAIContextSelection(visibleIDs: [CorpusFile.ID]) {
    let reconciled = selectedCorpusFileIDsForAIContext.intersection(visibleIDs)
    if reconciled != selectedCorpusFileIDsForAIContext {
      selectedCorpusFileIDsForAIContext = reconciled
    }
  }

  func selectAllVisibleCorpusFilesForAIContext() {
    let visibleIDs = filteredCorpusFiles.map(\.id)
    selectedCorpusFileIDsForAIContext = Set(visibleIDs)
    statusText = Self.listSelectionStatus(count: visibleIDs.count, singular: "file")
  }

  func clearCorpusFileAIContextSelection() {
    guard !selectedCorpusFileIDsForAIContext.isEmpty else { return }
    selectedCorpusFileIDsForAIContext = []
    statusText = "File selection cleared"
  }

  func extendCorpusFileAIContextSelection(by delta: Int) {
    let files = filteredCorpusFiles
    let result = Self.extendedKeyboardSelection(
      selectedCorpusFileIDsForAIContext,
      activeID: selectedCorpusFileID,
      visibleIDs: files.map(\.id),
      delta: delta
    )
    guard let targetID = result.targetID,
          let target = files.first(where: { $0.id == targetID })
    else {
      statusText = "No visible files"
      return
    }
    selectedCorpusFileIDsForAIContext = result.selection
    selectCorpusFile(target)
    statusText = Self.listSelectionStatus(count: result.selection.count, singular: "file")
  }

  public func openSidebarFile(_ file: CorpusFile) {
    let keepsVisibleChatPane =
      !isWorkspaceSurfacePaneClosed
      && (selectedSurface == .home || selectedSurface == .aiChat)
    let surface = keepsVisibleChatPane ? selectedSurface : .files

    pendingNavigationSource = "sidebar"
    selectCorpusFile(file, surface: surface)
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = !keepsVisibleChatPane
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    isAIChatAssistantPresented = false
  }

  public func isFilePinned(path: String) -> Bool {
    guard let relativePath = pinnedFileRelativePath(for: path) else { return false }
    return pinnedFileRelativePaths.contains(relativePath)
  }

  public func togglePinnedFile(_ file: CorpusFile) {
    togglePinnedFile(path: file.path)
  }

  public func togglePinnedFile(path: String) {
    guard let relativePath = pinnedFileRelativePath(for: path) else {
      statusText = "Only files inside the current corpus can be pinned"
      return
    }
    if let index = pinnedFileRelativePaths.firstIndex(of: relativePath) {
      pinnedFileRelativePaths.remove(at: index)
      statusText = "Unpinned \(relativePath)"
    } else {
      pinnedFileRelativePaths.append(relativePath)
      statusText = "Pinned \(relativePath)"
    }
    persistPinnedFiles()
    schedulePinnedCorpusFileProjection()
  }

  private func pinnedFileRelativePath(for path: String) -> String? {
    guard let corpusRoot else { return nil }
    let rootPath = corpusRoot.standardizedFileURL.path
    let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else { return nil }
    return String(filePath.dropFirst(prefix.count))
  }

  func restorePinnedFiles(for corpusRoot: URL) {
    let storage = defaults.dictionary(forKey: pinnedFilesByCorpusKey) ?? [:]
    pinnedFileRelativePaths = storage[corpusRoot.standardizedFileURL.path] as? [String] ?? []
    schedulePinnedCorpusFileProjection()
  }

  private func persistPinnedFiles() {
    guard let corpusRoot else { return }
    var storage = defaults.dictionary(forKey: pinnedFilesByCorpusKey) ?? [:]
    let key = corpusRoot.standardizedFileURL.path
    if pinnedFileRelativePaths.isEmpty {
      storage.removeValue(forKey: key)
    } else {
      storage[key] = pinnedFileRelativePaths
    }
    defaults.set(storage, forKey: pinnedFilesByCorpusKey)
  }

  func restoreAutomaticDailyNoteCreationPreference(for corpusRoot: URL) -> Bool {
    let storage = defaults.dictionary(forKey: automaticDailyNoteCreationDisabledByCorpusKey) ?? [:]
    return storage[corpusRoot.standardizedFileURL.path] as? Bool ?? false
  }

  func persistAutomaticDailyNoteCreationPreference(for corpusRoot: URL) {
    var storage = defaults.dictionary(forKey: automaticDailyNoteCreationDisabledByCorpusKey) ?? [:]
    let key = corpusRoot.standardizedFileURL.path
    if automaticDailyNoteCreationDisabled {
      storage[key] = true
    } else {
      storage.removeValue(forKey: key)
    }
    defaults.set(storage, forKey: automaticDailyNoteCreationDisabledByCorpusKey)
  }

  func reconcilePinnedFiles(for corpusRoot: URL) async {
    guard self.corpusRoot?.path == corpusRoot.path else { return }
    schedulePinnedCorpusFileProjection()
    await pinnedCorpusFileProjectionTask?.value
  }

  // MARK: Navigation attribution, frecency, and the local usage log

  func noteChatTurnTransitions(from previous: Set<UUID>, to current: Set<UUID>) {
    guard previous != current else { return }
    let now = CFAbsoluteTimeGetCurrent()
    for threadID in current.subtracting(previous) {
      chatTurnStartTimes[threadID] = now
      guard usageLog.isEnabled else { continue }
      let thread = aiChatThreads.first(where: { $0.id == threadID })
      usageLog.record(.chatTurnStart, [
        "runtime": .string(thread?.runtime.rawValue ?? "unknown"),
        "heading_thread": .bool(thread?.resource != nil),
      ])
    }
    for threadID in previous.subtracting(current) {
      let started = chatTurnStartTimes.removeValue(forKey: threadID)
      guard usageLog.isEnabled else { continue }
      var fields: [String: OpenOrgUsageValue] = [:]
      if let started { fields["seconds"] = .double(now - started) }
      usageLog.record(.chatTurnFinish, fields)
    }
  }

  /// Tags the next document activation with how it was reached so the local
  /// usage log can tell Quick Open from links, sidebar, history, and so on.
  func setPendingNavigationSource(_ source: String) {
    pendingNavigationSource = source
  }

  func noteDocumentNavigation(to location: WorkspaceLocation, recordsHistory: Bool) {
    let source = pendingNavigationSource ?? (recordsHistory ? "other" : "restore")
    pendingNavigationSource = nil
    let path = URL(fileURLWithPath: location.file).standardizedFileURL.path
    let previousPath = selectedLocation.map { URL(fileURLWithPath: $0.file).standardizedFileURL.path }
    let relative = corpusFilesByPath[path]?.relativePath ?? pinnedFileRelativePath(for: path)
    if let relative, source != "tab_switch", source != "restore", previousPath != path {
      recordFileVisit(relativePath: relative)
    }
    guard usageLog.isEnabled else { return }
    var fields: [String: OpenOrgUsageValue] = [
      "source": .string(source),
      "ext": .string(URL(fileURLWithPath: path).pathExtension.lowercased()),
      "same_file": .bool(previousPath == path),
      "in_corpus": .bool(relative != nil),
    ]
    if let relative { fields["file"] = usageLog.pathToken(relative) }
    usageLog.record(.documentOpen, fields)
    pendingDocumentReadyMeasurement = previousPath == path
      ? nil
      : (path: path, startedAt: CFAbsoluteTimeGetCurrent(), source: source)
  }

  func noteDocumentReady(for location: WorkspaceLocation, cached: Bool) {
    guard let pending = pendingDocumentReadyMeasurement else { return }
    let path = URL(fileURLWithPath: location.file).standardizedFileURL.path
    guard pending.path == path else { return }
    pendingDocumentReadyMeasurement = nil
    let milliseconds = (CFAbsoluteTimeGetCurrent() - pending.startedAt) * 1000
    usageLog.record(.documentReady, [
      "source": .string(pending.source),
      "ms": .double(milliseconds),
      "cached": .bool(cached),
    ])
  }

  private func currentFileFrecency() -> WorkspaceFileFrecency {
    guard let corpusRoot else { return WorkspaceFileFrecency() }
    let root = corpusRoot.standardizedFileURL.path
    if let cache = fileFrecencyCache, cache.root == root { return cache.value }
    let storage = defaults.dictionary(forKey: fileFrecencyByCorpusKey) ?? [:]
    let value = (storage[root] as? Data)
      .flatMap { try? JSONDecoder().decode(WorkspaceFileFrecency.self, from: $0) }
      ?? WorkspaceFileFrecency()
    fileFrecencyCache = (root, value)
    return value
  }

  func recordFileVisit(relativePath: String, at date: Date = Date()) {
    guard let corpusRoot else { return }
    let root = corpusRoot.standardizedFileURL.path
    var value = currentFileFrecency()
    value.recordVisit(relativePath, at: date)
    fileFrecencyCache = (root, value)
    fileFrecencyRevision &+= 1
    var storage = defaults.dictionary(forKey: fileFrecencyByCorpusKey) ?? [:]
    storage[root] = try? JSONEncoder().encode(value)
    defaults.set(storage, forKey: fileFrecencyByCorpusKey)
  }

  /// Carries pins and open history from a renamed file to its new path.
  func renameFileReferences(fromRelativePath oldPath: String, toRelativePath newPath: String) {
    guard let corpusRoot, oldPath != newPath else { return }
    if let index = pinnedFileRelativePaths.firstIndex(of: oldPath) {
      if pinnedFileRelativePaths.contains(newPath) {
        pinnedFileRelativePaths.remove(at: index)
      } else {
        pinnedFileRelativePaths[index] = newPath
      }
      persistPinnedFiles()
      schedulePinnedCorpusFileProjection()
    }
    let root = corpusRoot.standardizedFileURL.path
    var value = currentFileFrecency()
    guard value.visitsByPath[oldPath] != nil else { return }
    value.rename(from: oldPath, to: newPath)
    fileFrecencyCache = (root, value)
    fileFrecencyRevision &+= 1
    var storage = defaults.dictionary(forKey: fileFrecencyByCorpusKey) ?? [:]
    storage[root] = try? JSONEncoder().encode(value)
    defaults.set(storage, forKey: fileFrecencyByCorpusKey)
  }

  public func fileFrecencyScore(relativePath: String, now: Date = Date()) -> Double {
    currentFileFrecency().score(relativePath, now: now)
  }

  /// Recently and frequently opened corpus files, best first. Missing files are skipped.
  public func recentCorpusFiles(limit: Int = 12, now: Date = Date()) -> [CorpusFile] {
    _ = fileFrecencyRevision
    guard limit > 0 else { return [] }
    let byRelativePath = Dictionary(
      corpusFiles.map { ($0.relativePath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var result: [CorpusFile] = []
    for entry in currentFileFrecency().ranked(now: now) {
      guard let file = byRelativePath[entry.path] else { continue }
      result.append(file)
      if result.count == limit { break }
    }
    return result
  }

  public func fileFrecencyScores(now: Date = Date()) -> [String: Double] {
    _ = fileFrecencyRevision
    return currentFileFrecency().scores(now: now)
  }

  private func rankedRecentFileCount() -> Int {
    currentFileFrecency().ranked(now: Date()).count
  }

  public func isRecentCorpusFile(_ file: CorpusFile) -> Bool {
    _ = fileFrecencyRevision
    return fileFrecencyScore(relativePath: file.relativePath) > 0
  }

  public func presentQuickOpen() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    quickOpenQuery = ""
    resetQuickOpenSelection()
    isQuickOpenPresented = true
    usageLog.record(.quickOpenPresent, ["recent_count": .int(rankedRecentFileCount())])
    if corpusFiles.isEmpty {
      Task { await refreshCorpusFiles() }
    }
  }

  public func presentKeyboardShortcuts() {
    isKeyboardShortcutsPresented = true
  }

  public func focusSearchSurface() {
    makeSurfacePrimary(.search)
    searchFocusToken += 1
    warmAIChatSearchIndex()
  }

  /// Hand a quick-open query to full workspace search: show Search in text
  /// mode with the query and run it.
  public func searchWorkspace(for query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    isQuickOpenPresented = false
    searchMode = .text
    searchQuery = trimmed
    focusSearchSurface()
    guard !trimmed.isEmpty else { return }
    Task { await runSearch() }
  }

  public func presentAIChatThreadFind() {
    guard selectedSurface == .home || selectedSurface == .aiChat else { return }
    aiChatFindRequestGeneration &+= 1
  }

  @discardableResult
  public func focusCurrentSearchField() -> Bool {
    let detailIsSearchTarget = hasWorkspaceDetailContent
      && !isWorkspaceDetailPaneClosed
      && (isWorkspaceSurfacePaneClosed || activeWorkspacePane == .detail)
    if detailIsSearchTarget, focusPageSearch() {
      return true
    }

    switch selectedSurface {
    case .agenda:
      focusAgendaFilter(clearsFilter: false)
    case .approvals:
      focusRunsAndReviewFilter()
    case .files, .canvases:
      focusCorpusFileFilter()
    case .home, .aiChat:
      presentAIChatThreadFind()
    case .savedViews, .meetings, .sources, .externalThreads, .skills, .activity:
      return focusPageSearch()
    case .search:
      if selectedLocation != nil {
        return focusPageSearch()
      }
      focusSearchSurface()
    }
    return true
  }

  public func selectSearchNode(_ node: OrgRoamNodeReference) {
    let thread = AIChatThreadRecord(
      title: node.title,
      file: node.file,
      line: node.line,
      zone: "node",
      modifiedAt: nil,
      idValue: node.idValue
    )
    pendingNavigationSource = "search"
    activateDetailLocation(.aiChatThreadRecord(thread), mode: .entry, surface: .search, recordsHistory: true)
    selectedAIChatThreadRecordID = nil
    statusText = "Opened \(relativePath(node.file)):\(node.line)"
  }

  public func selectSearchFile(_ file: CorpusFile) {
    selectedCorpusFileID = file.id
    let thread = AIChatThreadRecord(
      title: file.name,
      file: file.path,
      line: 1,
      zone: file.directory.isEmpty ? "corpus" : file.directory,
      modifiedAt: file.modifiedAt,
      idValue: nil
    )
    pendingNavigationSource = "search"
    activateDetailLocation(.aiChatThreadRecord(thread), mode: .page, surface: .search, recordsHistory: true)
    selectedAIChatThreadRecordID = nil
    statusText = "Opened \(file.relativePath)"
  }

  public func selectAgentWorkSearchResult(_ result: WorkspaceAgentWorkSearchResult) {
    switch result.kind {
    case .approval:
      if let runID = result.parentRunID,
         let run = agentRunsByID[runID] {
        runsAndReviewPage = .runs
        selectAgentRun(run)
        statusText = "Opened \(result.title) in its run"
      } else if let approval = approvalItems.first(where: { $0.id == result.recordID }) {
        runsAndReviewPage = .review
        selectApprovalItem(approval)
      }
    case .run:
      guard let run = agentRunsByID[result.recordID] else { return }
      runsAndReviewPage = .runs
      selectAgentRun(run)
    case .workflow:
      guard let workflow = agentWorkflows.first(where: { $0.id == result.recordID }) else { return }
      runsAndReviewPage = .workflows
      selectAgentWorkflow(workflow)
    case .goal:
      guard let goal = agentGoals.first(where: { $0.id == result.recordID }) else { return }
      runsAndReviewPage = .goals
      selectAgentGoal(goal)
    case .agent:
      guard let profile = agentProfiles.first(where: { $0.id == result.recordID }) else { return }
      runsAndReviewPage = .agents
      selectAgentProfile(profile)
    }
  }

  func rebuildWorkspaceTextSearchDisplayCache() {
    let query = workspaceSearchRankingQuery ?? searchQuery
    var modifiedAtByPath: [String: Date] = [:]
    let referencedPaths = Set(searchResults.map(\.file) + workspacePageSearchResults.map(\.file))
    if !referencedPaths.isEmpty {
      for file in corpusFiles where referencedPaths.contains(file.path) {
        modifiedAtByPath[file.path] = file.modifiedAt
      }
    }
    workspaceTextSearchItems = Self.rankedWorkspaceSearchItems(
      corpusResults: searchResults,
      files: workspaceFileSearchResults,
      chats: aiChatSearchResults,
      agentWork: workspaceAgentWorkSearchResults,
      pages: workspacePageSearchResults,
      query: query,
      modifiedAtByPath: modifiedAtByPath,
      now: Date()
    )
    corpusSearchResultGroups = Self.groupedSearchResultsForDisplay(searchResults)
  }

  public var workspaceTextSearchResultCount: Int {
    workspaceTextSearchItems.count
  }

  /// Merges every search source into one list ordered by match quality plus
  /// a strong recency bias, rather than by result type.
  nonisolated static func rankedWorkspaceSearchItems(
    corpusResults: [SearchResult],
    files: [CorpusFile],
    chats: [AIChatSearchResult],
    agentWork: [WorkspaceAgentWorkSearchResult],
    pages: [OrgRoamNodeReference],
    query rawQuery: String,
    modifiedAtByPath: [String: Date] = [:],
    now: Date = Date(),
    limit: Int = workspaceSearchMergedDisplayLimit
  ) -> [WorkspaceTextSearchItem] {
    let query = WorkspaceSearchQuery(rawQuery)
    var ranked: [(item: WorkspaceTextSearchItem, score: Double, date: Date?)] = []
    ranked.reserveCapacity(corpusResults.count + files.count + chats.count + agentWork.count + pages.count)

    // One row per heading: further matches inside the same entry add noise.
    var seenEntries = Set<String>()
    for result in corpusResults {
      if result.headingLine != nil,
         !seenEntries.insert(corpusEntrySearchIdentity(result)).inserted {
        continue
      }
      let recency = WorkspaceSearchRanking.corpusResultRecency(
        result,
        modifiedAt: modifiedAtByPath[result.file],
        now: now
      )
      let item: WorkspaceTextSearchItem = result.isActiveTodo
        ? .activeTodo(result)
        : result.heading?.isEmpty == false ? .entry(result) : .corpusText(result)
      ranked.append((
        item,
        WorkspaceSearchRanking.corpusResultQuality(result, query: query) + recency.boost,
        recency.date
      ))
    }

    for file in files {
      let quality = query.flatMap { WorkspaceSearchRanking.fileQuality(file, query: $0) }
        ?? WorkspaceSearchRanking.pathOnlyQuality
      let recency = WorkspaceSearchRanking.fileRecency(file, now: now)
      ranked.append((.file(file), quality + recency.boost, recency.date))
    }

    var seenThreads = Set<UUID>()
    for chat in chats where seenThreads.insert(chat.threadID).inserted {
      let quality = chat.matchKind == .threadTitle
        ? query.flatMap { $0.titleQuality(chat.title) } ?? WorkspaceSearchRanking.substringTitleQuality
        : WorkspaceSearchRanking.bodyPhraseQuality
      let item: WorkspaceTextSearchItem = chat.matchKind == .threadTitle ? .chatThread(chat) : .chatMessage(chat)
      ranked.append((
        item,
        quality + WorkspaceSearchRanking.recencyBoost(chat.matchedAt, now: now),
        chat.matchedAt
      ))
    }

    for result in agentWork {
      let quality = query.flatMap { $0.titleQuality(result.title) } ?? WorkspaceSearchRanking.bodyPhraseQuality
      ranked.append((
        .agentWork(result),
        quality + WorkspaceSearchRanking.recencyBoost(result.updatedAt, now: now),
        result.updatedAt
      ))
    }

    for node in pages {
      let quality = query.flatMap { WorkspaceSearchRanking.pageQuality(node, query: $0) }
        ?? WorkspaceSearchRanking.substringTitleQuality
      let modifiedAt = modifiedAtByPath[node.file]
      ranked.append((
        .page(node),
        quality + WorkspaceSearchRanking.recencyBoost(
          modifiedAt,
          now: now,
          factor: WorkspaceSearchRanking.modifiedTimeRecencyFactor
        ),
        modifiedAt
      ))
    }

    let ordered = ranked.enumerated().sorted { lhs, rhs in
      if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
      let lhsDate = lhs.element.date ?? .distantPast
      let rhsDate = rhs.element.date ?? .distantPast
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      return lhs.offset < rhs.offset
    }
    return ordered.prefix(max(0, limit)).map(\.element.item)
  }

  nonisolated private static func corpusEntrySearchIdentity(_ result: SearchResult) -> String {
    [
      result.corpus?.id ?? "",
      result.file,
      String(result.headingLine ?? result.line)
    ].joined(separator: "\u{1F}")
  }

  nonisolated static func searchAgentWorkForWorkspace(
    runs: [AgentRunItem],
    approvals: [ApprovalItem],
    workflows: [AgentWorkflowItem],
    goals: [AgentGoalItem],
    profiles: [AgentProfileItem],
    query rawQuery: String,
    limitPerCategory: Int
  ) -> [WorkspaceAgentWorkSearchResult] {
    let terms = rawQuery
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !terms.isEmpty, limitPerCategory > 0 else { return [] }

    func matches(_ values: [String?], _ extra: [String]...) -> Bool {
      var parts: [String] = values.compactMap { $0 }
      for list in extra { parts.append(contentsOf: list) }
      let text = parts.joined(separator: "\n").lowercased()
      return terms.allSatisfy(text.contains)
    }

    func fileLabel(_ path: String) -> String {
      URL(fileURLWithPath: path).lastPathComponent
    }

    var approvalResults: [WorkspaceAgentWorkSearchResult] = []
    var runResults: [WorkspaceAgentWorkSearchResult] = []
    var workflowResults: [WorkspaceAgentWorkSearchResult] = []
    var goalResults: [WorkspaceAgentWorkSearchResult] = []
    var profileResults: [WorkspaceAgentWorkSearchResult] = []
    var indexedRunApprovalKeys = Set<String>()

    for run in runs {
      let matchingApprovals = run.approvals
        .filter { approval in
          matches([
            approval.id,
            approval.fingerprint,
            approval.title,
            approval.action,
            approval.riskClass,
            approval.status,
            approval.requestedRole,
            approval.requestedFrom,
            approval.decidedBy,
            approval.decisionNote,
            approval.note,
            approval.receipt,
            run.id,
            run.goal,
            run.agentRef,
            run.goalRef,
            run.workflowId,
          ])
        }
        .sorted { lhs, rhs in
          (lhs.decidedAt ?? lhs.requestedAt) > (rhs.decidedAt ?? rhs.requestedAt)
        }

      for approval in matchingApprovals where approvalResults.count < limitPerCategory {
        indexedRunApprovalKeys.insert("\(run.id):\(approval.id)")
        let detail = approval.decisionNote?.nilIfBlank
          ?? approval.note?.nilIfBlank
          ?? approval.action
        approvalResults.append(WorkspaceAgentWorkSearchResult(
          id: "run-approval:\(run.id):\(approval.id)",
          kind: .approval,
          recordID: approval.id,
          parentRunID: run.id,
          title: approval.title,
          snippet: "\(run.goal) · \(detail)",
          status: approval.status,
          sourceReference: "Run \(run.id.prefix(8))",
          updatedAt: WorkspaceSearchRanking.isoDate(approval.decidedAt ?? approval.requestedAt)
        ))
      }

      if matchingApprovals.isEmpty,
         runResults.count < limitPerCategory,
         run.matchesRunFilter(rawQuery) {
        runResults.append(WorkspaceAgentWorkSearchResult(
          id: "run:\(run.id)",
          kind: .run,
          recordID: run.id,
          title: run.goal,
          snippet: run.outcome?.summary.nilIfBlank
            ?? run.blockedReason?.nilIfBlank
            ?? run.progressText,
          status: run.status,
          sourceReference: "Run \(run.id.prefix(8))",
          updatedAt: WorkspaceSearchRanking.isoDate(run.updatedAt)
        ))
      }
    }

    for approval in approvals where approvalResults.count < limitPerCategory {
      if let runID = approval.runId,
         let approvalID = approval.approvalId,
         indexedRunApprovalKeys.contains("\(runID):\(approvalID)") {
        continue
      }
      let propertyText: [String] = approval.properties
        .sorted { $0.key < $1.key }
        .flatMap { [$0.key, $0.value] }
      guard matches([
        approval.idValue,
        approval.approvalId,
        approval.title,
        approval.status,
        approval.todo,
        approval.file,
        approval.body,
        approval.action,
        approval.riskClass,
        approval.requestedRole,
        approval.requestedFrom,
        approval.runId,
        approval.runGoal,
      ], approval.tags, propertyText) else { continue }
      approvalResults.append(WorkspaceAgentWorkSearchResult(
        id: "approval:\(approval.id)",
        kind: .approval,
        recordID: approval.id,
        parentRunID: approval.runId,
        title: approval.title,
        snippet: approval.runGoal?.nilIfBlank ?? approval.body,
        status: approval.status,
        sourceReference: approval.runId.map { "Run \($0.prefix(8))" }
          ?? "\(fileLabel(approval.file)):\(max(1, approval.line))",
        updatedAt: WorkspaceSearchRanking.isoDate(approval.requestedAt)
      ))
    }

    for workflow in workflows where workflowResults.count < limitPerCategory {
      let inputs: [String] = workflow.inputs.flatMap { [$0.id, $0.description, $0.default ?? ""] }
      let triggers: [String] = workflow.triggers.flatMap {
        [$0.id, $0.type, $0.schedule ?? "", $0.timezone ?? ""]
      }
      guard matches([
        workflow.id,
        workflow.version,
        workflow.title,
        workflow.description,
        workflow.state,
        workflow.instructions,
        workflow.riskClass,
        workflow.file,
        workflow.agentRef,
        workflow.goalRef,
      ], workflow.capabilities, inputs, triggers) else { continue }
      workflowResults.append(WorkspaceAgentWorkSearchResult(
        id: "workflow:\(workflow.id)",
        kind: .workflow,
        recordID: workflow.id,
        title: workflow.title,
        snippet: workflow.description,
        status: workflow.state,
        sourceReference: fileLabel(workflow.file)
      ))
    }

    for goal in goals where goalResults.count < limitPerCategory {
      guard matches([
        goal.id,
        goal.title,
        goal.description,
        goal.status,
        goal.parentGoalRef,
        goal.ownerAgentRef,
        goal.file,
      ], goal.measures) else { continue }
      goalResults.append(WorkspaceAgentWorkSearchResult(
        id: "goal:\(goal.id)",
        kind: .goal,
        recordID: goal.id,
        title: goal.title,
        snippet: goal.description,
        status: goal.status,
        sourceReference: fileLabel(goal.file)
      ))
    }

    for profile in profiles where profileResults.count < limitPerCategory {
      let bindings: [String] = profile.runtimeBindings.flatMap { [$0.runtime, $0.runtimeAgentId] }
      guard matches([
        profile.id,
        profile.name,
        profile.description,
        profile.status,
        profile.primaryGoalRef,
        profile.reportsToAgentRef,
        profile.file,
      ], profile.responsibilities, profile.capabilities, profile.skills, profile.goalRefs, bindings) else { continue }
      profileResults.append(WorkspaceAgentWorkSearchResult(
        id: "agent:\(profile.id)",
        kind: .agent,
        recordID: profile.id,
        title: profile.name,
        snippet: profile.description,
        status: profile.status,
        sourceReference: fileLabel(profile.file)
      ))
    }

    return approvalResults + runResults + workflowResults + goalResults + profileResults
  }

  nonisolated static func searchCorpusFilesForWorkspace(
    _ files: [CorpusFile],
    query rawQuery: String,
    limit: Int,
    now: Date = Date()
  ) -> [CorpusFile] {
    guard let query = WorkspaceSearchQuery(rawQuery), limit > 0 else { return [] }
    return files
      .compactMap { file -> (CorpusFile, Double)? in
        guard let quality = WorkspaceSearchRanking.fileQuality(file, query: query) else { return nil }
        return (file, quality + WorkspaceSearchRanking.fileRecency(file, now: now).boost)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.relativePath.localizedStandardCompare(rhs.0.relativePath) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0)
  }

  nonisolated static func searchPageNodesForWorkspace(
    _ nodes: [OrgRoamNodeReference],
    query rawQuery: String,
    limit: Int
  ) -> [OrgRoamNodeReference] {
    guard let query = WorkspaceSearchQuery(rawQuery), limit > 0 else { return [] }
    return nodes
      .filter(\.isPageNode)
      .compactMap { node -> (OrgRoamNodeReference, Double)? in
        guard let quality = WorkspaceSearchRanking.pageQuality(node, query: query) else { return nil }
        return (node, quality)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        let titleOrder = lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.0.file.localizedStandardCompare(rhs.0.file) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0)
  }

  /// Orders corpus matches by match quality plus recency and keeps one row
  /// per active TODO.
  nonisolated static func prioritizedSearchResultsForDisplay(
    _ results: [SearchResult],
    query rawQuery: String = "",
    limit: Int? = nil,
    modifiedAtByPath: [String: Date] = [:],
    now: Date = Date()
  ) -> [SearchResult] {
    let query = WorkspaceSearchQuery(rawQuery)
    let ranked = results.enumerated()
      .map { offset, result in
        let recency = WorkspaceSearchRanking.corpusResultRecency(
          result,
          modifiedAt: modifiedAtByPath[result.file],
          now: now
        )
        return (
          offset: offset,
          result: result,
          score: WorkspaceSearchRanking.corpusResultQuality(result, query: query) + recency.boost
        )
      }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.offset < rhs.offset
      }
      .map(\.result)

    var seenActiveTodos: Set<String> = []
    let deduplicated = ranked.filter { result in
      guard result.isActiveTodo else { return true }
      return seenActiveTodos.insert(activeTodoSearchIdentity(result)).inserted
    }
    guard let limit else { return deduplicated }
    return Array(deduplicated.prefix(max(0, limit)))
  }

  nonisolated static func groupedSearchResultsForDisplay(_ results: [SearchResult]) -> [SearchResultGroup] {
    var grouped: [String: [SearchResult]] = [:]
    var fileOrder: [String] = []

    for result in results {
      if grouped[result.file] == nil {
        fileOrder.append(result.file)
        grouped[result.file] = []
      }
      grouped[result.file]?.append(result)
    }

    return fileOrder.compactMap { file in
      SearchResultGroup(file: file, results: grouped[file] ?? [])
    }
  }

  nonisolated private static func activeTodoSearchIdentity(_ result: SearchResult) -> String {
    [
      result.corpus?.id ?? "",
      result.file,
      String(result.headingLine ?? result.line),
      result.heading ?? ""
    ].joined(separator: "\u{1F}")
  }

  public var selectedQuickOpenFile: CorpusFile? {
    if let selectedQuickOpenFileID {
      guard let selected = quickOpenItems.first(where: { $0.id == selectedQuickOpenFileID }),
            case .file(let file) = selected
      else {
        return nil
      }
      return file
    }
    return quickOpenFiles.first
  }

  public var selectedQuickOpenItem: WorkspaceQuickOpenItem? {
    if let selectedQuickOpenFileID,
       let selected = quickOpenItems.first(where: { $0.id == selectedQuickOpenFileID }) {
      return selected
    }
    return quickOpenItems.first
  }

  public func resetQuickOpenSelection() {
    selectedQuickOpenFileID = nil
  }

  public func moveQuickOpenSelection(_ direction: QuickOpenSelectionDirection) {
    let items = quickOpenItems
    guard !items.isEmpty else {
      selectedQuickOpenFileID = nil
      return
    }

    let currentIndex = selectedQuickOpenFileID.flatMap { id in
      items.firstIndex { $0.id == id }
    }
    let nextIndex: Int
    switch (direction, currentIndex) {
    case (.down, nil):
      nextIndex = items.startIndex
    case (.up, nil):
      nextIndex = items.index(before: items.endIndex)
    case (.down, let index?):
      nextIndex = index == items.index(before: items.endIndex) ? items.startIndex : items.index(after: index)
    case (.up, let index?):
      nextIndex = index == items.startIndex ? items.index(before: items.endIndex) : items.index(before: index)
    }
    selectedQuickOpenFileID = items[nextIndex].id
  }

  public func selectQuickOpenItem(_ item: WorkspaceQuickOpenItem, inNewTab: Bool = false) {
    if inNewTab {
      // Capture rank before the new tab resets transient state.
      let rank = quickOpenItems.firstIndex(of: item) ?? -1
      newWorkspaceTab()
      usageLog.record(.quickOpenSelect, ["kind": "file_new_tab", "rank": .int(rank)])
      if case .file(let file) = item {
        pendingNavigationSource = "quick_open"
        selectCorpusFile(file, surface: .files)
        return
      }
    }
    switch item {
    case .file(let file):
      let rank = quickOpenItems.firstIndex(of: item) ?? -1
      usageLog.record(.quickOpenSelect, [
        "kind": "file",
        "rank": .int(rank),
        "query_length": .int(quickOpenQuery.count),
        "recent": .bool(fileFrecencyScore(relativePath: file.relativePath) > 0),
      ])
      pendingNavigationSource = "quick_open"
      selectCorpusFile(file, surface: selectedSurface)
    case .chatThread(let thread):
      usageLog.record(.quickOpenSelect, [
        "kind": "chat",
        "rank": .int(quickOpenItems.firstIndex(of: item) ?? -1),
        "query_length": .int(quickOpenQuery.count),
      ])
      navigateToSurface(.aiChat)
      selectAIChatThread(thread.id)
      sidebarPromotedAIChatThreadID = thread.id
      statusText = "Opened \(thread.title)"
    case .approval(let approval):
      usageLog.record(.quickOpenSelect, [
        "kind": "approval",
        "rank": .int(quickOpenItems.firstIndex(of: item) ?? -1),
        "query_length": .int(quickOpenQuery.count),
      ])
      openApprovalInReview(approval)
    }
  }

  /// Opens an approval where it is decided: its run (whose decision card
  /// holds it) or, for a standalone approval, its entry in Agent Work → Review.
  public func openApprovalInReview(_ approval: ApprovalItem) {
    navigateToSurface(.approvals)
    runsAndReviewPage = .review
    approvalFilter = ""
    selectApprovalItem(approval)
  }

  /// Corpus assignment is intentionally constant-time on the main actor. The
  /// dictionary and normalized search rows scale with corpus size, so build an
  /// immutable projection on a detached task and publish only the latest one.
  /// Yielding once coalesces several assignments made in the same watcher or
  /// mutation burst before any corpus-scale work starts.
  func resetCorpusFileDerivedState() {
    orgRoamLinkResolverRefreshTask?.cancel()
    orgRoamLinkResolverRefreshTask = nil
    searchNodeSearchGeneration &+= 1
    searchNodeSearchTask?.cancel()
    searchNodeSearchTask = nil
    searchNodes = []
    corpusFileProjectionGeneration &+= 1
    corpusFileProjectionTask?.cancel()
    corpusFileProjectionTask = nil
    resetPinnedCorpusFileProjection()
    corpusFileDisplayGeneration &+= 1
    corpusFileDisplayTask?.cancel()
    corpusFileDisplayTask = nil
    corpusFileProjection = .empty
    corpusFilesByPath = [:]
    quickOpenIndexedFiles = []
    corpusFileTree = []
    publishFilteredCorpusFiles([], tree: [])
    quickOpenSearchGeneration += 1
    quickOpenSearchTask?.cancel()
    quickOpenFiles = []
    quickOpenItems = []
  }

  func scheduleCorpusFileProjection() {
    corpusFileProjectionGeneration &+= 1
    let projectionGeneration = corpusFileProjectionGeneration
    let filesGeneration = corpusFilesGeneration
    let files = corpusFiles
    corpusFileProjectionTask?.cancel()

    // Keep empty-query lists coherent immediately without doing corpus-scale
    // work. These prefixes are hard bounded by their UI result limits.
    if corpusFileFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      publishFilteredCorpusFiles(Array(files.prefix(500)), tree: [])
    } else {
      publishFilteredCorpusFiles([], tree: [])
    }
    if quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      quickOpenFiles = Array(files.prefix(80))
      quickOpenItems = quickOpenFiles.map(WorkspaceQuickOpenItem.file)
      pruneQuickOpenSelection()
    }

    guard !files.isEmpty else {
      corpusFileProjectionTask = nil
      publishCorpusFileProjection(
        .empty,
        tree: [],
        projectionGeneration: projectionGeneration,
        filesGeneration: filesGeneration
      )
      return
    }

    corpusFileProjectionTask = Task { @MainActor [weak self, files] in
      await Task.yield()
      guard !Task.isCancelled,
            let self,
            self.corpusFileProjectionGeneration == projectionGeneration,
            self.corpusFilesGeneration == filesGeneration
      else { return }

      self.corpusFileProjectionBuildCountForTesting += 1
      let (projection, tree) = await Task.detached(priority: .utility) {
        (
          CorpusFileCatalog.projection(for: files),
          Self.makeCorpusFileTree(files)
        )
      }.value
      guard !Task.isCancelled,
            self.corpusFileProjectionGeneration == projectionGeneration,
            self.corpusFilesGeneration == filesGeneration
      else { return }

      self.publishCorpusFileProjection(
        projection,
        tree: tree,
        projectionGeneration: projectionGeneration,
        filesGeneration: filesGeneration
      )
    }
  }

  private func publishCorpusFileProjection(
    _ projection: CorpusFileCatalog.Projection,
    tree: [CorpusFileTreeNode],
    projectionGeneration: UInt64,
    filesGeneration: UInt64
  ) {
    guard corpusFileProjectionGeneration == projectionGeneration,
          corpusFilesGeneration == filesGeneration
    else { return }

    corpusFileProjection = projection
    corpusFilesByPath = projection.filesByPath
    quickOpenIndexedFiles = projection.indexedFiles
    corpusFileTree = tree
    corpusFileProjectionTask = nil
    schedulePinnedCorpusFileProjection(catalogProjection: projection)
    scheduleCorpusFileDisplayRefresh()
    scheduleQuickOpenSearch(debounce: false)
  }

  private func resetPinnedCorpusFileProjection() {
    pinnedCorpusFileProjectionGeneration &+= 1
    pinnedCorpusFileProjectionTask?.cancel()
    pinnedCorpusFileProjectionTask = nil
    guard !pinnedCorpusFiles.isEmpty else { return }
    pinnedCorpusFiles = []
    pinnedCorpusFileProjectionPublicationCountForTesting += 1
  }

  /// The sidebar consumes a stored, equality-gated projection. Resolving pins
  /// must never rebuild a corpus dictionary or touch the filesystem from a
  /// SwiftUI body: the corpus-scale relative-path map is built by the existing
  /// detached catalog lane, and the O(number of pins) fallback runs detached.
  private func schedulePinnedCorpusFileProjection(
    catalogProjection: CorpusFileCatalog.Projection? = nil
  ) {
    pinnedCorpusFileProjectionGeneration &+= 1
    let projectionGeneration = pinnedCorpusFileProjectionGeneration
    let sessionGeneration = corpusSessionGeneration
    pinnedCorpusFileProjectionTask?.cancel()
    pinnedCorpusFileProjectionTask = nil

    guard let root = corpusRoot else {
      if !pinnedCorpusFiles.isEmpty {
        pinnedCorpusFiles = []
        pinnedCorpusFileProjectionPublicationCountForTesting += 1
      }
      return
    }
    let relativePaths = pinnedFileRelativePaths
    guard !relativePaths.isEmpty else {
      if !pinnedCorpusFiles.isEmpty {
        pinnedCorpusFiles = []
        pinnedCorpusFileProjectionPublicationCountForTesting += 1
      }
      return
    }

    let filesByRelativePath = (
      catalogProjection ?? corpusFileProjection
    ).filesByRelativePath
    let catalogFiles = relativePaths.compactMap { filesByRelativePath[$0] }
    if catalogFiles.count == relativePaths.count,
       catalogFiles == pinnedCorpusFiles {
      return
    }

    let preparation = pinnedCorpusFileProjectionPreparationForTesting
    let didBuild = pinnedCorpusFileProjectionDidBuildForTesting
    pinnedCorpusFileProjectionTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled,
            let self,
            self.pinnedCorpusFileProjectionGeneration == projectionGeneration,
            self.corpusSessionGeneration == sessionGeneration,
            self.corpusRoot?.path == root.path
      else { return }

      if let preparation {
        await preparation(root, relativePaths)
      }
      guard !Task.isCancelled,
            self.pinnedCorpusFileProjectionGeneration == projectionGeneration,
            self.corpusSessionGeneration == sessionGeneration,
            self.corpusRoot?.path == root.path
      else { return }

      let projection = await Task.detached(priority: .utility) {
        Self.makePinnedCorpusFileProjection(
          filesByRelativePath: filesByRelativePath,
          corpusRoot: root,
          relativePaths: relativePaths,
          didBuild: didBuild
        )
      }.value
      self.pinnedCorpusFileProjectionBuildCountForTesting += 1
      if projection.wasBuiltOnMainThread {
        self.pinnedCorpusFileProjectionMainThreadBuildCountForTesting += 1
      }
      guard !Task.isCancelled,
            self.pinnedCorpusFileProjectionGeneration == projectionGeneration,
            self.corpusSessionGeneration == sessionGeneration,
            self.corpusRoot?.path == root.path
      else { return }

      self.pinnedCorpusFileProjectionTask = nil
      if projection.existingRelativePaths != self.pinnedFileRelativePaths {
        self.pinnedFileRelativePaths = projection.existingRelativePaths
        self.persistPinnedFiles()
      }
      guard projection.files != self.pinnedCorpusFiles else { return }
      self.pinnedCorpusFiles = projection.files
      self.pinnedCorpusFileProjectionPublicationCountForTesting += 1
    }
  }

  nonisolated private static func makePinnedCorpusFileProjection(
    filesByRelativePath: [String: CorpusFile],
    corpusRoot: URL,
    relativePaths: [String],
    didBuild: (@Sendable (Bool) -> Void)?
  ) -> PinnedCorpusFileProjection {
    let wasBuiltOnMainThread = Thread.isMainThread
    didBuild?(wasBuiltOnMainThread)
    var files: [CorpusFile] = []
    files.reserveCapacity(relativePaths.count)
    var existingRelativePaths: [String] = []
    existingRelativePaths.reserveCapacity(relativePaths.count)
    for relativePath in relativePaths {
      let file = filesByRelativePath[relativePath]
        ?? corpusFile(
          atPath: corpusRoot.appendingPathComponent(relativePath).path,
          corpusRoot: corpusRoot
        )
      guard let file else { continue }
      files.append(file)
      existingRelativePaths.append(relativePath)
    }
    return PinnedCorpusFileProjection(
      files: files,
      existingRelativePaths: existingRelativePaths,
      wasBuiltOnMainThread: wasBuiltOnMainThread
    )
  }

  func rebuildQuickOpenChatIndex() {
    let signature = aiChatThreads.map {
      AIChatQuickOpenChatIndexSignature(id: $0.id, title: $0.title)
    }
    guard signature != quickOpenChatIndexSignature else { return }
    quickOpenChatIndexSignature = signature
    quickOpenIndexedChatThreads = aiChatThreads.map { thread in
      QuickOpenIndexedChatThread(
        id: thread.id,
        title: thread.title,
        normalizedTitle: Self.normalizedQuickOpenCandidate(thread.title)
      )
    }
    quickOpenChatThreadIndexesByID = Dictionary(
      uniqueKeysWithValues: aiChatThreads.enumerated().map { ($0.element.id, $0.offset) }
    )
  }

  func scheduleCorpusFileDisplayRefresh() {
    corpusFileDisplayGeneration &+= 1
    let generation = corpusFileDisplayGeneration
    let indexedFiles = quickOpenIndexedFiles
    let query = corpusFileFilter
    let fullTree = corpusFileTree
    corpusFileDisplayTask?.cancel()

    guard !indexedFiles.isEmpty else {
      corpusFileDisplayTask = nil
      publishFilteredCorpusFiles([], tree: [])
      return
    }

    corpusFileDisplayTask = Task { @MainActor [weak self, indexedFiles, query] in
      await Task.yield()
      guard !Task.isCancelled,
            let self,
            self.corpusFileDisplayGeneration == generation
      else { return }

      let (files, tree) = await Task.detached(priority: .userInitiated) {
        let files = Self.filterIndexedQuickOpenFiles(
          indexedFiles,
          query: query,
          limit: 500
        )
        let tree = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? fullTree
          : Self.makeCorpusFileTree(files)
        return (files, tree)
      }.value
      guard !Task.isCancelled,
            self.corpusFileDisplayGeneration == generation,
            self.corpusFileFilter == query
      else { return }

      self.publishFilteredCorpusFiles(files, tree: tree)
      self.corpusFileDisplayTask = nil
    }
  }

  private func publishFilteredCorpusFiles(
    _ files: [CorpusFile],
    tree: [CorpusFileTreeNode]
  ) {
    filteredCorpusFiles = files
    filteredCorpusFileTree = tree
    reconcileCorpusFileAIContextSelection(visibleIDs: files.map(\.id))
  }

  func awaitCorpusFilePublication() async {
    while corpusFileCatalogMutationTask != nil
      || corpusFileProjectionTask != nil
      || pinnedCorpusFileProjectionTask != nil
      || corpusFileDisplayTask != nil {
      if let corpusFileCatalogMutationTask {
        await corpusFileCatalogMutationTask.value
      }
      if let corpusFileProjectionTask {
        await corpusFileProjectionTask.value
      }
      if let pinnedCorpusFileProjectionTask {
        await pinnedCorpusFileProjectionTask.value
      }
      if let corpusFileDisplayTask {
        await corpusFileDisplayTask.value
      }
    }
  }

  func waitForCorpusFilePublicationForTesting() async {
    await awaitCorpusFilePublication()
  }

  nonisolated static func makeCorpusFileTree(_ files: [CorpusFile]) -> [CorpusFileTreeNode] {
    let root = MutableCorpusFileTreeNode()
    for file in files {
      let components = file.relativePath.split(separator: "/").map(String.init)
      guard !components.isEmpty else { continue }
      var directory = root
      for component in components.dropLast() {
        if let existing = directory.directories[component] {
          directory = existing
        } else {
          let created = MutableCorpusFileTreeNode()
          directory.directories[component] = created
          directory = created
        }
      }
      directory.files.append(file)
    }

    func materialize(
      _ node: MutableCorpusFileTreeNode,
      relativePath: String
    ) -> [CorpusFileTreeNode] {
      let directories = node.directories.keys.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
      }.compactMap { name -> CorpusFileTreeNode? in
        guard let child = node.directories[name] else { return nil }
        let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
        let children = materialize(child, relativePath: childPath)
        return CorpusFileTreeNode(
          id: "directory:\(childPath)",
          name: name,
          relativePath: childPath,
          file: nil,
          children: children,
          descendantFileCount: children.reduce(0) { $0 + $1.descendantFileCount }
        )
      }
      let fileNodes = node.files.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }.map { file in
        CorpusFileTreeNode(
          id: file.id,
          name: file.name,
          relativePath: file.relativePath,
          file: file,
          children: nil,
          descendantFileCount: 1
        )
      }
      return directories + fileNodes
    }

    return materialize(root, relativePath: "")
  }

  func scheduleQuickOpenSearch(debounce: Bool = true) {
    quickOpenSearchGeneration += 1
    let generation = quickOpenSearchGeneration
    let query = quickOpenQuery
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    quickOpenSearchTask?.cancel()

    guard !trimmedQuery.isEmpty else {
      isFilteringQuickOpenFiles = false
      // Empty query: frequently and recently opened files first, then the
      // rest of the corpus alphabetically.
      let recent = recentCorpusFiles(limit: 15)
      let recentIDs = Set(recent.map(\.id))
      quickOpenFiles = recent + corpusFiles.lazy.filter { !recentIDs.contains($0.id) }.prefix(80 - recent.count)
      quickOpenItems = quickOpenFiles.map(WorkspaceQuickOpenItem.file)
      pruneQuickOpenSelection()
      return
    }

    let indexedFiles = quickOpenIndexedFiles
    let indexedChatThreads = quickOpenIndexedChatThreads
    // The review queue is small; index it per search so it is never stale.
    let indexedApprovals = approvalItems.map(QuickOpenIndexedApproval.init)
    let frecencyScores = currentFileFrecency().scores(now: Date())
    if !isFilteringQuickOpenFiles {
      isFilteringQuickOpenFiles = true
    }
    quickOpenSearchTask = Task { [indexedFiles, indexedChatThreads, indexedApprovals, frecencyScores, query, generation, debounce] in
      if debounce {
        try? await Task.sleep(nanoseconds: 80_000_000)
      }
      guard !Task.isCancelled else { return }

      let matches = await Task.detached(priority: .userInitiated) {
        Self.filterQuickOpenItems(
          files: indexedFiles,
          chatThreads: indexedChatThreads,
          approvals: indexedApprovals,
          query: query,
          limit: 80,
          frecencyScores: frecencyScores
        )
      }.value
      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self, self.quickOpenSearchGeneration == generation else { return }
        let items = matches.compactMap { match -> WorkspaceQuickOpenItem? in
          switch match {
          case .file(let file):
            return .file(file)
          case .chatThread(let id):
            guard let index = self.quickOpenChatThreadIndexesByID[id],
                  self.aiChatThreads.indices.contains(index),
                  self.aiChatThreads[index].id == id
            else { return nil }
            return .chatThread(self.aiChatThreads[index])
          case .approval(let approval):
            return .approval(approval)
          }
        }
        self.quickOpenItems = items
        self.quickOpenFiles = items.compactMap { item in
          guard case .file(let file) = item else { return nil }
          return file
        }
        self.isFilteringQuickOpenFiles = false
        self.pruneQuickOpenSelection()
      }
    }
  }

  private func pruneQuickOpenSelection() {
    guard let selectedQuickOpenFileID else { return }
    if !quickOpenItems.contains(where: { $0.id == selectedQuickOpenFileID }) {
      self.selectedQuickOpenFileID = nil
    }
  }

  nonisolated private static func filterIndexedQuickOpenFiles(
    _ files: [QuickOpenIndexedFile],
    query rawQuery: String,
    limit: Int
  ) -> [CorpusFile] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedQuery = normalizedQuickOpenQuery(query)
    guard !normalizedQuery.isEmpty else {
      return Array(files.prefix(limit).map(\.file))
    }

    return files
      .compactMap { indexedFile -> (QuickOpenIndexedFile, Int)? in
        guard let score = fuzzyScore(normalizedQuery: normalizedQuery, normalizedCandidate: indexedFile.normalizedRelativePath)
        else { return nil }
        return (indexedFile, score)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.file.relativePath.localizedStandardCompare(rhs.0.file.relativePath) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0.file)
  }

  nonisolated private static func filterQuickOpenItems(
    files: [QuickOpenIndexedFile],
    chatThreads: [QuickOpenIndexedChatThread],
    approvals: [QuickOpenIndexedApproval] = [],
    query rawQuery: String,
    limit: Int,
    frecencyScores: [String: Double] = [:]
  ) -> [QuickOpenSearchMatch] {
    let normalizedQuery = normalizedQuickOpenQuery(
      rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard !normalizedQuery.isEmpty else {
      return Array(files.prefix(limit).map { QuickOpenSearchMatch.file($0.file) })
    }

    let fileMatches = files.compactMap { indexedFile -> (QuickOpenSearchMatch, Int, String)? in
      guard let score = fuzzyScore(
        normalizedQuery: normalizedQuery,
        normalizedCandidate: indexedFile.normalizedRelativePath
      ) else {
        return nil
      }
      let bonus = WorkspaceFileFrecency.quickOpenBonus(
        frecencyScores[indexedFile.file.relativePath] ?? 0
      )
      return (.file(indexedFile.file), score + bonus, indexedFile.file.relativePath)
    }
    let chatMatches = chatThreads.compactMap { thread -> (QuickOpenSearchMatch, Int, String)? in
      guard let score = fuzzyScore(
        normalizedQuery: normalizedQuery,
        normalizedCandidate: thread.normalizedTitle
      ) else {
        return nil
      }
      return (.chatThread(thread.id), score, thread.title)
    }
    let approvalMatches = approvals.compactMap { approval -> (QuickOpenSearchMatch, Int, String)? in
      // A title match ranks with files and chats; a match only on what the
      // approval asks for still lists it, below them.
      let score = fuzzyScore(normalizedQuery: normalizedQuery, normalizedCandidate: approval.normalizedTitle)
        ?? fuzzyScore(normalizedQuery: normalizedQuery, normalizedCandidate: approval.normalizedDetail)
          .map { $0 / 2 }
      guard let score else { return nil }
      return (.approval(approval.item), score, approval.item.title)
    }

    return (fileMatches + chatMatches + approvalMatches)
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.2.localizedStandardCompare(rhs.2) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0)
  }

  /// Publish only immutable snapshots on the main actor. Resolver indexes,
  /// normalized search candidates, and corpus-relative paths all scale with
  /// corpus size and are built by `makeOrgRoamSearchProjection` off actor.
  func publishOrgRoamSearchProjection(
    _ projectionBox: OrgRoamSearchProjectionBox,
    recordsDetachedBuild: Bool = true
  ) {
    let projection = projectionBox.projection
    if recordsDetachedBuild {
      orgRoamSearchProjectionBuildCountForTesting &+= 1
      if projection.wasBuiltOnMainThread {
        orgRoamSearchProjectionMainThreadBuildCountForTesting &+= 1
      }
    }

    // Watchers may report a file even when its semantic node projection did
    // not change. Avoid invalidating the root SwiftUI environment (and its
    // mounted NSTableView) for a content-identical resolver. Cache restoration
    // explicitly bypasses this fast path because it also changes corpus scope.
    if recordsDetachedBuild,
       projection.resolver == orgRoamLinkResolver {
      orgRoamSearchProjectionReleaseSink.enqueue([projectionBox])
      return
    }

    let replacedProjectionBox = OrgRoamSearchProjectionBox(
      projection: OrgRoamSearchProjection(
        resolver: orgRoamLinkResolver,
        searchNodeIndexRows: searchNodeIndexRows,
        wasBuiltOnMainThread: false
      ),
      releaseMetrics: orgRoamSearchProjectionReleaseMetrics
    )
    orgRoamLinkResolver = projection.resolver
    searchNodeIndexRows = projection.searchNodeIndexRows
    orgRoamSearchProjectionReleaseSink.enqueue([
      replacedProjectionBox,
      projectionBox,
    ])

    if searchMode == .nodes {
      scheduleSearchNodeDisplayRefresh(debounce: false)
    } else {
      searchNodeSearchGeneration &+= 1
      searchNodeSearchTask?.cancel()
      searchNodeSearchTask = nil
      searchNodes = []
    }
  }

  func publishEmptyOrgRoamSearchProjection() {
    publishOrgRoamSearchProjection(
      OrgRoamSearchProjectionBox(
        projection: OrgRoamSearchProjection(
          resolver: .empty,
          searchNodeIndexRows: [],
          wasBuiltOnMainThread: false
        ),
        releaseMetrics: orgRoamSearchProjectionReleaseMetrics
      ),
      recordsDetachedBuild: false
    )
  }

  nonisolated static func makeOrgRoamSearchProjection(
    resolver: OrgRoamLinkResolver,
    files: [CorpusFile],
    corpusRoot: URL?
  ) -> OrgRoamSearchProjection {
    var relativePathsByAbsolutePath: [String: String] = [:]
    relativePathsByAbsolutePath.reserveCapacity(files.count * 2)
    for file in files {
      relativePathsByAbsolutePath[file.path] = file.relativePath
      relativePathsByAbsolutePath[
        URL(fileURLWithPath: file.path).standardizedFileURL.path
      ] = file.relativePath
    }

    let rows = resolver.nodes.compactMap { node -> SearchNodeIndexRow? in
      guard node.isPageNode else { return nil }
      let standardizedNodePath = URL(fileURLWithPath: node.file).standardizedFileURL.path
      let relativePath = relativePathsByAbsolutePath[node.file]
        ?? relativePathsByAbsolutePath[standardizedNodePath]
        ?? corpusRelativePathWithoutFilesystemAccess(
          for: standardizedNodePath,
          root: corpusRoot
        )
      let labels = [node.title] + node.aliases
      let candidates = [
        node.title,
        node.aliases.joined(separator: " "),
        node.idValue ?? "",
        relativePath
      ]
      return SearchNodeIndexRow(
        node: node,
        normalizedCandidates: candidates.map(normalizedQuickOpenCandidate),
        normalizedLabels: labels.map(normalizedQuickOpenCandidate)
      )
    }
    return OrgRoamSearchProjection(
      resolver: resolver,
      searchNodeIndexRows: rows,
      wasBuiltOnMainThread: Thread.isMainThread
    )
  }
}
