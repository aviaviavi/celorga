import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func recordMeetingReadyAutomationFailure(
    eventID: String,
    item: MeetingWorkspaceItem,
    threadID: UUID?,
    error: String
  ) {
    meetingReadyAutomationDeliveries[eventID] = MeetingReadyAutomationDeliveryRecord(
      eventID: eventID,
      meetingFile: item.file,
      destinationID: meetingReadyAutomationSettings.destinationID,
      threadID: threadID,
      status: .failed,
      updatedAt: Date(),
      error: error
    )
    persistMeetingReadyAutomationDeliveries()
    meetingReadyAutomationStatusText = "Meeting delivery pending: \(error)"
  }

  func queueAIChatAutomationMessage(
    _ text: String,
    threadID: UUID,
    marker: String,
    context: AIChatCorpusContextToken
  ) -> AIChatEnqueueResult {
    guard isCurrentAIChatCorpusContext(context) else { return .rejected }
    if unloadedAIChatThreadIDs.contains(threadID) {
      hydrateAIChatThread(threadID)
      let deferred: Task<AIChatEnqueueOutcome, Never> = Task { @MainActor [weak self] in
        guard let self else { return .rejected }
        let hydrated = await self.hydrateAIChatThreadIfNeeded(threadID)
        guard self.isCurrentAIChatCorpusContext(context) else { return .superseded }
        guard let hydrated else { return .rejected }
        if hydrated.messages.contains(where: { $0.role == .user && $0.content.contains(marker) }) {
          return .enqueued(threadID: threadID, shouldDrain: false)
        }
        let retry = self.enqueueAIChatMessage(
          text,
          attachments: [],
          in: threadID,
          deliveryKind: self.isAIChatThreadRunning(threadID) ? .followUp : .turn,
          context: context
        )
        return await self.resolveDeferredAIChatEnqueue(retry)
      }
      return .deferred(deferred)
    }
    if aiChatMessages(for: threadID).contains(where: {
      $0.role == .user && $0.content.contains(marker)
    }) {
      return .enqueued(threadID: threadID, shouldDrain: false)
    }
    return enqueueAIChatMessage(
      text,
      attachments: [],
      in: threadID,
      deliveryKind: isAIChatThreadRunning(threadID) ? .followUp : .turn,
      context: context
    )
  }

  public func requestOpenClawGatewayPairing() async {
    aiChatStatusText = "Requesting Gateway device access…"
    do {
      let client = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
      try await client.prepare()
      if openClawLocalEditsEnabled {
        startOpenClawLocalEditNode()
        aiChatStatusText = "OpenClaw operator access is live; local edit node pairing requested"
      } else {
        aiChatStatusText = "OpenClaw Gateway device is paired and live"
      }
      await refreshAIChatCommands(force: true)
    } catch let error as OpenClawGatewayError {
      aiChatStatusText = error.localizedDescription
    } catch {
      aiChatStatusText = "Gateway pairing failed: \(error.localizedDescription)"
    }
  }

  public var openClawLocalEditNodeDisplayName: String {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    return bundleID.hasSuffix(".codex")
      ? "Celorga Local Edits (Codex)"
      : "Celorga Local Edits"
  }

  func localEditBroker() -> AIChatLocalEditBroker {
    if let aiChatLocalEditBroker {
      return aiChatLocalEditBroker
    }
    let broker = AIChatLocalEditBroker(
      documentReader: { [weak self] turnID, path, requestedRoot in
        guard let self else { throw AIChatLocalEditError.inactiveTurn }
        let corpusRoot = try self.authorizedAIChatCorpusRoot(
          turnID: turnID,
          requestedRoot: requestedRoot
        )
        return try self.aiChatLocalEditDocument(at: path, corpusRoot: corpusRoot)
      },
      replacementApplier: { [weak self] turnID, replacements in
        guard let self else { throw AIChatLocalEditError.inactiveTurn }
        let corpusRoot = try self.aiChatLocalEditCorpus(for: turnID)
        return try await self.applyAIChatLocalEditReplacements(
          replacements,
          corpusRoot: corpusRoot
        )
      }
    )
    aiChatLocalEditBroker = broker
    return broker
  }

  func aiChatLocalEditCorpus(for turnID: String) throws -> URL {
    guard let expectedRoot = aiChatLocalEditCorpusRootsByTurnID[turnID] else {
      throw AIChatLocalEditError.inactiveTurn
    }
    return expectedRoot
  }

  func startOpenClawLocalEditNode() {
    guard openClawLocalEditsEnabled else {
      openClawLocalEditNodeState = .disabled
      openClawLocalEditNodeDetail = ""
      return
    }
    guard corpusRoot != nil else {
      openClawLocalEditNodeState = .stopped
      openClawLocalEditNodeDetail = "Choose a corpus before starting local edits."
      return
    }
    guard openClawLocalEditNodeTask == nil else { return }

    let node = OpenClawLocalEditNode(
      settings: currentOpenClawSettings(allowKeychainRead: true),
      broker: localEditBroker(),
      displayName: openClawLocalEditNodeDisplayName
    ) { [weak self] state, detail in
      guard let self else { return }
      self.openClawLocalEditNodeState = state
      self.openClawLocalEditNodeDetail = detail ?? ""
    }
    openClawLocalEditNode = node
    openClawLocalEditNodeTask = Task { @MainActor [weak self, node] in
      await node.run()
      guard let self, self.openClawLocalEditNode === node else { return }
      self.openClawLocalEditNodeTask = nil
      self.openClawLocalEditNode = nil
    }
  }

  func restartOpenClawLocalEditNode() {
    let previousNode = openClawLocalEditNode
    openClawLocalEditNodeTask?.cancel()
    openClawLocalEditNodeTask = nil
    openClawLocalEditNode = nil
    if !openClawLocalEditsEnabled {
      openClawLocalEditNodeState = .disabled
      openClawLocalEditNodeDetail = ""
    }
    Task { @MainActor [weak self] in
      await previousNode?.stop()
      guard let self, self.openClawLocalEditsEnabled else { return }
      self.startOpenClawLocalEditNode()
    }
  }

  func aiChatLocalEditDocument(
    at rawPath: String,
    corpusRoot requestedCorpusRoot: URL? = nil,
    enforcesSnapshotSizeLimit: Bool = true
  ) throws -> AIChatLocalEditDocument {
    // The broker's read callback is intentionally synchronous today. Keep
    // this explicit request path compatible with that cross-file contract;
    // the latency-sensitive multi-file apply preflight below is detached.
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else {
      throw AIChatLocalEditError.invalidRequest("no active corpus")
    }
    let url = try aiChatLocalEditURL(for: rawPath, corpusRoot: corpusRoot)
    let relativePath = Self.relativePath(for: url.path, root: corpusRoot)
    let diskBaseline = try Self.aiChatLocalEditDiskBaseline(at: url)
    return try Self.aiChatLocalEditDocument(
      relativePath: relativePath,
      url: url,
      diskBaseline: diskBaseline,
      overlay: aiChatLocalEditOverlay(for: corpusRoot),
      enforcesSnapshotSizeLimit: enforcesSnapshotSizeLimit
    )
  }

  private func aiChatLocalEditOverlay(for requestedCorpusRoot: URL) -> AIChatLocalEditOverlay? {
    guard corpusRoot?.standardizedFileURL.path == requestedCorpusRoot.standardizedFileURL.path,
          let source = selectedEntrySource
    else { return nil }
    let file = URL(fileURLWithPath: source.file).standardizedFileURL.path
    let selectedFile = selectedEntrySource?.file ?? selectedLocation?.file
    guard selectedFile.map({
      URL(fileURLWithPath: $0).standardizedFileURL.path == file
    }) == true else { return nil }

    if isLiveFileEditorSelected {
      guard source.startLine == 1, !source.isSubtree else {
        return .invalidWholeFile(file: file)
      }
      return .wholeFile(
        file: file,
        text: editableEntryText,
        isDirty: liveFileEditorHasUnsavedChanges
      )
    }
    if isEditingEntry {
      return .sourceRange(
        file: file,
        source: source,
        replacement: sourceEditorLocalDraftText ?? editableEntryText,
        isDirty: entryEditorHasUnsavedChanges
      )
    }
    if let block = activeEditingBlock, transientDraftBlock == nil {
      let sourceBlock = activeBlockOriginals[block.id] ?? block
      return .sourceRange(
        file: file,
        source: EntrySource(
          file: source.file,
          startLine: sourceBlock.startLine,
          endLineExclusive: sourceBlock.endLineExclusive,
          text: sourceBlock.rawText,
          isSubtree: false
        ),
        replacement: saveReplacementText(for: block),
        isDirty: true
      )
    }
    return nil
  }

  private func aiChatLocalEditPreparationIdentity() -> AIChatLocalEditPreparationIdentity {
    AIChatLocalEditPreparationIdentity(
      corpusSessionGeneration: corpusSessionGeneration,
      selectedSourceID: selectedEntrySource?.id,
      sourceDraftGeneration: sourceEditorDraftGeneration,
      liveDraftGeneration: liveFileEditorDraftGeneration
    )
  }

  nonisolated private static func aiChatLocalEditDocument(
    relativePath: String,
    url: URL,
    diskBaseline: AIChatLocalEditDiskBaseline,
    overlay: AIChatLocalEditOverlay?,
    enforcesSnapshotSizeLimit: Bool
  ) throws -> AIChatLocalEditDocument {
    guard diskBaseline.existed else {
      return AIChatLocalEditDocument(relativePath: relativePath, text: "", origin: .missing)
    }
    let diskText = diskBaseline.text
    guard !enforcesSnapshotSizeLimit
      || diskText.utf8.count <= Self.aiChatChangeSnapshotMaxFileBytes
    else {
      throw AIChatLocalEditError.oversizedRequest
    }

    guard let overlay,
          WorkspaceDocumentMutationLane.canonicalPath(overlay.file)
            == WorkspaceDocumentMutationLane.canonicalPath(url.path)
    else {
      return AIChatLocalEditDocument(
        relativePath: relativePath,
        text: diskText,
        origin: .disk
      )
    }

    switch overlay {
    case .invalidWholeFile:
      throw AIChatLocalEditError.invalidRequest(
        "the selected file editor is not a whole-file editor"
      )
    case .wholeFile(_, let text, let isDirty):
      return AIChatLocalEditDocument(
        relativePath: relativePath,
        text: text,
        origin: isDirty ? .editor : .disk
      )
    case .sourceRange(_, let source, let replacement, let isDirty):
      guard source.file == overlay.file else {
        throw AIChatLocalEditError.invalidRequest("the selected file editor is not a whole-file editor")
      }
      let effective = try Self.aiChatEffectiveFileText(
        diskText: diskText,
        source: source,
        replacement: replacement
      )
      return AIChatLocalEditDocument(
        relativePath: relativePath,
        text: effective,
        origin: isDirty ? .editor : .disk
      )
    }
  }

  nonisolated private static func aiChatLocalEditDiskBaseline(
    at url: URL
  ) throws -> AIChatLocalEditDiskBaseline {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return AIChatLocalEditDiskBaseline(existed: false, text: "")
    }
    return AIChatLocalEditDiskBaseline(
      existed: true,
      text: try String(contentsOf: url, encoding: .utf8)
    )
  }

  nonisolated private static func prepareAIChatLocalEdits(
    _ replacements: [AIChatLocalEditReplacement],
    corpusRoot: URL,
    overlay: AIChatLocalEditOverlay?
  ) throws -> PreparedAIChatLocalEdits {
    var documents: [String: AIChatLocalEditDocument] = [:]
    var urls: [String: URL] = [:]
    var diskBaselines: [String: AIChatLocalEditDiskBaseline] = [:]
    var changes: [AIChatCorpusFileChange] = []
    documents.reserveCapacity(replacements.count)
    urls.reserveCapacity(replacements.count)
    diskBaselines.reserveCapacity(replacements.count)
    changes.reserveCapacity(replacements.count)

    for replacement in replacements {
      let url = try aiChatLocalEditURL(
        for: replacement.relativePath,
        corpusRoot: corpusRoot
      )
      let relativePath = Self.relativePath(for: url.path, root: corpusRoot)
      let diskBaseline = try aiChatLocalEditDiskBaseline(at: url)
      let document = try aiChatLocalEditDocument(
        relativePath: relativePath,
        url: url,
        diskBaseline: diskBaseline,
        overlay: overlay,
        enforcesSnapshotSizeLimit: true
      )
      if replacement.createsFile {
        guard document.origin == .missing else {
          throw AIChatLocalEditError.staleDocument(document.relativePath)
        }
      } else {
        guard document.origin != .missing,
              document.sha256 == replacement.expectedSHA256
        else {
          throw AIChatLocalEditError.staleDocument(document.relativePath)
        }
      }
      documents[replacement.relativePath] = document
      urls[replacement.relativePath] = url
      diskBaselines[replacement.relativePath] = diskBaseline
      if let change = AIChatLocalEditBroker.fileChange(
        path: document.relativePath,
        before: replacement.createsFile ? nil : document.text,
        after: replacement.replacementText
      ) {
        changes.append(change)
      }
    }
    return PreparedAIChatLocalEdits(
      documents: documents,
      urls: urls,
      diskBaselines: diskBaselines,
      changes: changes
    )
  }

  func applyAIChatLocalEditReplacements(
    _ replacements: [AIChatLocalEditReplacement],
    corpusRoot requestedCorpusRoot: URL? = nil
  ) async throws -> AIChatLocalEditApplyResult {
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else {
      throw AIChatLocalEditError.invalidRequest("no active corpus")
    }
    let isActiveCorpus = self.corpusRoot?.standardizedFileURL.path
      == corpusRoot.standardizedFileURL.path
    let overlay = isActiveCorpus ? aiChatLocalEditOverlay(for: corpusRoot) : nil
    let preparationIdentity = aiChatLocalEditPreparationIdentity()
    let prepared = try await Task.detached(priority: .userInitiated) {
      try Self.prepareAIChatLocalEdits(
        replacements,
        corpusRoot: corpusRoot,
        overlay: overlay
      )
    }.value
    if isActiveCorpus,
       preparationIdentity != aiChatLocalEditPreparationIdentity() {
      throw AIChatLocalEditError.staleDocument(
        URL(fileURLWithPath: overlay?.file ?? corpusRoot.path).lastPathComponent
      )
    }
    let documents = prepared.documents
    let urls = prepared.urls
    let diskBaselines = prepared.diskBaselines
    let changes = prepared.changes

    let selectedPath = isActiveCorpus ? selectedEntrySource.map {
      URL(fileURLWithPath: $0.file).standardizedFileURL.path
    } : nil
    if replacements.contains(where: { urls[$0.relativePath]?.standardizedFileURL.path == selectedPath }) {
      cancelLiveFileEditorAutosave(resetStatus: false)
    }

    guard let mutationContext = captureDocumentCorpusContext(mutationRoot: corpusRoot) else {
      throw AIChatLocalEditError.inactiveTurn
    }
    let preparedURLs = urls
    let preparedDocuments = documents
    let preparedDiskBaselines = diskBaselines
    let resourcePaths = preparedURLs.values.map(\.path)
    try await performDocumentMutation(
      context: mutationContext,
      files: resourcePaths
    ) { execution in
      var snapshots: [String: WorkspaceDocumentSnapshot] = [:]
      for replacement in replacements {
        guard let url = preparedURLs[replacement.relativePath],
              let document = preparedDocuments[replacement.relativePath],
              let baseline = preparedDiskBaselines[replacement.relativePath]
        else {
          throw AIChatLocalEditError.invalidRequest("missing prepared replacement")
        }
        let snapshot = try await execution.readSnapshot(at: url, allowMissing: true)
        guard snapshot.existed == baseline.existed,
              snapshot.text == baseline.text
        else {
          throw AIChatLocalEditError.staleDocument(document.relativePath)
        }
        snapshots[replacement.relativePath] = snapshot
      }

      var committed: [(AIChatLocalEditReplacement, WorkspaceDocumentSnapshot)] = []
      do {
        for replacement in replacements {
          guard let snapshot = snapshots[replacement.relativePath] else {
            throw AIChatLocalEditError.invalidRequest("missing prepared replacement")
          }
          try await execution.commit(replacement.replacementText, over: snapshot) {
            text, url, previous in
            _ = try Self.aiChatLocalEditURL(
              for: replacement.relativePath,
              corpusRoot: corpusRoot
            )
            if replacement.createsFile {
              try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
              )
            }
            try Self.commitDocumentText(
              text,
              url: url,
              previousText: previous,
              operation: "AI local edit"
            )
          }
          committed.append((replacement, snapshot))
        }
      } catch {
        for (replacement, original) in committed.reversed() {
          guard let current = try? await execution.readSnapshot(at: original.url) else { continue }
          guard current.text == replacement.replacementText else { continue }
          if original.existed {
            try? await execution.commit(original.text, over: current) { text, url, previous in
              try Self.commitDocumentText(
                text,
                url: url,
                previousText: previous,
                operation: "AI local edit rollback",
                allowDestructiveReplacement: true
              )
            }
          } else {
            try? await execution.commit("", over: current) { _, url, _ in
              try FileManager.default.removeItem(at: url)
            }
          }
        }
        throw error
      }
    }

    let refreshedCorpusFiles: [String: CorpusFile]
    if isActiveCorpus {
      let preparedURLs = urls
      refreshedCorpusFiles = await Task.detached(priority: .utility) {
        Dictionary(uniqueKeysWithValues: preparedURLs.values.map { url in
          (
            url.standardizedFileURL.path,
            Self.corpusFileOffMain(for: url, corpusRoot: corpusRoot)
          )
        })
      }.value
    } else {
      refreshedCorpusFiles = [:]
    }

    for replacement in replacements {
      guard let document = documents[replacement.relativePath],
            let url = urls[replacement.relativePath]
      else { continue }
      if isActiveCorpus {
        recordWorkspaceUndo(
          .fileSnapshot(
            file: url.standardizedFileURL.path,
            previous: replacement.createsFile ? nil : document.text,
            next: replacement.replacementText
          )
        )
        invalidateCanonicalDocumentCache(for: url.path)
        if let file = refreshedCorpusFiles[url.standardizedFileURL.path] {
          upsertCorpusFile(file)
        }
      }
    }

    if isActiveCorpus,
       let selectedLocation,
       let selectedReplacement = replacements.first(where: {
         urls[$0.relativePath]?.standardizedFileURL.path
           == URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path
       }) {
      isEditingEntry = false
      resetBlockState()
      await loadEntrySource(for: selectedLocation)
      if isLiveFileEditorSelected, selectedEntrySourceMode == .page {
        if let selectedEntrySource {
          self.selectedEntrySource = Self.entrySource(
            selectedEntrySource,
            replacingText: selectedReplacement.replacementText
          )
        }
        replaceEditableEntryTextFromModel(selectedReplacement.replacementText)
        liveFileEditorStatusText = "Saved by AI"
      }
    }
    if isActiveCorpus {
      scheduleAgendaRefresh(preserveSelection: true)
    } else {
      invalidateCachedCorpusWorkspace(
        at: corpusRoot.path,
        surfaces: Set(WorkspaceSurface.allCases.filter { $0 != .home })
      )
    }

    return AIChatLocalEditApplyResult(
      summary: AIChatCorpusChangeSummary(files: changes)
    )
  }

  private func aiChatLocalEditURL(
    for rawPath: String,
    corpusRoot requestedCorpusRoot: URL? = nil
  ) throws -> URL {
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else {
      throw AIChatLocalEditError.invalidRequest("no active corpus")
    }
    return try Self.aiChatLocalEditURL(for: rawPath, corpusRoot: corpusRoot)
  }

  nonisolated private static func aiChatLocalEditURL(
    for rawPath: String,
    corpusRoot: URL
  ) throws -> URL {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.split(separator: "/").contains(where: { $0 == ".." })
    else {
      throw AIChatLocalEditError.invalidRequest("path must be relative to the active corpus")
    }
    let root = corpusRoot.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
    guard resolvedParent.path == root.path || resolvedParent.path.hasPrefix(root.path + "/") else {
      throw AIChatLocalEditError.invalidRequest("path escapes the active corpus")
    }
    // Missing parents are valid for read/preview; only apply creates them.
    // Check the nearest existing ancestor without following a dangling link.
    var ancestor = candidate.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    while !FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &isDirectory) {
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
        throw AIChatLocalEditError.invalidRequest("parent directory is a dangling symlink")
      }
      let parent = ancestor.deletingLastPathComponent()
      guard parent.path != ancestor.path else {
        throw AIChatLocalEditError.invalidRequest("no existing parent directory")
      }
      ancestor = parent
    }
    guard isDirectory.boolValue else {
      throw AIChatLocalEditError.invalidRequest("parent path is not a directory")
    }
    let resolvedAncestor = ancestor.resolvingSymlinksInPath()
    guard resolvedAncestor.path == root.path || resolvedAncestor.path.hasPrefix(root.path + "/") else {
      throw AIChatLocalEditError.invalidRequest("path escapes the active corpus")
    }
    if FileManager.default.fileExists(atPath: candidate.path) {
      let resolved = candidate.resolvingSymlinksInPath()
      guard resolved.path.hasPrefix(root.path + "/") else {
        throw AIChatLocalEditError.invalidRequest("path escapes the active corpus")
      }
    }
    guard Self.aiChatChangeSnapshotAllowedExtensions.contains(candidate.pathExtension.lowercased()) else {
      throw AIChatLocalEditError.invalidRequest("unsupported file type")
    }
    return candidate
  }

  nonisolated static func aiChatEffectiveFileText(
    diskText: String,
    source: EntrySource,
    replacement: String
  ) throws -> String {
    let normalizedDisk = normalizeLineEndings(diskText)
    var lines = normalizedDisk
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let startIndex = source.startLine - 1
    let endIndex = source.endLineExclusive - 1
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw AIChatLocalEditError.invalidRequest("the selected editor range is no longer valid")
    }
    let currentSource = lines[startIndex..<endIndex].joined(separator: "\n")
    guard currentSource == normalizeLineEndings(source.text) else {
      throw AIChatLocalEditError.staleDocument(
        URL(fileURLWithPath: source.file).lastPathComponent
      )
    }
    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)
    var output = lines.joined(separator: "\n")
    if normalizedDisk.hasSuffix("\n"), !output.isEmpty, !output.hasSuffix("\n") {
      output += "\n"
    }
    return output
  }

  public var aiChatAvailableSlashCommands: [AIChatSlashCommand] {
    AIChatSlashCommands.merged(
      with: openClawGatewayCommands,
      corpusSkills: corpusAgentSkillCommands
    )
  }

  public var activeAIChatGatewayCommands: [AIChatSlashCommand] {
    selectedAIChatRuntime == .openClaw ? openClawGatewayCommands : []
  }

  public func refreshCorpusAgentSkills(force: Bool = false) {
    guard let root = corpusRoot?.standardizedFileURL else {
      corpusAgentSkillRefreshGeneration &+= 1
      corpusAgentSkillRefreshTask?.cancel()
      corpusAgentSkillCommands = []
      workspaceSkills = []
      selectedWorkspaceSkillID = nil
      corpusAgentSkillRefreshTask = nil
      corpusAgentSkillLoadedCorpusPath = nil
      corpusAgentSkillRefreshCorpusPath = nil
      return
    }
    let rootPath = root.path
    if !force,
       corpusAgentSkillLoadedCorpusPath == rootPath
        || (corpusAgentSkillRefreshTask != nil
          && corpusAgentSkillRefreshCorpusPath == rootPath) {
      return
    }
    corpusAgentSkillRefreshGeneration &+= 1
    let generation = corpusAgentSkillRefreshGeneration
    corpusAgentSkillRefreshTask?.cancel()
    corpusAgentSkillRefreshCorpusPath = rootPath
    let sessionGeneration = corpusSessionGeneration
    let observer = corpusAgentSkillDiscoveryForTesting
    corpusAgentSkillRefreshTask = Task { @MainActor [weak self] in
      async let preparedCommands = CorpusAgentSkillCatalog.prepareCommands(
        in: root,
        force: force,
        discoveryThreadObserver: observer
      )
      async let preparedSkills = Task.detached(priority: .utility) {
        WorkspaceSkillCatalog.discover(in: root)
      }.value
      let (commands, skills) = await (preparedCommands, preparedSkills)
      guard let self,
            !Task.isCancelled,
            self.corpusAgentSkillRefreshGeneration == generation,
            self.isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      self.corpusAgentSkillCommands = commands
      self.workspaceSkills = skills
      self.corpusAgentSkillLoadedCorpusPath = rootPath
      self.corpusAgentSkillRefreshCorpusPath = nil
      if let selectedID = self.selectedWorkspaceSkillID,
         !skills.contains(where: { $0.id == selectedID }) {
        self.selectedWorkspaceSkillID = nil
      }
      self.corpusAgentSkillRefreshTask = nil
    }
  }

  func waitForCorpusAgentSkillRefreshForTesting() async {
    while let task = corpusAgentSkillRefreshTask {
      let generation = corpusAgentSkillRefreshGeneration
      await task.value
      await Task.yield()
      if corpusAgentSkillRefreshGeneration == generation,
         corpusAgentSkillRefreshTask == nil {
        return
      }
    }
  }

  public func selectWorkspaceSkill(_ skill: WorkspaceSkillItem) {
    selectedWorkspaceSkillID = skill.id
    openWorkspaceSkillFile(at: URL(fileURLWithPath: skill.sourcePath))
  }

  private func openWorkspaceSkillFile(at rawURL: URL) {
    let url = rawURL.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    selectCorpusFile(CorpusFile(
      path: url.path,
      relativePath: relativePath(url.path),
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    ), surface: .skills)
  }

  @discardableResult
  public func createWorkspaceSkill(name rawName: String, description: String) -> Bool {
    guard let corpusRoot else { return false }
    let rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let name = WorkspaceSkillCatalog.normalizedSkillName(rawName)
    guard !name.isEmpty, name == rawName else {
      errorText = "Use lowercase letters, digits, and hyphens for the skill name."
      statusText = "Invalid skill name"
      return false
    }
    guard name != "org2" else {
      errorText = "The name org2 is reserved for Celorga's built-in operating guidance."
      statusText = "Reserved skill name"
      return false
    }
    let summary = description
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !summary.isEmpty else {
      errorText = "Add a short description of when the skill should be used."
      statusText = "Skill description required"
      return false
    }
    let skillsRoot = corpusRoot
      .appendingPathComponent(".agents", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let directory = skillsRoot.appendingPathComponent(name, isDirectory: true)
    let destination = directory.appendingPathComponent("SKILL.md")
    do {
      try assertSafeWorkspaceSkillParents(corpusRoot: corpusRoot, target: skillsRoot)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        errorText = "A workspace skill named \(name) already exists."
        statusText = "Skill already exists"
        return false
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try assertSafeWorkspaceSkillParents(corpusRoot: corpusRoot, target: directory)
      let source = WorkspaceSkillCatalog.newSkillSource(name: name, description: summary)
      try Data(source.utf8).write(to: destination, options: .withoutOverwriting)
      selectedWorkspaceSkillID = destination.standardizedFileURL.path
      openWorkspaceSkillFile(at: destination)
      refreshCorpusAgentSkills(force: true)
      statusText = "Created /\(name)"
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not create the skill"
      return false
    }
  }

  public func moveWorkspaceSkillToTrash(_ skill: WorkspaceSkillItem) async {
    guard let corpusRoot else { return }
    let skillsRoot = corpusRoot
      .appendingPathComponent(".agents", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
      .standardizedFileURL
    let skillFile = URL(fileURLWithPath: skill.sourcePath).standardizedFileURL
    let directory = skillFile.deletingLastPathComponent()
    guard skillFile.lastPathComponent == "SKILL.md",
          directory.deletingLastPathComponent() == skillsRoot
    else {
      errorText = "Only top-level workspace skill folders can be removed."
      statusText = "Skill could not be removed"
      return
    }
    do {
      let removesSelectedDetail = selectedLocation?.file == skillFile.path
      if removesSelectedDetail {
        persistLiveFileEditorDraftBeforeNavigation()
        guard await awaitPendingEditorPersistence() else {
          statusText = "Save the current skill before removing it"
          return
        }
      }
      var resultingURL: NSURL?
      try FileManager.default.trashItem(at: directory, resultingItemURL: &resultingURL)
      if removesSelectedDetail {
        clearDetailForNavigation()
      }
      if selectedWorkspaceSkillID == skill.id { selectedWorkspaceSkillID = nil }
      if removesSelectedDetail {
        isWorkspaceSurfacePaneClosed = false
        isWorkspaceDetailPaneClosed = true
        activeWorkspacePane = .surface
      }
      refreshCorpusAgentSkills(force: true)
      statusText = "Moved /\(skill.name) to Trash"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not move the skill to Trash"
    }
  }

  private func assertSafeWorkspaceSkillParents(corpusRoot: URL, target: URL) throws {
    let root = corpusRoot.standardizedFileURL
    let target = target.standardizedFileURL
    guard target.path.hasPrefix(root.path + "/.agents") else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
    }
    var current = root
    let components = target.pathComponents.dropFirst(root.pathComponents.count)
    for component in components {
      current.appendPathComponent(component, isDirectory: true)
      guard FileManager.default.fileExists(atPath: current.path) else { continue }
      let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: current.path])
      }
    }
  }

  public var aiChatCommandDiscoveryID: String {
    let agentID = OpenClawChatClient.openClawAgentHeaderValue(for: openClawAgentID)
    return "\(openClawEndpointText.trimmingCharacters(in: .whitespacesAndNewlines))#\(agentID)"
  }

  public func refreshAIChatCommands(force: Bool = false) async {
    // Documentation screenshots use a synthetic corpus and must remain fully
    // deterministic. In particular, do not let SwiftUI's chat-view task prompt
    // for the developer's real Keychain token or contact a live Gateway while
    // the offscreen renderer is taking a snapshot.
    if CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_CORPUS") != nil {
      openClawGatewayCommands = []
      isRefreshingAIChatCommands = false
      return
    }

    let discoveryID = aiChatCommandDiscoveryID
    let now = Date()
    if aiChatActiveCommandDiscoveryID != discoveryID {
      aiChatActiveCommandDiscoveryID = discoveryID
      openClawGatewayCommands = aiChatCommandCache[discoveryID]?.commands ?? []
    }
    if !force,
       let cached = aiChatCommandCache[discoveryID],
       now.timeIntervalSince(cached.refreshedAt) < 300 {
      openClawGatewayCommands = cached.commands
      return
    }

    aiChatCommandDiscoveryGeneration += 1
    let generation = aiChatCommandDiscoveryGeneration
    isRefreshingAIChatCommands = true
    defer {
      if generation == aiChatCommandDiscoveryGeneration {
        isRefreshingAIChatCommands = false
      }
    }

    do {
      let settings = currentOpenClawSettings(allowKeychainRead: true)
      let agentID = OpenClawChatClient.openClawAgentHeaderValue(for: openClawAgentID)
      let commands = try await OpenClawGatewayClient(settings: settings).listCommands(agentID: agentID)
      aiChatCommandCache[discoveryID] = (commands, now)
      guard generation == aiChatCommandDiscoveryGeneration,
            discoveryID == aiChatCommandDiscoveryID
      else { return }
      openClawGatewayCommands = commands
    } catch {
      // Discovery is an enhancement. Keep a previously fetched catalog when the
      // Gateway is temporarily unavailable and let command execution report its
      // own authoritative error when the user actually sends one.
    }
  }

  public func saveOrgCryptConfiguration(
    encryptOnSave: Bool,
    recipientsText: String,
    recipientFilesText: String,
    useDefaultGpgKey: Bool,
    gpgProgram: String,
    passphrase: String,
    clearPassphrase: Bool
  ) -> Bool {
    let recipients = OrgCryptSettings.splitListText(recipientsText)
    let recipientFiles = OrgCryptSettings.splitListText(recipientFilesText)
    let normalizedGpgProgram = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "gpg"
      : gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      defaults.set(encryptOnSave, forKey: orgCryptEncryptOnSaveKey)
      defaults.set(recipients, forKey: orgCryptRecipientsKey)
      defaults.set(recipientFiles, forKey: orgCryptRecipientFilesKey)
      defaults.set(useDefaultGpgKey, forKey: orgCryptUseDefaultGpgKeyKey)
      defaults.set(normalizedGpgProgram, forKey: orgCryptGpgProgramKey)

      orgCryptEncryptOnSave = encryptOnSave
      orgCryptRecipientsText = OrgCryptSettings.listText(recipients)
      orgCryptRecipientFilesText = OrgCryptSettings.listText(recipientFiles)
      orgCryptUseDefaultGpgKey = useDefaultGpgKey
      orgCryptGpgProgram = normalizedGpgProgram

      if clearPassphrase {
        try OrgCryptKeychain.deletePassphrase()
        orgCryptHasStoredPassphrase = false
      } else if !passphrase.isEmpty {
        try OrgCryptKeychain.savePassphrase(passphrase)
        orgCryptHasStoredPassphrase = true
      } else {
        orgCryptHasStoredPassphrase = OrgCryptKeychain.containsPassphrase()
      }

      orgCryptStatusText = orgCryptStatusText(settings: currentOrgCryptSettings())
      statusText = "Encryption settings saved"
      return true
    } catch {
      orgCryptStatusText = error.localizedDescription
      errorText = error.localizedDescription
      return false
    }
  }

  public var orgCryptPublicKeysDirectoryURL: URL? {
    corpusRoot?.appendingPathComponent(Self.orgCryptPublicKeysDirectoryName, isDirectory: true)
  }

  public func refreshOrgCryptManagedRecipientFiles() {
    orgCryptRecipientRefreshGeneration &+= 1
    let generation = orgCryptRecipientRefreshGeneration
    orgCryptRecipientRefreshTask?.cancel()
    guard let corpusRoot else {
      orgCryptManagedRecipientFiles = []
      orgCryptRecipientRefreshTask = nil
      return
    }
    let root = corpusRoot.standardizedFileURL
    let sessionGeneration = corpusSessionGeneration
    let observer = orgCryptRecipientScanForTesting
    orgCryptRecipientRefreshTask = Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) {
        observer?(Self.currentThreadIsMainForTesting())
        do {
          return OrgCryptRecipientScanResult.success(
            try Self.scanOrgCryptManagedRecipientFiles(corpusRoot: root)
          )
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      guard let self,
            !Task.isCancelled,
            self.orgCryptRecipientRefreshGeneration == generation,
            self.isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      switch result {
      case .success(let files):
        self.orgCryptManagedRecipientFiles = files
      case .failure(let message):
        self.orgCryptManagedRecipientFiles = []
        self.orgCryptStatusText = message
      }
      self.orgCryptRecipientRefreshTask = nil
    }
  }

  func waitForOrgCryptRecipientRefreshForTesting() async {
    await orgCryptRecipientRefreshTask?.value
  }

  nonisolated public static func scanOrgCryptManagedRecipientFiles(corpusRoot: URL) throws -> [OrgCryptRecipientFile] {
    let root = corpusRoot.standardizedFileURL
    let directory = root.appendingPathComponent(orgCryptPublicKeysDirectoryName, isDirectory: true)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    .map { url in
      let standardized = url.standardizedFileURL
      return OrgCryptRecipientFile(
        path: standardized.path,
        relativePath: Self.relativePath(for: standardized.path, root: root)
      )
    }
    .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
  }

  @discardableResult
  public func importOrgCryptAgentPublicKey(from sourceURL: URL) throws -> OrgCryptRecipientFile {
    guard let corpusRoot else {
      throw OrgCryptPublicKeyImportError.missingCorpusRoot
    }

    let fileManager = FileManager.default
    let source = sourceURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw OrgCryptPublicKeyImportError.invalidSource
    }

    let destinationDirectory = corpusRoot.standardizedFileURL
      .appendingPathComponent(Self.orgCryptPublicKeysDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false).standardizedFileURL

    if source.path != destination.path {
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.copyItem(at: source, to: destination)
    }

    let imported = OrgCryptRecipientFile(
      path: destination.path,
      relativePath: Self.relativePath(for: destination.path, root: corpusRoot.standardizedFileURL)
    )
    if !orgCryptManagedRecipientFiles.contains(where: { $0.path == imported.path }) {
      orgCryptManagedRecipientFiles.append(imported)
      orgCryptManagedRecipientFiles.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    refreshOrgCryptManagedRecipientFiles()
    orgCryptStatusText = "Added \(imported.name) to public keys"
    return imported
  }

  public func chooseOrgCryptAgentPublicKey() -> OrgCryptRecipientFile? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose an agent public key to copy into public-keys"

    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      return try importOrgCryptAgentPublicKey(from: url)
    } catch {
      orgCryptStatusText = error.localizedDescription
      errorText = error.localizedDescription
      return nil
    }
  }

  public func normalizedOrgCryptRecipientFilePath(_ rawPath: String) -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if NSString(string: trimmed).isAbsolutePath {
      return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
    guard let corpusRoot else { return trimmed }
    return corpusRoot.standardizedFileURL.appendingPathComponent(trimmed).standardizedFileURL.path
  }

  public func selectedManagedOrgCryptRecipientFilePaths(in recipientFilesText: String) -> Set<String> {
    let managed = Set(orgCryptManagedRecipientFiles.map(\.path))
    return Set(OrgCryptSettings.splitListText(recipientFilesText)
      .map { normalizedOrgCryptRecipientFilePath($0) }
      .filter { managed.contains($0) })
  }

  public func manualOrgCryptRecipientFilesText(from recipientFilesText: String) -> String {
    let managed = Set(orgCryptManagedRecipientFiles.map(\.path))
    let manual = OrgCryptSettings.splitListText(recipientFilesText)
      .filter { !managed.contains(normalizedOrgCryptRecipientFilePath($0)) }
    return OrgCryptSettings.listText(manual)
  }

  public func combinedOrgCryptRecipientFilesText(
    manualText: String,
    selectedManagedPaths: Set<String>
  ) -> String {
    var seen = Set<String>()
    var values: [String] = []
    for value in OrgCryptSettings.splitListText(manualText) {
      if seen.insert(normalizedOrgCryptRecipientFilePath(value)).inserted {
        values.append(value)
      }
    }
    for path in selectedManagedPaths.sorted() {
      let normalized = normalizedOrgCryptRecipientFilePath(path)
      if !normalized.isEmpty, seen.insert(normalized).inserted {
        values.append(normalized)
      }
    }
    return OrgCryptSettings.listText(values)
  }

  public func presentOrgCryptConfiguration() {
    isOrgCryptConfigurationPresented = true
  }

  /// Decrypts the armored block at `line` into a temporary sheet without
  /// modifying the document, so nothing ever needs to be re-encrypted.
  public func peekOrgCrypt(line explicitLine: Int? = nil) async {
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      statusText = "Open a file before viewing encrypted text"
      return
    }
    let line = explicitLine ?? selectedBlock?.startLine ?? selectedLocation?.lineForEditor ?? 1

    let text: String
    let baseLine: Int
    if let source = selectedEntrySource,
       source.file == file,
       line >= source.startLine,
       !source.isSubtree || line < source.endLineExclusive {
      text = source.text
      baseLine = source.startLine
    } else if let diskText = try? String(contentsOfFile: NSString(string: file).expandingTildeInPath, encoding: .utf8) {
      text = diskText
      baseLine = 1
    } else {
      statusText = "Could not read \(relativePath(file))"
      return
    }

    guard let target = OrgCrypt.peekTarget(in: text, line: line, baseLine: baseLine) else {
      statusText = "No encrypted text found at \(relativePath(file)):\(line)"
      return
    }

    let peek = OrgCryptPeek(file: file, headingLine: target.headingLine, title: target.title, state: .decrypting)
    orgCryptPeek = peek
    let settings = await currentOrgCryptSettingsForOperation()
    let armor = target.armor
    let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
      Result { try OrgCrypt.decryptArmor(armor, settings: settings) }
    }.value
    // The sheet may have been closed (or replaced) while gpg was running;
    // in that case discard the plaintext instead of resurrecting it.
    guard orgCryptPeek?.id == peek.id else { return }
    switch result {
    case .success(let plaintext):
      orgCryptPeek?.state = .decrypted(plaintext)
    case .failure(let error):
      orgCryptPeek?.state = .failed(error.localizedDescription)
    }
  }

  public func dismissOrgCryptPeek() {
    orgCryptPeek = nil
  }

  /// Escape hatch from the peek sheet for when the user really does want to
  /// edit: the old in-file decrypt, which re-encrypts on save.
  public func decryptPeekedSubtreeInFile() async {
    guard let peek = orgCryptPeek else { return }
    orgCryptPeek = nil
    _ = await runOrgCrypt(.decrypt, line: peek.headingLine)
  }

  @discardableResult
  public func runOrgCrypt(_ action: OrgCryptAction, line explicitLine: Int? = nil) async -> OrgCryptRunResult {
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      let message = "Open a file before running encryption"
      statusText = message
      return .failure(message: message)
    }

    let line = explicitLine ?? selectedBlock?.startLine ?? selectedLocation?.lineForEditor ?? 1
    let settings = await currentOrgCryptSettingsForOperation()
    orgCryptStatusText = "\(action.title) running \(relativePath(file)):\(line)"
    statusText = orgCryptStatusText
    var arguments = [
      "crypt",
      action.rawValue,
      "--file",
      file,
      "--line",
      "\(line)",
      "--gpg-program",
      settings.gpgProgram,
      "--gpg-timeout",
      "\(settings.gpgTimeout)",
      "--format",
      "json",
      "--apply"
    ]
    if let passphrase = settings.passphrase {
      arguments += ["--passphrase", passphrase]
    }
    if settings.useDefaultGpgKey {
      arguments += ["--default-recipient-self"]
    }
    for recipient in settings.recipients {
      arguments += ["--recipient", recipient]
    }
    for recipientFile in settings.recipientFiles {
      arguments += ["--recipient-file", recipientFile]
    }

    do {
      guard let context = captureDocumentCorpusContext(forFile: file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(
          file: file,
          root: corpusRoot?.path ?? "(none)"
        )
      }
      let cli = self.cli
      let cryptArguments = arguments
      let result = try await performDocumentMutation(context: context, files: [file]) { _ in
        try await cli.runJSON(cryptArguments, as: OrgCryptCLIPayload.self)
      }
      guard isCurrentDocumentCorpusContext(context) else {
        return .failure(message: "The active corpus changed", headingLine: line)
      }
      invalidateCanonicalDocumentCache(for: file)
      resetBlockEditing()
      isEditingEntry = false
      let succeeded = action == .decrypt ? result.changed : true
      orgCryptStatusText = "\(action.title) \(result.changed ? "updated" : "made no changes") \(relativePath(file)):\(result.headingLine)"
      statusText = orgCryptStatusText
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      if succeeded {
        return .success(changed: result.changed, headingLine: result.headingLine, message: orgCryptStatusText)
      }
      return .failure(message: orgCryptStatusText, headingLine: result.headingLine)
    } catch {
      errorText = error.localizedDescription
      orgCryptStatusText = error.localizedDescription
      statusText = error.localizedDescription
      return .failure(message: error.localizedDescription, headingLine: line)
    }
  }

  // MARK: Secret requests

  /// Reloads pending `celorga secret request` envelopes and presents the
  /// oldest one the person has not deferred this session.
  func refreshSecretRequests() async {
    guard let corpusRoot else {
      pendingSecretRequests = []
      activeSecretRequest = nil
      return
    }
    let root = corpusRoot.standardizedFileURL
    let generation = corpusSessionGeneration
    let scan = await Task.detached(priority: .utility) {
      SecretRequestQueue.loadPending(corpusRoot: root)
    }.value
    guard isCurrentCorpusSession(root: root, generation: generation) else { return }
    pendingSecretRequests = scan.requests
    if let error = scan.errors.first {
      errorText = "Ignored a secret request: \(error)"
    }
    if let active = activeSecretRequest, !scan.requests.contains(where: { $0.id == active.id }) {
      activeSecretRequest = nil
      secretRequestErrorText = nil
    }
    if activeSecretRequest == nil, !isSubmittingSecretRequest {
      activeSecretRequest = scan.requests.first { !deferredSecretRequestIDs.contains($0.id) }
    }
  }

  public func presentPendingSecretRequests() {
    deferredSecretRequestIDs.removeAll()
    if activeSecretRequest == nil {
      activeSecretRequest = pendingSecretRequests.first
    }
  }

  public func deferSecretRequest(_ request: SecretRequest) {
    deferredSecretRequestIDs.insert(request.id)
    secretRequestErrorText = nil
    activeSecretRequest = pendingSecretRequests.first { !deferredSecretRequestIDs.contains($0.id) }
    statusText = "\(request.authorLabel)'s request for \(request.name) is still pending"
  }

  public func secretRequestThreadTitle(_ request: SecretRequest) -> String? {
    guard let raw = request.threadID, let id = UUID(uuidString: raw) else { return nil }
    return aiChatThreads.first(where: { $0.id == id })?.title
  }

  public func secretRequestRecipientSummary(_ request: SecretRequest) -> String {
    let options = SecretSealOptions(settings: currentOrgCryptSettings())
    var parts: [String] = []
    if options.useDefaultGpgKey {
      parts.append("your default GPG key")
    }
    for entry in request.recipients.entries {
      let label = entry.source == "request" ? "\(entry.value) (requested)" : entry.value
      if !parts.contains(label) { parts.append(label) }
    }
    for value in options.recipients + options.recipientFiles where !parts.contains(value) {
      parts.append(value)
    }
    return parts.isEmpty ? "No recipients are configured" : parts.joined(separator: ", ")
  }

  private var secretSealer: any SecretSealing {
    secretSealerForTesting ?? CLISecretSealer(cli: cli)
  }

  /// Seals the typed value with GPG into the corpus secrets file. Only
  /// ciphertext reaches disk; the value is never logged or posted to a thread.
  @discardableResult
  public func submitSecretRequest(_ request: SecretRequest, value: String) async -> Bool {
    guard !value.isEmpty else {
      secretRequestErrorText = SecretRequestError.emptyValue.errorDescription
      return false
    }
    guard let corpusRoot else { return false }
    let root = corpusRoot.standardizedFileURL
    let file = root.appendingPathComponent(request.destination.file).standardizedFileURL.path
    guard file.hasPrefix(root.path + "/"),
          let context = captureDocumentCorpusContext(forFile: file)
    else {
      secretRequestErrorText = SecretRequestError.outsideCorpus.errorDescription
      return false
    }
    isSubmittingSecretRequest = true
    secretRequestErrorText = nil
    defer { isSubmittingSecretRequest = false }
    let options = SecretSealOptions(settings: currentOrgCryptSettings())
    let sealer = secretSealer
    let payload = Data(value.utf8)
    do {
      let result = try await performDocumentMutation(context: context, files: [file]) { _ in
        try await sealer.fulfill(request, value: payload, options: options, corpusRoot: root)
      }
      guard isCurrentDocumentCorpusContext(context) else { return false }
      invalidateCanonicalDocumentCache(for: file)
      pendingSecretRequests.removeAll { $0.id == request.id }
      deferredSecretRequestIDs.remove(request.id)
      activeSecretRequest = pendingSecretRequests.first { !deferredSecretRequestIDs.contains($0.id) }
      statusText = "Encrypted \(result.name) into \(result.file)"
      if let selectedLocation, selectedLocation.file == file {
        await loadEntrySource(for: selectedLocation)
      }
      return true
    } catch {
      secretRequestErrorText = error.localizedDescription
      return false
    }
  }

  public func declineSecretRequest(_ request: SecretRequest) async {
    guard let corpusRoot else { return }
    isSubmittingSecretRequest = true
    defer { isSubmittingSecretRequest = false }
    do {
      try await secretSealer.decline(request, corpusRoot: corpusRoot.standardizedFileURL)
      pendingSecretRequests.removeAll { $0.id == request.id }
      secretRequestErrorText = nil
      activeSecretRequest = pendingSecretRequests.first { !deferredSecretRequestIDs.contains($0.id) }
      statusText = "Declined \(request.authorLabel)'s request for \(request.name)"
    } catch {
      secretRequestErrorText = error.localizedDescription
    }
  }

  func rebuildAgendaDisplayCache() {
    agendaDisplaySections = Self.makeAgendaDisplaySections(
      agenda: agenda,
      mode: agendaMode,
      overdueOrder: agendaOverdueOrder,
      filter: agendaFilter,
      dateFilter: agendaDateFilter,
      assigneeFilter: agendaAssigneeFilter,
      statusFilter: agendaStatusFilter,
      priorityFilter: agendaPriorityFilter,
      topicFilter: agendaTopicFilter,
      buckets: agendaDisplayBuckets,
      filterTextByItemID: agendaFilterTextByItemID
    )
    visibleAgendaItems = agendaDisplaySections.flatMap(\.items)
  }

  /// Corpus-scale run projection building is deliberately detached from
  /// observation publication. A large run archive otherwise turns assigning
  /// one CLI response (and each filter keystroke) into a long MainActor stall.
  func scheduleAgentRunProjectionRefresh(debounce: Bool = false) {
    agentRunProjectionGeneration &+= 1
    let generation = agentRunProjectionGeneration
    agentRunProjectionTask?.cancel()

    // Keep tiny fixtures and single-run lifecycle mutations immediately
    // coherent without paying task scheduling overhead. Real archives use the
    // detached path below.
    guard agentRuns.count > 256 else {
      publishAgentRunProjection(Self.agentRunProjection(
        runs: agentRuns,
        filterTerms: agentRunFilterTerms
      )!)
      agentRunProjectionTask = nil
      return
    }

    let runs = agentRuns
    let terms = agentRunFilterTerms
    let revision = agentRunsRevision
    // A filter keystroke over an unchanged archive reuses the per-run indexes;
    // only the cheap term match and section grouping run again.
    let indexes = agentRunProjectionIndexes?.revision == revision
      ? agentRunProjectionIndexes?.box
      : nil
    let preparation = agentRunProjectionPreparationForTesting
    let didBuild = agentRunProjectionDidBuildForTesting
    agentRunProjectionTask = Task { @MainActor [weak self] in
      if debounce {
        do {
          try await Task.sleep(nanoseconds: 80_000_000)
        } catch {
          return
        }
      }
      let build = Task.detached(priority: .userInitiated) { () -> AgentRunProjectionBox? in
        if let preparation { await preparation() }
        let projection: AgentRunProjectionBox?
        if let indexes {
          projection = Self.agentRunProjection(reusing: indexes, filterTerms: terms, checksCancellation: true)
        } else {
          projection = Self.agentRunProjection(runs: runs, filterTerms: terms, checksCancellation: true)
        }
        guard let projection else { return nil }
        didBuild?(projection.wasBuiltOnMainThread)
        return projection
      }
      // Superseded keystrokes cancel their build instead of competing with
      // the current one for CPU.
      let projection = await withTaskCancellationHandler {
        await build.value
      } onCancel: {
        build.cancel()
      }
      guard let self,
            let projection,
            !Task.isCancelled,
            self.agentRunProjectionGeneration == generation,
            self.agentRunsRevision == revision,
            self.agentRunFilterTerms == terms
      else { return }
      self.publishAgentRunProjection(projection, runsRevision: revision)
      self.agentRunProjectionTask = nil
    }
  }

  /// Builds the complete projection. Returns nil only when `checksCancellation`
  /// is set and the surrounding task is canceled.
  nonisolated static func agentRunProjection(
    runs: [AgentRunItem],
    filterTerms: [String],
    checksCancellation: Bool = false
  ) -> AgentRunProjectionBox? {
    var filterTextByID: [AgentRunItem.ID: String] = [:]
    var runsByID: [AgentRunItem.ID: AgentRunItem] = [:]
    var countByGoalRef: [String: Int] = [:]
    var countByAgentRef: [String: Int] = [:]
    filterTextByID.reserveCapacity(runs.count)
    runsByID.reserveCapacity(runs.count)
    for (index, run) in runs.enumerated() {
      if checksCancellation, index % 256 == 0, Task.isCancelled { return nil }
      filterTextByID[run.id] = run.runFilterText
      runsByID[run.id] = run
      if let goalRef = run.goalRef { countByGoalRef[goalRef, default: 0] += 1 }
      if let agentRef = run.agentRef { countByAgentRef[agentRef, default: 0] += 1 }
    }

    var scopeCounts: [AgentRunScope: Int] = [:]
    var scopeEntries: [AgentRunScope: [AgentRunScopeEntry]] = [:]
    let sourceMeetingContexts = RunCenterPresentation.sourceMeetingContextsByRunID(in: runs)
    var runIDsBySourceMeetingReference: [String: [AgentRunItem.ID]] = [:]
    runIDsBySourceMeetingReference.reserveCapacity(min(sourceMeetingContexts.count, 32))
    for run in runs {
      guard let context = sourceMeetingContexts[run.id] else { continue }
      let reference = context.fileReference ?? context.ref
      runIDsBySourceMeetingReference[reference, default: []].append(run.id)
    }

    for scope in AgentRunScope.allCases {
      let entries = scope.entries(in: runs)
      scopeEntries[scope] = entries
      scopeCounts[scope] = entries.count
    }

    let indexes = AgentRunProjectionBox(
      filterTextByID: filterTextByID,
      runsByID: runsByID,
      countByGoalRef: countByGoalRef,
      countByAgentRef: countByAgentRef,
      scopeCounts: scopeCounts,
      scopeEntries: scopeEntries,
      filteredScopeEntries: [:],
      filteredScopeIDs: [:],
      filteredScopeIDSets: [:],
      sectionsByScope: [:],
      sourceMeetingContextsByID: sourceMeetingContexts,
      runIDsBySourceMeetingReference: runIDsBySourceMeetingReference,
      wasBuiltOnMainThread: Thread.isMainThread
    )
    guard let projection = agentRunProjection(
      reusing: indexes,
      filterTerms: filterTerms,
      checksCancellation: checksCancellation
    ) else {
      return nil
    }
    projection.reusedRunIndexes = false
    return projection
  }

  /// Applies `filterTerms` to run-derived indexes that are already built.
  /// Returns nil only when `checksCancellation` is set and the surrounding
  /// task is canceled.
  nonisolated static func agentRunProjection(
    reusing indexes: AgentRunProjectionBox,
    filterTerms: [String],
    checksCancellation: Bool = false
  ) -> AgentRunProjectionBox? {
    var filteredEntries: [AgentRunScope: [AgentRunScopeEntry]] = [:]
    var filteredIDs: [AgentRunScope: [AgentRunItem.ID]] = [:]
    var filteredIDSets: [AgentRunScope: Set<AgentRunItem.ID>] = [:]
    var sectionsByScope: [AgentRunScope: [RunCenterSection]] = [:]

    for scope in AgentRunScope.allCases {
      if checksCancellation, Task.isCancelled { return nil }
      let entries = indexes.scopeEntries[scope] ?? []
      let visibleEntries = filterTerms.isEmpty
        ? entries
        : entries.filter { entry in
          let text = indexes.filterTextByID[entry.id] ?? entry.run.runFilterText
          return filterTerms.allSatisfy { text.contains($0) }
        }
      filteredEntries[scope] = visibleEntries
      let visibleIDs = visibleEntries.map(\.id)
      filteredIDs[scope] = visibleIDs
      filteredIDSets[scope] = Set(visibleIDs)
      sectionsByScope[scope] = RunCenterPresentation.sections(
        for: visibleEntries,
        sourceMeetingContexts: indexes.sourceMeetingContextsByID
      )
    }

    let projection = AgentRunProjectionBox(
      filterTextByID: indexes.filterTextByID,
      runsByID: indexes.runsByID,
      countByGoalRef: indexes.countByGoalRef,
      countByAgentRef: indexes.countByAgentRef,
      scopeCounts: indexes.scopeCounts,
      scopeEntries: indexes.scopeEntries,
      filteredScopeEntries: filteredEntries,
      filteredScopeIDs: filteredIDs,
      filteredScopeIDSets: filteredIDSets,
      sectionsByScope: sectionsByScope,
      sourceMeetingContextsByID: indexes.sourceMeetingContextsByID,
      runIDsBySourceMeetingReference: indexes.runIDsBySourceMeetingReference,
      wasBuiltOnMainThread: Thread.isMainThread
    )
    projection.reusedRunIndexes = true
    return projection
  }

  func publishAgentRunProjection(
    _ projection: AgentRunProjectionBox,
    runsRevision: UInt64? = nil
  ) {
    agentRunProjectionIndexes = (runsRevision ?? agentRunsRevision, projection)
    if projection.reusedRunIndexes {
      agentRunProjectionIndexReuseCountForTesting &+= 1
    }
    agentRunProjectionBuildCountForTesting &+= 1
    if projection.wasBuiltOnMainThread {
      agentRunProjectionMainThreadBuildCountForTesting &+= 1
    }
    agentRunFilterTextByID = projection.filterTextByID
    agentRunsByID = projection.runsByID
    agentRunCountByGoalRef = projection.countByGoalRef
    agentRunCountByAgentRef = projection.countByAgentRef
    agentRunScopeCounts = projection.scopeCounts
    agentRunScopeEntriesByScope = projection.scopeEntries
    filteredAgentRunScopeEntries = projection.filteredScopeEntries
    filteredAgentRunScopeIDs = projection.filteredScopeIDs
    filteredAgentRunScopeIDSets = projection.filteredScopeIDSets
    agentRunSectionsByScope = projection.sectionsByScope
    agentRunSourceMeetingContextsByID = projection.sourceMeetingContextsByID
    agentRunIDsBySourceMeetingReference = projection.runIDsBySourceMeetingReference
    agentRunDisplayRevision &+= 1
  }

  func waitForAgentRunProjectionForTesting() async {
    await agentRunProjectionTask?.value
  }

  func rebuildAgendaSearchIndex() {
    guard let agenda else {
      agendaFilterTextByItemID = [:]
      agendaDisplayBuckets = AgendaDisplayBuckets()
      rebuildAgendaFilterOptions()
      return
    }
    let next7End = Self.isoDate(
      Calendar(identifier: .gregorian).date(
        byAdding: .day,
        value: 7,
        to: Self.dateFromISO(agenda.range.start) ?? Date()
      ) ?? Date()
    )
    agendaDisplayBuckets = AgendaDisplayBuckets(
      overdue: agenda.overdue.flatMap(\.items),
      today: agenda.days.filter { $0.date == agenda.range.start }.flatMap(\.items),
      next7: agenda.days
        .filter { $0.date > agenda.range.start && $0.date <= next7End }
        .flatMap(\.items),
      later: agenda.days
        .filter { $0.date > next7End }
        .flatMap(\.items)
    )
    var index: [AgendaItem.ID: String] = [:]
    let items = agendaDisplayBuckets.overdue
      + agendaDisplayBuckets.today
      + agendaDisplayBuckets.next7
      + agendaDisplayBuckets.later
    index.reserveCapacity(items.count)
    for item in items {
      index[item.id] = item.agendaFilterText
    }
    agendaFilterTextByItemID = index
    rebuildAgendaFilterOptions()
  }

  func rebuildAgendaFilterOptions() {
    let agendaItems = agendaDisplayBuckets.overdue
      + agendaDisplayBuckets.today
      + agendaDisplayBuckets.next7
      + agendaDisplayBuckets.later
    let agendaAssignees = agendaItems.compactMap {
      Self.propertyValue("ASSIGNEE", in: $0.properties)
    }
    let agendaStatuses = agendaItems.flatMap { item in
      [item.todo, Self.propertyValue("STATUS", in: item.properties)].compactMap { $0 }
    }
    let agendaPriorities = agendaItems.compactMap { item in
      item.priority ?? Self.propertyValue("PRIORITY", in: item.properties)
    }
    let assignedStatuses = assignedWorkItems.flatMap { item in
      [item.todo, item.status, Self.propertyValue("STATUS", in: item.properties)].compactMap { $0 }
    }
    let assignedPriorities = assignedWorkItems.compactMap {
      Self.propertyValue("PRIORITY", in: $0.properties)
    }

    agendaAssigneeFilterOptions = Self.sortedUniqueFacetValues(
      agendaAssignees + assignedWorkItems.map(\.assignee)
    )
    agendaStatusFilterOptions = Self.sortedUniqueFacetValues(agendaStatuses + assignedStatuses)
    agendaPriorityFilterOptions = Self.sortedUniqueFacetValues(agendaPriorities + assignedPriorities)
    agendaTopicFilterOptions = Self.sortedUniqueFacetValues(
      agendaItems.flatMap(\.tags) + assignedWorkItems.flatMap(\.tags)
    )
  }

  nonisolated private static func sortedUniqueFacetValues(_ values: [String]) -> [String] {
    var displayByNormalizedValue: [String: String] = [:]
    for value in values {
      let display = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !display.isEmpty else { continue }
      let normalized = display.lowercased()
      if displayByNormalizedValue[normalized] == nil {
        displayByNormalizedValue[normalized] = display
      }
    }
    return displayByNormalizedValue.values.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  nonisolated static func propertyValue(
    _ key: String,
    in properties: [String: String]
  ) -> String? {
    properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
  }

  private static func makeAgendaDisplaySections(
    agenda: AgendaPayload?,
    mode: AgendaMode,
    overdueOrder: AgendaOverdueOrder,
    filter: String,
    dateFilter: AgendaDateFilter,
    assigneeFilter: String,
    statusFilter: String,
    priorityFilter: String,
    topicFilter: String,
    buckets: AgendaDisplayBuckets,
    filterTextByItemID: [AgendaItem.ID: String]
  ) -> [AgendaDisplaySection] {
    guard agenda != nil else { return [] }
    let terms = filterTerms(from: filter)
    let matchesFilter: (AgendaItem) -> Bool = { item in
      guard matchesAgendaStructuredFilters(
        item,
        assignee: assigneeFilter,
        status: statusFilter,
        priority: priorityFilter,
        topic: topicFilter
      ) else { return false }
      guard !terms.isEmpty else { return true }
      let searchText = filterTextByItemID[item.id] ?? item.agendaFilterText
      return terms.allSatisfy { searchText.contains($0) }
    }
    let overdue = sortedOverdueItems(
      (dateFilter == .any || dateFilter == .overdue ? buckets.overdue : []).filter(matchesFilter),
      order: overdueOrder
    )
    let today = (dateFilter == .any || dateFilter == .today ? buckets.today : []).filter(matchesFilter)
    let next7 = (dateFilter == .any || dateFilter == .next7 ? buckets.next7 : []).filter(matchesFilter)
    let later = (dateFilter == .any || dateFilter == .later ? buckets.later : []).filter(matchesFilter)

    switch mode {
    case .focus:
      let todayActionable = today.filter(\.isActionable)
      let overdueActionable = overdue.filter(\.isActionable)
      let doneToday = today.filter { !$0.isActionable }
      return [
        AgendaDisplaySection(id: "focus-today", label: "Today", items: todayActionable, hint: "today"),
        AgendaDisplaySection(id: "focus-overdue", label: "Overdue", items: overdueActionable, hint: "overdue"),
        AgendaDisplaySection(id: "focus-closed", label: "Done or canceled", items: doneToday, hint: "today")
      ].filter { !$0.items.isEmpty }
    case .today:
      return [
        AgendaDisplaySection(id: "today", label: "Today", items: today, hint: "today"),
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: overdue, hint: "overdue")
      ].filter { !$0.items.isEmpty }
    case .range:
      return [
        AgendaDisplaySection(id: "overdue", label: "Overdue", items: overdue, hint: "overdue"),
        AgendaDisplaySection(id: "today", label: "Today", items: today, hint: "today"),
        AgendaDisplaySection(id: "next-7-days", label: "Next 7 days", items: next7, hint: "upcoming"),
        AgendaDisplaySection(id: "later", label: "Later", items: later, hint: "upcoming")
      ].filter { !$0.items.isEmpty }
    case .assigned:
      return []
    }
  }

  nonisolated private static func matchesAgendaStructuredFilters(
    _ item: AgendaItem,
    assignee: String,
    status: String,
    priority: String,
    topic: String
  ) -> Bool {
    let itemAssignee = propertyValue("ASSIGNEE", in: item.properties)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if assignee == agendaUnassignedFilter {
      guard itemAssignee.isEmpty else { return false }
    } else if !assignee.isEmpty,
              itemAssignee.caseInsensitiveCompare(assignee) != .orderedSame {
      return false
    }

    let todo = item.todo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let propertyStatus = propertyValue("STATUS", in: item.properties) ?? ""
    if status == agendaOpenStatusFilter {
      guard item.isActionable else { return false }
    } else if status == agendaCompletedStatusFilter {
      guard !item.isActionable else { return false }
    } else if !status.isEmpty,
              todo.caseInsensitiveCompare(status) != .orderedSame,
              propertyStatus.caseInsensitiveCompare(status) != .orderedSame {
      return false
    }

    let itemPriority = item.priority ?? propertyValue("PRIORITY", in: item.properties) ?? ""
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

  nonisolated static func sortedOverdueItems(
    _ items: [AgendaItem],
    order: AgendaOverdueOrder
  ) -> [AgendaItem] {
    guard order == .priority else { return items }

    return items.enumerated().sorted { left, right in
      let leftRank = agendaPriorityRank(left.element.priority)
      let rightRank = agendaPriorityRank(right.element.priority)
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      return left.offset < right.offset
    }.map(\.element)
  }

  nonisolated private static func agendaPriorityRank(_ rawPriority: String?) -> Int {
    guard var priority = rawPriority?.trimmingCharacters(in: .whitespacesAndNewlines),
          !priority.isEmpty
    else {
      return Int.max
    }
    if priority.hasPrefix("[#"), priority.hasSuffix("]"), priority.count == 4 {
      priority = String(priority.dropFirst(2).dropLast())
    }
    guard let scalar = priority.uppercased().unicodeScalars.first,
          priority.unicodeScalars.count == 1
    else {
      return Int.max - 1
    }
    switch scalar.value {
    case 65...90:
      return Int(scalar.value - 65)
    case 48...57:
      return 26 + Int(scalar.value - 48)
    default:
      return Int.max - 1
    }
  }

  static func filterTerms(from query: String) -> [String] {
    query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
  }

  public var visibleAgendaItemCount: Int {
    visibleAgendaItems.count
  }

  public var bulkAgendaSelectionCount: Int {
    let visibleIDs = Set(visibleAgendaItems.map(\.id))
    return bulkSelectedAgendaItemIDs.intersection(visibleIDs).count
  }

  public var hasBulkAgendaSelection: Bool {
    bulkAgendaSelectionCount > 0
  }

  public func isAgendaItemBulkSelected(_ item: AgendaItem) -> Bool {
    bulkSelectedAgendaItemIDs.contains(item.id)
  }

  public func toggleAgendaItemBulkSelection(_ item: AgendaItem) {
    guard isResultInActiveCorpus(item.corpus) else {
      statusText = "Open \(item.corpus?.name ?? "the corpus") before editing this item"
      return
    }
    var ids = bulkSelectedAgendaItemIDs
    if ids.contains(item.id) {
      ids.remove(item.id)
    } else {
      ids.insert(item.id)
    }
    bulkSelectedAgendaItemIDs = ids
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAllVisibleAgendaItemsForBulkAction() {
    let ids = Set(visibleAgendaItems.filter { isResultInActiveCorpus($0.corpus) }.map(\.id))
    bulkSelectedAgendaItemIDs = ids
    if ids.isEmpty {
      statusText = "No visible agenda items"
    } else {
      statusText = ids.count == 1 ? "1 agenda item selected" : "\(ids.count) agenda items selected"
    }
  }

  public func clearAgendaBulkSelection() {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return }
    bulkSelectedAgendaItemIDs = []
    statusText = "Agenda selection cleared"
  }

  public func handleAgendaItemClick(_ item: AgendaItem, modifiers: NSEvent.ModifierFlags = []) {
    if modifiers.intersection([.command]).contains(.command) {
      toggleAgendaItemBulkSelection(item)
      selectAgendaItem(item)
    } else {
      selectAgendaItem(item)
    }
  }

  public func extendAgendaBulkSelection(by delta: Int) {
    let items = visibleAgendaItems
    guard !items.isEmpty else {
      statusText = "No visible agenda items"
      return
    }

    let currentIndex = selectedAgendaItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }

    var ids = bulkSelectedAgendaItemIDs
    if let currentIndex {
      ids.insert(items[currentIndex].id)
    }
    ids.insert(items[nextIndex].id)
    bulkSelectedAgendaItemIDs = ids
    selectAgendaItem(items[nextIndex])
    updateAgendaBulkSelectionStatusText()
  }

  public func selectAgendaItem(_ item: AgendaItem) {
    deactivateAgendaFilterFocus()
    suppressNextAgendaSelectionActivation = false
    if activateCorpusIfNeeded(for: item.corpus, location: .agenda(item), surface: .agenda) {
      return
    }
    select(.agenda(item), surface: .agenda)
  }

  func selectAgendaItemWithoutActivatingEntry(_ item: AgendaItem) {
    suppressNextAgendaSelectionActivation = true
    selectedSurface = .agenda
    selectedAgendaItemID = item.id
    agendaSelectionAnchor = AgendaSelectionAnchor(item: item)
  }

  public func moveAgendaSelection(by delta: Int) {
    if agendaMode == .assigned {
      moveAssignedAgendaSelection(by: delta)
      return
    }
    let items = visibleAgendaItems
    guard !items.isEmpty else { return }

    let currentIndex = selectedAgendaItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }
    selectAgendaItem(items[nextIndex])
  }

  public func requestDetailScroll(_ direction: DetailScrollDirection) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      direction: direction
    )
  }

  public func requestDetailScroll(toBlock blockID: OrgEditableBlock.ID) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      target: .block(blockID)
    )
  }

  public func requestDetailReveal(toBlock blockID: OrgEditableBlock.ID) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      target: .revealBlock(blockID)
    )
  }

  public func requestDetailScroll(toSourceLine line: Int) {
    detailScrollRequest = DetailScrollRequest(
      id: (detailScrollRequest?.id ?? 0) + 1,
      target: .sourceLine(max(1, line))
    )
  }

  public func recordDocumentViewportSourceLine(
    _ line: Int?,
    for source: EntrySource? = nil
  ) {
    guard let source = source ?? selectedEntrySource,
          let line
    else {
      return
    }
    let clampedLine = Self.clampedDocumentViewportSourceLine(line, for: source)
    let key = Self.documentViewportKey(for: source)
    if let target = detailScrollRequest?.target {
      switch target {
      case .page, .sourceLine:
        detailScrollRequest = nil
      case .block, .revealBlock:
        break
      }
    }
    guard documentViewportSourceLines[key] != clampedLine
            || currentDocumentViewportSourceLine != clampedLine
    else {
      return
    }
    documentViewportSourceLines[key] = clampedLine
    currentDocumentViewportSourceLine = clampedLine
    if documentViewportSourceLines.count > Self.documentViewportSourceLinesLimit,
       let discardedKey = documentViewportSourceLines.keys.sorted().first(where: { $0 != key }) {
      documentViewportSourceLines.removeValue(forKey: discardedKey)
    }
    defaults.set(documentViewportSourceLines, forKey: documentViewportSourceLinesKey)
  }

  public func documentViewportSourceLine(for source: EntrySource) -> Int? {
    documentViewportSourceLines[Self.documentViewportKey(for: source)].map {
      Self.clampedDocumentViewportSourceLine($0, for: source)
    }
  }

  public func recordDocumentSlidePageIndex(
    _ pageIndex: Int?,
    for source: EntrySource? = nil
  ) {
    guard let source = source ?? selectedEntrySource,
          let pageIndex,
          pageIndex >= 0
    else {
      return
    }
    let key = Self.documentViewportKey(for: source)
    guard documentSlidePageIndexes[key] != pageIndex
            || currentDocumentSlidePageIndex != pageIndex
    else {
      return
    }
    documentSlidePageIndexes[key] = pageIndex
    currentDocumentSlidePageIndex = pageIndex
    if documentSlidePageIndexes.count > Self.documentViewportSourceLinesLimit,
       let discardedKey = documentSlidePageIndexes.keys.sorted().first(where: { $0 != key }) {
      documentSlidePageIndexes.removeValue(forKey: discardedKey)
    }
    defaults.set(documentSlidePageIndexes, forKey: documentSlidePageIndexesKey)
  }

  public func documentSlidePageIndex(for source: EntrySource) -> Int? {
    documentSlidePageIndexes[Self.documentViewportKey(for: source)]
  }

  nonisolated static func documentViewportKey(for source: EntrySource) -> String {
    URL(fileURLWithPath: source.file).standardizedFileURL.path
  }

  nonisolated static func clampedDocumentViewportSourceLine(
    _ line: Int,
    for source: EntrySource
  ) -> Int {
    min(max(source.startLine, line), max(source.startLine, source.endLineExclusive - 1))
  }

  nonisolated static func restoreDocumentViewportSourceLines(
    from defaults: UserDefaults,
    key: String,
    minimumValue: Int = 1
  ) -> [String: Int] {
    (defaults.dictionary(forKey: key) ?? [:]).reduce(into: [:]) { result, item in
      if let value = item.value as? Int, value >= minimumValue {
        result[item.key] = value
      } else if let value = item.value as? NSNumber, value.intValue >= minimumValue {
        result[item.key] = value.intValue
      }
    }
  }

  nonisolated static func restoreDocumentPreviewOverrides(
    from defaults: UserDefaults,
    key: String
  ) -> [String: String] {
    (defaults.dictionary(forKey: key) ?? [:]).reduce(into: [:]) { result, item in
      guard let value = item.value as? String,
            OrgDocumentPreviewPreference(rawValue: value).map({ $0 != .automatic }) == true
      else { return }
      result[item.key] = value
    }
  }

  public func selectFirstAgendaItem() {
    if agendaMode == .assigned {
      if let first = visibleAssignedWorkItems.first {
        selectAssignedWorkItem(first)
      }
      return
    }
    pruneAgendaBulkSelection()
    if let first = visibleAgendaItems.first {
      selectAgendaItem(first)
    }
  }

  public func syncAgendaSelectionAfterDisplayOptionsChange() {
    if agendaMode == .assigned {
      syncAssignedAgendaSelectionAfterDisplayOptionsChange()
      return
    }
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
    guard !items.isEmpty else { return }

    if let selectedAgendaItemID,
       let selectedItem = items.first(where: { $0.id == selectedAgendaItemID }) {
      agendaSelectionAnchor = AgendaSelectionAnchor(item: selectedItem)
      return
    }

    if let anchoredItem = agendaSelectionAnchor.flatMap({ agendaItem(matching: $0, in: items) }) {
      selectAgendaItemWithoutActivatingEntry(anchoredItem)
      return
    }

    // Filtering and other display-only changes must not silently move a user's
    // selection. Keep the intent so the highlight returns when the row is
    // visible again.
    guard selectedAgendaItemID == nil, agendaSelectionAnchor == nil else { return }

    selectAgendaItemWithoutActivatingEntry(items[0])
  }

  public func syncAssignedAgendaSelectionAfterDisplayOptionsChange() {
    guard agendaMode == .assigned else { return }
    let items = visibleAssignedWorkItems
    guard !items.isEmpty else {
      selectedAssignedWorkItemID = nil
      return
    }
    if let selectedAssignedWorkItemID,
       items.contains(where: { $0.id == selectedAssignedWorkItemID }) {
      return
    }
    selectedAssignedWorkItemID = items[0].id
  }

  public func consumeAgendaSelectionActivationSuppression() -> Bool {
    guard suppressNextAgendaSelectionActivation else { return false }
    suppressNextAgendaSelectionActivation = false
    return true
  }

  public func selectLastAgendaItem() {
    if agendaMode == .assigned {
      if let last = visibleAssignedWorkItems.last {
        selectAssignedWorkItem(last)
      }
      return
    }
    if let last = visibleAgendaItems.last {
      selectAgendaItem(last)
    }
  }

  public func moveAssignedAgendaSelection(by delta: Int) {
    let items = assignedWorkSections.flatMap(\.items)
    guard !items.isEmpty else { return }

    let currentIndex = selectedAssignedWorkItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    let nextIndex: Int
    if let currentIndex {
      nextIndex = max(0, min(items.count - 1, currentIndex + delta))
    } else {
      nextIndex = delta < 0 ? items.count - 1 : 0
    }
    selectAssignedWorkItem(items[nextIndex])
  }

  public func setAgendaModeFromKey(_ key: String) {
    if key == "1" { agendaMode = .focus }
    if key == "2" { agendaMode = .today }
    if key == "3" { agendaMode = .range }
    if key == "4" { agendaMode = .assigned }
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public func focusAgendaFilter(clearsFilter: Bool = true) {
    selectedSurface = .agenda
    if clearsFilter {
      agendaFilter = ""
    }
    agendaFilterFocusToken += 1
  }

  public func focusApprovalFilter() {
    selectedSurface = .approvals
    approvalFilterFocusToken += 1
  }

  public func focusRunsAndReviewFilter() {
    selectedSurface = .approvals
    agentRunFilterFocusToken += 1
    approvalFilterFocusToken += 1
  }

  public func clearAgentRunFilter() {
    agentRunFilter = ""
  }

  func agentRunEntries(for scope: AgentRunScope) -> [AgentRunScopeEntry] {
    filteredAgentRunScopeEntries[scope] ?? []
  }

  func agentRunIDs(for scope: AgentRunScope) -> [AgentRunItem.ID] {
    filteredAgentRunScopeIDs[scope] ?? []
  }

  func isAgentRunVisible(_ id: AgentRunItem.ID, in scope: AgentRunScope) -> Bool {
    filteredAgentRunScopeIDSets[scope]?.contains(id) == true
  }

  func agentRunSections(for scope: AgentRunScope) -> [RunCenterSection] {
    agentRunSectionsByScope[scope] ?? []
  }

  func agentRun(for id: AgentRunItem.ID) -> AgentRunItem? {
    agentRunsByID[id]
  }

  func agentRunCount(goalRef: String) -> Int {
    agentRunCountByGoalRef[goalRef, default: 0]
  }

  func agentRunCount(agentRef: String) -> Int {
    agentRunCountByAgentRef[agentRef, default: 0]
  }

  func agentRunSourceMeetingContext(for runID: AgentRunItem.ID) -> AgentRunContextItem? {
    agentRunSourceMeetingContextsByID[runID]
  }

  func relatedAgentRuns(for runID: AgentRunItem.ID) -> [AgentRunItem] {
    guard let context = agentRunSourceMeetingContextsByID[runID] else { return [] }
    let reference = context.fileReference ?? context.ref
    return agentRunIDsBySourceMeetingReference[reference, default: []].compactMap { candidateID in
      candidateID == runID ? nil : agentRunsByID[candidateID]
    }
  }

  func agentRunCount(for scope: AgentRunScope) -> Int {
    agentRunScopeCounts[scope, default: 0]
  }

  func agentRunMatchesFilter(_ run: AgentRunItem) -> Bool {
    guard !agentRunFilterTerms.isEmpty else { return true }
    let searchText = agentRunFilterTextByID[run.id] ?? run.runFilterText
    return agentRunFilterTerms.allSatisfy { searchText.contains($0) }
  }

  public func focusCorpusFileFilter() {
    selectedSurface = .files
    corpusFileFilterFocusToken += 1
  }

  public func deactivateAgendaFilterFocus() {
    isAgendaFilterFocused = false
  }

  public func clearAgendaFilter() {
    agendaFilter = ""
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public var agendaStructuredFilterCount: Int {
    [
      agendaDateFilter == .any ? "" : agendaDateFilter.rawValue,
      agendaAssigneeFilter,
      agendaStatusFilter,
      agendaPriorityFilter,
      agendaTopicFilter
    ].filter { !$0.isEmpty }.count
  }

  public var hasAgendaStructuredFilters: Bool {
    agendaStructuredFilterCount > 0
  }

  public func setAgendaDateFilter(_ filter: AgendaDateFilter) {
    if filter == .next7 || filter == .later {
      agendaMode = .range
    }
    agendaDateFilter = filter
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public func clearAgendaStructuredFilters() {
    isUpdatingAgendaStructuredFilters = true
    agendaDateFilter = .any
    agendaAssigneeFilter = ""
    agendaStatusFilter = ""
    agendaPriorityFilter = ""
    agendaTopicFilter = ""
    isUpdatingAgendaStructuredFilters = false
    rebuildAgendaDisplayCache()
    rebuildAssignedWorkDisplayCache()
    syncAgendaSelectionAfterDisplayOptionsChange()
  }

  public func agendaStatusFilterTitle(_ filter: String) -> String {
    switch filter {
    case Self.agendaOpenStatusFilter: "Open"
    case Self.agendaCompletedStatusFilter: "Completed"
    default: filter
    }
  }

  public func agendaAssigneeFilterTitle(_ filter: String) -> String {
    filter == Self.agendaUnassignedFilter ? "Unassigned" : filter
  }

  public func agendaPriorityFilterTitle(_ filter: String) -> String {
    filter == Self.agendaNoPriorityFilter ? "No priority" : filter
  }

  public var canOrganizeCurrentHeadline: Bool {
    hasBulkAgendaSelection || selectedHeadlineMutationTarget != nil
  }

  var selectedHeadlineMutationTarget: HeadlineMutationTarget? {
    if selectedSurface == .agenda,
       let item = selectedAgendaItemForMutation() {
      return HeadlineMutationTarget(item: item)
    }
    if let renderedTarget = selectedRenderedHeadlineMutationTarget {
      return renderedTarget
    }
    if let locationTarget = selectedLocationHeadlineMutationTarget {
      return locationTarget
    }
    return nil
  }

  private var selectedRenderedHeadlineMutationTarget: HeadlineMutationTarget? {
    guard let source = selectedEntrySource, source.isEditable else { return nil }
    let visibleBlocks = OrgRenderedFoldTree.visibleBlocks(
      selectedRenderedBlocks,
      foldedBlockIDs: foldedRenderedBlockIDs
    )
    guard !visibleBlocks.isEmpty else { return nil }

    let candidate: OrgEditableBlock?
    if let selectedBlock {
      candidate = visibleBlocks
        .filter { block in
          if case .heading = block.rendered {
            return block.startLine <= selectedBlock.startLine
          }
          return false
        }
        .max { $0.startLine < $1.startLine }
    } else if source.isSubtree {
      candidate = visibleBlocks.first { block in
        if case .heading = block.rendered {
          return block.startLine == source.startLine
        }
        return false
      }
    } else {
      candidate = nil
    }

    guard let candidate,
          case .heading(let heading) = candidate.rendered
    else {
      return nil
    }
    return HeadlineMutationTarget(
      file: source.file,
      line: candidate.startLine,
      title: heading.title.isEmpty ? relativePath(source.file) : Org2Display.cleanInline(heading.title),
      agendaItemID: nil
    )
  }

  private var selectedLocationHeadlineMutationTarget: HeadlineMutationTarget? {
    guard let location = selectedLocation else { return nil }
    if case .agenda(let item) = location {
      return HeadlineMutationTarget(item: item)
    }
    guard selectedEntrySource?.isEditable == true else { return nil }
    let line: Int
    if let source = selectedEntrySource, source.isSubtree, source.file == location.file {
      line = source.startLine
    } else {
      line = location.lineForEditor
    }
    return HeadlineMutationTarget(
      file: location.file,
      line: line,
      title: location.title,
      agendaItemID: nil
    )
  }

  func headlineMutationTarget(for location: WorkspaceLocation) -> HeadlineMutationTarget? {
    switch location {
    case .agenda(let item):
      return HeadlineMutationTarget(item: item)
    case .assigned(let item):
      return HeadlineMutationTarget(
        file: item.file,
        line: item.lineForEditor,
        title: Org2Display.cleanInline(item.headline)
      )
    case .search(let result):
      return HeadlineMutationTarget(
        file: result.file,
        line: result.lineForEditor,
        title: Org2Display.cleanInline(result.title)
      )
    case .backlink(let backlink):
      return HeadlineMutationTarget(
        file: backlink.file,
        line: backlink.lineForEditor,
        title: Org2Display.cleanInline(backlink.srcTitle)
      )
    case .aiChatThreadRecord(let thread):
      return HeadlineMutationTarget(
        file: thread.file,
        line: thread.lineForEditor,
        title: Org2Display.cleanInline(thread.title)
      )
    case .meeting(let meeting):
      return HeadlineMutationTarget(
        file: meeting.file,
        line: meeting.lineForEditor,
        title: Org2Display.cleanInline(meeting.title)
      )
    }
  }

  func refreshAfterHeadlineMutation(
    _ target: HeadlineMutationTarget,
    selectMutatedBlock: Bool = true,
    reloadSelectedEntry: Bool = true
  ) async {
    invalidateCanonicalDocumentCache(for: target.file)
    if reloadSelectedEntry,
       selectedEntrySource?.file == target.file,
       let selectedLocation {
      if selectMutatedBlock {
        pendingBlockSelection = PendingBlockSelection(
          file: target.file,
          line: target.line,
          mode: .containingOrNearest
        )
      }
      scheduleEntrySourceLoad(for: selectedLocation)
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  func documentMutationContext(for target: HeadlineMutationTarget) throws -> WorkspaceDocumentCorpusContext {
    guard let context = captureDocumentCorpusContext(forFile: target.file) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: target.file,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    return context
  }

  func performDocumentMutation<Value: Sendable>(
    context: WorkspaceDocumentCorpusContext,
    files: [String],
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable (WorkspaceDocumentMutationExecution) async throws -> Value
  ) async throws -> Value {
    try await documentMutationLane.perform(
      rootPath: context.mutationRootPath,
      resourcePaths: files,
      priority: priority,
      operation: operation
    )
  }

  func replaceDocumentSourceRange(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String? = nil,
    allowDestructiveReplacement: Bool = false,
    context explicitContext: WorkspaceDocumentCorpusContext? = nil
  ) async throws {
    guard let context = explicitContext ?? captureDocumentCorpusContext(forFile: file) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: file,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    try await performDocumentMutation(context: context, files: [file]) { execution in
      let url = URL(fileURLWithPath: file)
      let snapshot = try await execution.readSnapshot(at: url)
      let output = try Self.textByReplacingSourceRange(
        in: snapshot.text,
        file: file,
        startLine: startLine,
        endLineExclusive: endLineExclusive,
        replacement: replacement,
        expectedOriginal: expectedOriginal
      )
      guard output != snapshot.text else { return }
      try await execution.commit(output, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "source range edit",
          allowDestructiveReplacement: allowDestructiveReplacement
        )
      }
    }
  }

  func deleteDocumentSourceRangeCleaningAdjacentBlank(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    allowDestructiveReplacement: Bool = false
  ) async throws {
    guard let context = captureDocumentCorpusContext(forFile: file) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: file,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    try await performDocumentMutation(context: context, files: [file]) { execution in
      let url = URL(fileURLWithPath: file)
      let snapshot = try await execution.readSnapshot(at: url)
      let output = try Self.textByDeletingSourceRangeCleaningAdjacentBlank(
        in: snapshot.text,
        file: file,
        startLine: startLine,
        endLineExclusive: endLineExclusive
      )
      guard output != snapshot.text else { return }
      try await execution.commit(output, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "source range delete",
          allowDestructiveReplacement: allowDestructiveReplacement
        )
      }
    }
  }

  func swapDocumentSourceRanges(
    file: String,
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) async throws {
    guard let context = captureDocumentCorpusContext(forFile: file) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: file,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    try await performDocumentMutation(context: context, files: [file]) { execution in
      let url = URL(fileURLWithPath: file)
      let snapshot = try await execution.readSnapshot(at: url)
      let output = try Self.textBySwappingSourceRanges(
        in: snapshot.text,
        file: file,
        firstStartLine: firstStartLine,
        firstEndLineExclusive: firstEndLineExclusive,
        secondStartLine: secondStartLine,
        secondEndLineExclusive: secondEndLineExclusive
      )
      guard output != snapshot.text else { return }
      try await execution.commit(output, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "source range swap"
        )
      }
    }
  }

  nonisolated static func resolveHeadlineMutationTarget(
    _ target: HeadlineMutationTarget,
    in raw: String,
    requiresTodo: Bool = false,
    canonicalHeadlines: [Int: Org2CanonicalHeadline]? = nil
  ) throws -> HeadlineMutationTarget {
    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let isCandidate: (Int) -> Bool = { index in
      guard lines.indices.contains(index), headingLevel(lines[index]) != nil else { return false }
      if let canonicalHeadlines { return !requiresTodo || canonicalHeadlines[index + 1]?.todo != nil }
      return !requiresTodo || parseTodoHeading(lines[index]) != nil
    }
    let candidateTitle: (Int) -> String = { index in
      if let headline = canonicalHeadlines?[index + 1] { return canonicalInlineText(headline.title) }
      if let heading = parseTodoHeading(lines[index]) {
        return heading.title
      }
      return headingTitle(from: lines[index])
    }

    // Agenda properties include inherited values, so an ID may belong to the
    // file-level drawer or an ancestor rather than this heading. Only an ID
    // owned by exactly one heading identifies it; otherwise resolve by the
    // line and title like any heading without an ID.
    if let idValue = target.idValue {
      let matches = lines.indices.filter { index in
        guard isCandidate(index) else { return false }
        let properties = scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
        return properties["ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) == idValue
      }
      if matches.count == 1, let index = matches.first {
        return HeadlineMutationTarget(
          file: target.file,
          line: index + 1,
          title: candidateTitle(index),
          agendaItemID: target.agendaItemID,
          idValue: idValue
        )
      }
    }

    let normalizedTitle = normalizedApprovalActionTitle(target.title)
    let originalIndex = target.line - 1
    if isCandidate(originalIndex),
       normalizedApprovalActionTitle(candidateTitle(originalIndex)) == normalizedTitle {
      return HeadlineMutationTarget(
        file: target.file,
        line: originalIndex + 1,
        title: candidateTitle(originalIndex),
        agendaItemID: target.agendaItemID
      )
    }

    let matches = lines.indices.filter { index in
      isCandidate(index)
        && normalizedApprovalActionTitle(candidateTitle(index)) == normalizedTitle
    }
    guard matches.count == 1, let index = matches.first else {
      throw WorkspaceDocumentMutationError.fileChanged(file: target.file)
    }
    return HeadlineMutationTarget(
      file: target.file,
      line: index + 1,
      title: candidateTitle(index),
      agendaItemID: target.agendaItemID
    )
  }

  nonisolated static func canonicalTodoMutationTarget(
    _ target: HeadlineMutationTarget,
    text: String,
    cli: Org2CLI,
    requiresTodo: Bool = true
  ) async throws -> HeadlineMutationTarget {
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(text, sourceRanges: true, sourcePath: target.file)
    if document.todoSequences?.isEmpty != false {
      return try resolveHeadlineMutationTarget(target, in: text, requiresTodo: requiresTodo)
    }
    var headlines: [Int: Org2CanonicalHeadline] = [:]
    func collect(_ nodes: [Org2CanonicalNode]) {
      for node in nodes {
        if case .headline(let heading) = node {
          if let line = heading.sourceRange?.startLine { headlines[line] = heading }
          collect(heading.children)
        }
      }
    }
    collect(document.children)
    return try resolveHeadlineMutationTarget(target, in: text, requiresTodo: requiresTodo, canonicalHeadlines: headlines)
  }

  nonisolated static func commitDocumentText(
    _ replacement: String,
    url: URL,
    previousText: String,
    operation: String,
    allowDestructiveReplacement: Bool = false
  ) throws {
    try writeOrgTextSafely(
      replacement,
      to: url,
      replacing: previousText,
      operation: operation,
      allowDestructiveReplacement: allowDestructiveReplacement
    )
  }

  func cancelEntryPreviewWorkForAgendaKeyboardAdvance() {
    // A queued freshness check or source load may not have flipped the loading
    // flags yet. Invalidate all preview work unconditionally so a late task for
    // the prior row cannot interfere with the newly highlighted row.
    selectedDetailFreshnessTask?.cancel()
    selectedDetailFreshnessTask = nil
    entrySourceLoadGeneration += 1
    entryHTMLRenderGeneration += 1
    entrySourceLoadWatchdogTask?.cancel()
    entrySourceLoadWatchdogTask = nil
    entryHTMLRenderWatchdogTask?.cancel()
    entryHTMLRenderWatchdogTask = nil
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = nil
    activeEntrySourceLoadingGeneration = nil
    isLoadingEntrySource = false
    isRenderingEntrySource = false
  }

  func optimisticallyUpdateAgendaItem(id agendaItemID: AgendaItem.ID?, todo: String) {
    guard let agendaItemID,
          let agenda
    else {
      return
    }

    var updatedSelectedItem: AgendaItem?
    let removesItem = Self.isTerminalTodoStatus(todo)
    let transformItems: ([AgendaItem]) -> [AgendaItem] = { items in
      items.compactMap { item in
        guard item.id == agendaItemID else { return item }
        if removesItem { return nil }
        let updated = item.replacing(todo: todo)
        updatedSelectedItem = updated
        return updated
      }
    }
    let transformGroups: ([AgendaGroup]?) -> [AgendaGroup]? = { groups in
      groups?.map { group in
        AgendaGroup(label: group.label, items: transformItems(group.items))
      }
    }
    let transformDays: ([AgendaDay]) -> [AgendaDay] = { days in
      days.map { day in
        AgendaDay(
          date: day.date,
          weekday: day.weekday,
          items: transformItems(day.items),
          groups: transformGroups(day.groups)
        )
      }
    }

    self.agenda = AgendaPayload(
      schema: agenda.schema,
      range: agenda.range,
      overdue: transformDays(agenda.overdue),
      days: transformDays(agenda.days),
      skippedFiles: agenda.skippedFiles,
      workload: agenda.workload,
      corpora: agenda.corpora,
      issues: agenda.issues
    )

    if let updatedSelectedItem,
       case .agenda(let currentItem) = selectedLocation,
       currentItem.id == agendaItemID {
      selectedLocation = .agenda(updatedSelectedItem)
    }
  }

  public func presentSimilarTodoAssignment() async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a TODO heading first"
      return
    }
    guard let corpusRoot,
          let corpusContext = captureDocumentCorpusContext()
    else {
      statusText = "No corpus selected"
      return
    }

    similarTodoScanRequestGeneration &+= 1
    let requestGeneration = similarTodoScanRequestGeneration
    let targetFile = WorkspaceDocumentMutationLane.canonicalPath(target.file)
    let assignee = resolvedAgentHandoffAssignee()

    for attempt in 0..<2 {
      let filesGeneration = corpusFilesGeneration
      let eventSerial = corpusFileEventSerial
      let files = corpusFiles
      let request = SimilarTodoScanContext(
        requestGeneration: requestGeneration,
        corpus: corpusContext,
        corpusFilesGeneration: filesGeneration,
        corpusFileEventSerial: eventSerial,
        targetFile: targetFile,
        targetLine: target.line,
        targetTitle: target.title,
        targetID: target.idValue
      )
      let laneSnapshot = await documentMutationLane.rootMutationSnapshot(
        rootPath: corpusContext.mutationRootPath
      )
      do {
        let preparation = similarTodoScanPreparationForTesting
        let cache = workspaceTodoScanCache
        let matched = try await Task.detached(priority: .utility) {
          await preparation?()
          let scanFiles = files.isEmpty
            ? try Self.scanCorpusFiles(corpusRoot: corpusRoot)
            : files
          let allCandidates = try await cache.scan(files: scanFiles)
          return Self.similarTodoCandidates(to: target, from: allCandidates)
        }.value
        guard isCurrentSimilarTodoScan(request) else { return }
        let laneIsCurrent = await documentMutationLane.isCurrentAndQuiescent(laneSnapshot)
        guard corpusFilesGeneration == request.corpusFilesGeneration,
              corpusFileEventSerial == request.corpusFileEventSerial,
              laneIsCurrent
        else {
          if attempt == 0 {
            await Task.yield()
            continue
          }
          return
        }
        similarTodoCandidates = matched
        selectedSimilarTodoCandidateIDs = Set(matched.map(\.id))
        similarTodoPattern = Self.inferredAssignmentPattern(from: matched, fallback: target.title)
        similarTodoAssignee = assignee
        similarTodoStatus = "ready"
        isSimilarTodoAssignmentPresented = true
        statusText = "\(matched.count) similar TODO\(matched.count == 1 ? "" : "s") found"
        return
      } catch {
        guard isCurrentSimilarTodoScan(request) else { return }
        errorText = error.localizedDescription
        statusText = "Similar TODO scan failed"
        return
      }
    }
  }

  public func toggleSimilarTodoCandidateSelection(_ candidate: SimilarTodoCandidate) {
    if selectedSimilarTodoCandidateIDs.contains(candidate.id) {
      selectedSimilarTodoCandidateIDs.remove(candidate.id)
    } else {
      selectedSimilarTodoCandidateIDs.insert(candidate.id)
    }
  }

  public func assignSimilarTodos(askAIChat: Bool) async {
    let assignee = similarTodoAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !assignee.isEmpty else {
      statusText = "Assignee is required"
      return
    }
    let status = similarTodoStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "ready"
      : similarTodoStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = similarTodoCandidates.filter { selectedSimilarTodoCandidateIDs.contains($0.id) }
    guard !selected.isEmpty else {
      statusText = "Select at least one TODO"
      return
    }
    guard let originContext = captureDocumentCorpusContext() else {
      statusText = "No corpus selected"
      return
    }

    let timestamp = Self.orgTimestamp(Date())
    do {
      var touchedFiles: Set<String> = []
      let grouped = Dictionary(grouping: selected, by: { candidate in
        WorkspaceDocumentMutationLane.canonicalPath(candidate.file)
      })
      let cli = self.cli
      for file in grouped.keys.sorted() {
        guard let candidates = grouped[file] else { continue }
        let targets = candidates.sorted(by: { $0.line > $1.line }).map { candidate in
          HeadlineMutationTarget(
            file: candidate.file,
            line: candidate.line,
            title: Org2Display.cleanInline(candidate.headline),
            idValue: candidate.properties["ID"]
          )
        }
        guard let firstTarget = targets.first else { continue }
        let context = try documentMutationContext(for: firstTarget)
        try await performDocumentMutation(context: context, files: [file]) { execution in
          for target in targets {
            let assignedTarget = try await Self.assignTodoInDocument(
              assignee: assignee,
              target: target,
              cli: cli,
              execution: execution
            )
            _ = try await Self.upsertPropertiesInDocument(
              [
                "STATUS": status,
                "ASSIGNED_AT": timestamp,
              ],
              target: assignedTarget,
              execution: execution
            )
          }
        }
        touchedFiles.insert(file)
      }
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      statusText = "Assigned \(selected.count) TODO\(selected.count == 1 ? "" : "s") to \(assignee)"
      isSimilarTodoAssignmentPresented = false
      await refreshAgenda(preserveSelection: true, updatesStatus: false)
      await refreshAssignedWork(showsLoading: false)
      if let selectedLocation, touchedFiles.contains(selectedLocation.file) {
        await loadEntrySource(for: selectedLocation)
      }
      if askAIChat {
        await askAIChatToHandleAssignedBacklog(
          assignee: assignee,
          status: status,
          pattern: similarTodoPattern,
          items: selected
        )
      }
    } catch {
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      errorText = error.localizedDescription
      statusText = "Assignment failed"
    }
  }

  public func askAIChatToHandleAssignedBacklog(
    assignee: String,
    status: String,
    pattern: String,
    items: [SimilarTodoCandidate]
  ) async {
    guard !items.isEmpty else { return }
    let prompt = Self.aiChatAssignedBacklogPrompt(
      assignee: assignee,
      status: status,
      pattern: pattern,
      items: items,
      relativePath: { [weak self] file in self?.relativePath(file) ?? file },
      mappedPath: { [weak self] file in self?.mappedPathForOpenClaw(file) ?? file }
    )
    let first = items[0]
    let pointer = AIChatContextPointer(
      kind: "assigned backlog action",
      displayTitle: "\(items.count) item\(items.count == 1 ? "" : "s") for \(assignee)",
      reference: "\(mappedPathForOpenClaw(first.file)):\(first.line)",
      displayReference: "\(relativePath(first.file)):\(first.line)",
      threadTitle: "Assigned backlog: \(assignee)"
    )
    setAIChatAssistantPanelPresented(true)
    await sendAIChatMessage(
      text: automaticAIChatActionText(pointer, prompt: prompt)
    )
  }
}
