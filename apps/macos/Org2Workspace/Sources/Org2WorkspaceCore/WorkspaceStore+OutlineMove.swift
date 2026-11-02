import Foundation

/// Drag-and-drop reordering and nesting of headings and list items in the
/// rendered document.
extension WorkspaceStore {
  /// Moves a heading subtree or list item as the rendered page requested.
  /// The page addresses lines of the source it was rendered from, so the
  /// write only proceeds when the file still holds exactly that text.
  @discardableResult
  public func moveRenderedOutlineEntry(_ request: OrgOutlineMoveRequest) async -> Bool {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This document is read-only"
      return false
    }
    guard !isEditingEntry else {
      statusText = "Save or close source editing before moving entries"
      return false
    }
    let firstMovableLine = source.isSubtree ? source.startLine + 1 : source.startLine
    guard request.startLine >= firstMovableLine,
          request.endLine < source.endLineExclusive,
          request.targetLine >= firstMovableLine,
          request.targetLine <= source.endLineExclusive
    else {
      statusText = "That entry can't be moved outside this view"
      return false
    }
    if source.isSubtree, request.kind == .heading {
      let rootLevel = OrgOutlineMove.headingLevel(
        source.text.prefix { $0 != "\n" }.description
      ) ?? 0
      guard (request.level ?? 0) > rootLevel else {
        statusText = "Headings in this view must stay inside it"
        return false
      }
    }

    let relativeRequest = request.offsettingLines(by: 1 - source.startLine)
    let replacement: String
    do {
      replacement = try OrgOutlineMove.apply(relativeRequest, to: source.text)
    } catch OrgOutlineMoveError.unchanged {
      return false
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not move entry"
      if let selectedLocation { scheduleEntrySourceLoad(for: selectedLocation) }
      return false
    }

    isSavingBlock = true
    defer { isSavingBlock = false }
    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.endLineExclusive,
        replacement: replacement,
        expectedOriginal: source.text
      )
      await recordFileUndo(from: undoSnapshot)
      invalidateCanonicalDocumentCache(for: source.file)
      let staleRenderKey = entryHTMLRenderKey(for: source)
      releaseWorkspaceCacheBoxesOffMain(
        renderedHTMLCache.removeValue(forKey: staleRenderKey).map { [$0] } ?? []
      )
      renderedHTMLCacheOrder.removeAll { $0 == staleRenderKey }
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      } else if selectedEntrySource?.id == source.id {
        let updated = Self.entrySource(source, replacingText: replacement)
        selectedEntrySource = updated
        renderEntrySource(updated, generation: entrySourceLoadGeneration)
      }
      statusText = request.kind == .heading ? "Moved heading" : "Moved list item"
      scheduleAgendaRefresh(preserveSelection: true)
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not move entry"
      if let selectedLocation { scheduleEntrySourceLoad(for: selectedLocation) }
      return false
    }
  }
}
