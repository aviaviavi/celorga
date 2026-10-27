import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  nonisolated static func clampedSourceEditorSelection(
    _ selection: NSRange,
    utf16Length: Int
  ) -> NSRange {
    let location = min(max(0, selection.location), utf16Length)
    return NSRange(
      location: location,
      length: min(max(0, selection.length), max(0, utf16Length - location))
    )
  }

  nonisolated static func clampedSourceEditorSelection(
    _ selection: NSRange,
    in text: String
  ) -> NSRange {
    clampedSourceEditorSelection(
      selection,
      utf16Length: text.utf16.count
    )
  }

  nonisolated static func sourceEditorUTF16Offset(
    forAbsoluteLine line: Int,
    in source: EntrySource,
    sourceLineIndex: OrgSourceLineIndex
  ) -> Int {
    let lineOffset = max(0, line - source.startLine)
    return sourceLineIndex.utf16Offset(forLine: lineOffset + 1)
  }

  public func beginEditingBlock(
    _ block: OrgEditableBlock,
    initialDraft: String? = nil,
    initialSelection: NSRange? = nil
  ) {
    guard block.isEditable, selectedEntrySource?.isEditable == true else {
      statusText = "Block is read-only"
      return
    }
    if initialDraft == nil,
       !isEditingEntry,
       selectedBlockID == block.id,
       editingBlockID == block.id {
      return
    }
    let draft = initialDraft ?? block.rawText
    isEditingEntry = false
    selectedBlockID = block.id
    editingBlockID = block.id
    editableBlockText = draft
    activeBlockDrafts[block.id] = draft
    activeBlockOriginals[block.id] = block
    if let initialSelection {
      activeBlockInitialSelections[block.id] = initialSelection
    } else {
      activeBlockInitialSelections.removeValue(forKey: block.id)
    }
    deferredStableAutosaves.removeValue(forKey: block.id)
    if draft != block.rawText {
      let updatedBlocks = Self.locallyUpdatingRenderedBlocks(
        selectedRenderedBlocks,
        replacing: block,
        with: draft
      )
      setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
      selectedBlockID = block.id
    }
  }

  public func updateEditingBlockDraft(_ block: OrgEditableBlock, draft: String) {
    guard editingBlockID == block.id else { return }
    activeBlockDrafts[block.id] = draft
  }

  public func initialSelectionForEditingBlock(_ block: OrgEditableBlock) -> NSRange? {
    guard editingBlockID == block.id else { return nil }
    return activeBlockInitialSelections[block.id]
  }

  public func cancelEditingBlock() {
    if let draft = transientDraftBlock, editingBlockID == draft.block.id {
      discardTransientDraft(status: "Draft discarded")
      return
    }
    if !applyDeferredStableAutosaveForActiveBlock() {
      restoreActiveBlockOriginal()
    }
    resetBlockEditing()
  }

  public var selectedBlock: OrgEditableBlock? {
    guard let selectedBlockID else { return nil }
    guard let index = selectedRenderedBlockIndexes[selectedBlockID],
          selectedRenderedBlocks.indices.contains(index),
          selectedRenderedBlocks[index].id == selectedBlockID
    else {
      return nil
    }
    return selectedRenderedBlocks[index]
  }

  public var hasSelectedBlock: Bool {
    selectedBlock != nil
  }

  public var canSaveActiveEdit: Bool {
    if isEditingEntry {
      return entryEditorHasUnsavedChanges && !isSavingEntry
    }
    if editingBlockID != nil {
      return !isSavingBlock
    }
    return false
  }

  public var canSaveCurrentFile: Bool {
    (isEditingEntry && !isSavingEntry)
      || canSaveActiveEdit
      || canSaveLiveFileEditor
      || (orgCryptEncryptOnSave && selectedFileForOrgCryptSave != nil)
  }

  public var canExportSlides: Bool {
    currentOrgSourceFile != nil && !isExportingSlides && !isSavingEntry && !isSavingBlock
  }

  public var canExportCurrentDocumentPDF: Bool {
    currentOrgSourceFile != nil
      && !isExportingCurrentDocumentPDF
      && !isSavingEntry
      && !isSavingBlock
  }

  public var canPublishCurrentDocument: Bool {
    currentOrgSourceFile != nil
      && !isPublishingDocument
      && !isSavingEntry
      && !isSavingBlock
  }

  public var currentDocumentPublishSubtreeLine: Int? {
    if let source = selectedEntrySource, source.isSubtree {
      return source.startLine
    }
    if let selectedBlock {
      return selectedBlock.startLine
    }
    return currentDocumentViewportSourceLine
  }

  public var currentDocumentPublishDisplayName: String {
    currentOrgSourceFile?.deletingPathExtension().lastPathComponent ?? "Document"
  }

  public func googleDrivePublication(
    for request: DocumentPublishRequest
  ) -> GoogleDrivePublicationBinding? {
    guard request.destination == .googleDrive else { return nil }
    return currentDocumentGoogleDrivePublications
      .filter { binding in
        guard binding.format == request.format else { return false }
        guard let line = request.line else { return binding.scopeLine == nil }
        return binding.scopeLine.map { $0 <= line } ?? false
      }
      .max { ($0.scopeLine ?? 0) < ($1.scopeLine ?? 0) }
  }

  func updateCurrentDocumentGoogleDrivePublications(for source: EntrySource?) {
    selectedGooglePublicationGeneration &+= 1
    let generation = selectedGooglePublicationGeneration
    selectedGooglePublicationTask?.cancel()
    selectedGooglePublicationTask = nil
    guard let source else {
      currentDocumentGoogleDrivePublications = []
      return
    }

    let fileURL = URL(fileURLWithPath: source.file).standardizedFileURL
    currentDocumentGoogleDrivePublications = []
    selectedGooglePublicationTask = Task { @MainActor [weak self] in
      let publications = await Task.detached(priority: .utility) {
        let text = !source.isSubtree && source.startLine == 1
          ? source.text
          : try? String(contentsOf: fileURL, encoding: .utf8)
        return text.map { GoogleDrivePublicationBinding.allBindings(in: $0) } ?? []
      }.value
      guard let self,
            !Task.isCancelled,
            self.selectedGooglePublicationGeneration == generation,
            self.selectedEntrySource?.id == source.id
      else { return }
      self.currentDocumentGoogleDrivePublications = publications
      self.selectedGooglePublicationTask = nil
    }
  }

  nonisolated private static func publicationData(at url: URL) -> Data? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          !data.isEmpty
    else { return nil }
    return data
  }

  private func publicationData(at url: URL) async -> Data? {
    await Task.detached(priority: .userInitiated) {
      Self.publicationData(at: url)
    }.value
  }

  public func presentDocumentPublisher() {
    guard currentOrgSourceFile != nil else {
      statusText = "Open an Org document first"
      return
    }
    isDocumentPublisherPresented = true
  }

  public func previewDocumentPublication(
    _ request: DocumentPublishRequest
  ) async throws -> DocumentPublishCLIResult {
    guard request.destination.formats.contains(request.format) else {
      throw DocumentPublishingError.unsupportedFormat
    }
    let sourceFile = try await sourceFileForDocumentPublishing()
    let googleBinding = try await googleDrivePublicationBinding(
      sourceFile: sourceFile,
      request: request
    )
    isPublishingDocument = true
    statusText = "Checking the publication boundary…"
    defer { isPublishingDocument = false }

    let outputDirectory = request.destination == .localLink
      ? documentPublicationDirectory(preview: true)
      : nil
    let result: DocumentPublishCLIResult = try await cli.runJSON(
      Self.documentPublishArguments(
        sourceFile: sourceFile,
        request: request,
        outputDirectory: outputDirectory,
        googleBinding: googleBinding,
        apply: false
      )
    )
    statusText = "Publication preview ready"
    return result
  }

  public func publishDocument(
    _ request: DocumentPublishRequest,
    googleAccessToken: String? = nil
  ) async throws -> DocumentPublishOutcome {
    guard request.destination.formats.contains(request.format) else {
      throw DocumentPublishingError.unsupportedFormat
    }
    let sourceFile = try await sourceFileForDocumentPublishing()
    let googleBinding = try await googleDrivePublicationBinding(
      sourceFile: sourceFile,
      request: request
    )
    isPublishingDocument = true
    statusText = request.destination == .localLink
      ? "Starting the local publication…"
      : "Publishing to \(request.format.title)…"
    defer { isPublishingDocument = false }

    switch request.destination {
    case .localLink:
      let outputDirectory = documentPublicationDirectory(preview: false)
      let result: DocumentPublishCLIResult = try await cli.runJSON(
        Self.documentPublishArguments(
          sourceFile: sourceFile,
          request: request,
          outputDirectory: outputDirectory,
          apply: true
        )
      )
      let data: Data
      let mediaType: String
      switch request.format {
      case .html:
        let indexURL = outputDirectory.appendingPathComponent("index.html", isDirectory: false)
        guard let html = await publicationData(at: indexURL) else {
          throw DocumentPublishingError.missingWebBundle(indexURL.path)
        }
        data = html
        mediaType = "text/html"
      case .pdf:
        let indexURL = outputDirectory.appendingPathComponent("index.html", isDirectory: false)
        guard let html = await publicationData(at: indexURL) else {
          throw DocumentPublishingError.missingWebBundle(indexURL.path)
        }
        data = try await renderedPublicationPDF(html: html, baseURL: outputDirectory)
        mediaType = "application/pdf"
      case .beamerSlides:
        let pdfURL = outputDirectory.appendingPathComponent("presentation.pdf", isDirectory: false)
        guard let pdf = await publicationData(at: pdfURL) else {
          throw DocumentPublishingError.missingWebBundle(pdfURL.path)
        }
        data = try await Task.detached(priority: .userInitiated) {
          try Org2PDFExporter.validated(pdf)
        }.value
        mediaType = "application/pdf"
      case .googleDocs, .googleSlides, .googleSheets:
        throw DocumentPublishingError.unsupportedFormat
      }
      let hostedPublication = try await localDocumentPublicationHost.publish(
        data: data,
        title: result.artifact.title,
        mediaType: mediaType,
        sourcePath: result.source.file,
        format: request.format,
        stableKey: Self.localDocumentPublicationStableKey(
          sourceFile: sourceFile,
          request: request
        )
      )
      localDocumentPublications.removeAll { $0.id == hostedPublication.id }
      localDocumentPublications.insert(hostedPublication, at: 0)
      statusText = "Published \(result.artifact.title) on the local network"
      return .localLink(publication: hostedPublication, result: result)

    case .googleDrive:
      let token = googleAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !token.isEmpty else {
        throw DocumentPublishingError.missingGoogleCredential
      }
      let result: DocumentPublishCLIResult
      if request.format == .pdf {
        let outputDirectory = documentPublicationDirectory(preview: false)
        let webRequest = DocumentPublishRequest(
          destination: .localLink,
          format: .html,
          line: request.line
        )
        _ = try await cli.runJSON(
          Self.documentPublishArguments(
            sourceFile: sourceFile,
            request: webRequest,
            outputDirectory: outputDirectory,
            apply: true
          )
        ) as DocumentPublishCLIResult
        let indexURL = outputDirectory.appendingPathComponent("index.html", isDirectory: false)
        guard let html = await publicationData(at: indexURL) else {
          throw DocumentPublishingError.missingWebBundle(indexURL.path)
        }
        let pdf = try await renderedPublicationPDF(html: html, baseURL: outputDirectory)
        let pdfURL = outputDirectory.appendingPathComponent("publication.pdf", isDirectory: false)
        try await Task.detached(priority: .userInitiated) {
          try Org2PDFExporter.validated(pdf).write(to: pdfURL, options: .atomic)
        }.value
        result = try await cli.runJSON(
          Self.documentPublishArguments(
            sourceFile: sourceFile,
            request: request,
            outputDirectory: nil,
            pdfFile: pdfURL,
            googleBinding: googleBinding,
            apply: true
          ),
          environment: ["ORG2_GOOGLE_DRIVE_ACCESS_TOKEN": token]
        )
      } else {
        result = try await cli.runJSON(
          Self.documentPublishArguments(
            sourceFile: sourceFile,
            request: request,
            outputDirectory: nil,
            googleBinding: googleBinding,
            apply: true
          ),
          environment: ["ORG2_GOOGLE_DRIVE_ACCESS_TOKEN": token]
        )
      }
      guard let link = result.destinationString("webViewLink"),
            let url = URL(string: link),
            let fileID = result.destinationString("fileId")
      else {
        throw DocumentPublishingError.invalidGoogleResponse
      }
      let binding = GoogleDrivePublicationBinding(
        format: request.format,
        fileID: fileID,
        url: url,
        version: result.destinationString("version"),
        publishedAt: Date(),
        scopeLine: request.line
      )
      do {
        try await persistGoogleDrivePublication(binding, in: sourceFile)
      } catch {
        throw DocumentPublishingError.googlePublicationPersistenceFailed(
          url,
          error.localizedDescription
        )
      }
      statusText = googleBinding == nil
        ? "Published and linked \(result.artifact.title) in \(request.format.title)"
        : "Updated linked \(request.format.title) publication"
      return .googleDrive(
        format: request.format,
        url: url,
        fileID: fileID,
        version: result.destinationString("version"),
        result: result
      )
    }
  }

  public func revokeLocalDocumentPublication(_ publicationID: String) {
    do {
      try localDocumentPublicationHost.revoke(publicationID)
      localDocumentPublications.removeAll { $0.id == publicationID }
      statusText = "Local publication revoked"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not revoke the local publication"
    }
  }

  public func revokeAllLocalDocumentPublications() {
    do {
      try localDocumentPublicationHost.revokeAll()
      localDocumentPublications.removeAll()
      statusText = "All local publications revoked"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not revoke all local publications"
    }
  }

  public func restoreLocalDocumentPublications() async {
    do {
      localDocumentPublications = try await localDocumentPublicationHost.restorePublications()
      ensureChatThreadPublicationMonitor()
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not restore local publications"
    }
  }

  private func sourceFileForDocumentPublishing() async throws -> URL {
    guard !isPublishingDocument else {
      throw DocumentPublishingError.busy
    }
    guard let sourceFile = currentOrgSourceFile else {
      throw DocumentPublishingError.noDocument
    }
    guard await savePendingEditsBeforeExport(
      blockedStatus: "Save the current edit before publishing the document"
    ) else {
      throw DocumentPublishingError.pendingEdits
    }
    return sourceFile.standardizedFileURL
  }

  nonisolated static func documentPublishArguments(
    sourceFile: URL,
    request: DocumentPublishRequest,
    outputDirectory: URL?,
    pdfFile: URL? = nil,
    googleBinding: GoogleDrivePublicationBinding? = nil,
    apply: Bool
  ) -> [String] {
    let cliDestination: String
    switch request.destination {
    case .localLink:
      cliDestination = request.format == .beamerSlides ? "beamer-pdf" : "web"
    case .googleDrive:
      cliDestination = request.format.googleCLIDestination ?? "google-docs"
    }
    var arguments = [
      "publish", "document",
      "--file", sourceFile.path,
      "--to", cliDestination,
      "--format", "json",
    ]
    if let line = request.line {
      arguments.append(contentsOf: ["--line", String(line)])
    }
    if let outputDirectory, request.destination == .localLink {
      if request.format == .beamerSlides {
        arguments.append(contentsOf: [
          "--out-file",
          outputDirectory.appendingPathComponent("presentation.pdf", isDirectory: false).path,
        ])
      } else {
        arguments.append(contentsOf: ["--out-dir", outputDirectory.path])
      }
    }
    if let googleBinding,
       request.destination == .googleDrive {
      arguments.append(contentsOf: [
        "--document-id", googleBinding.fileID,
      ])
      if let version = googleBinding.version {
        arguments.append(contentsOf: ["--if-version", version])
      }
      arguments.append("--replace-existing")
    } else if let folderID = request.googleFolderID, request.destination == .googleDrive {
      arguments.append(contentsOf: ["--folder-id", folderID])
    }
    if let pdfFile {
      arguments.append(contentsOf: ["--pdf-file", pdfFile.path])
    }
    if apply {
      arguments.append("--apply")
    }
    return arguments
  }

  nonisolated static func localDocumentPublicationStableKey(
    sourceFile: URL,
    request: DocumentPublishRequest
  ) -> String {
    let scope = request.line.map(String.init) ?? "document"
    return [
      sourceFile.standardizedFileURL.path,
      "scope:\(scope)",
      "format:\(request.format.rawValue)",
    ].joined(separator: "\n")
  }

  private func googleDrivePublicationBinding(
    sourceFile: URL,
    request: DocumentPublishRequest
  ) async throws -> GoogleDrivePublicationBinding? {
    guard request.destination == .googleDrive else { return nil }
    let format = request.format
    let line = request.line
    let binding = try await Task.detached(priority: .userInitiated) {
      let sourceText = try String(contentsOf: sourceFile, encoding: .utf8)
      return GoogleDrivePublicationBinding.binding(
        for: format,
        in: sourceText,
        line: line
      )
    }.value
    return binding
  }

  private func persistGoogleDrivePublication(
    _ binding: GoogleDrivePublicationBinding,
    in sourceFile: URL
  ) async throws {
    let sourceFile = sourceFile.standardizedFileURL
    guard let context = captureDocumentCorpusContext(forFile: sourceFile.path) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: sourceFile.path,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    try await performDocumentMutation(context: context, files: [sourceFile.path]) { execution in
      let snapshot = try await execution.readSnapshot(at: sourceFile)
      guard let updatedSource = GoogleDrivePublicationBinding.sourceText(
        snapshot.text,
        upserting: binding
      ) else {
        throw CocoaError(.fileWriteUnknown)
      }
      guard updatedSource != snapshot.text else { return }
      try await execution.commit(updatedSource, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "Google Drive publication metadata"
        )
      }
    }
    guard isCurrentDocumentCorpusContext(context) else { return }
    invalidateCanonicalDocumentCache(for: sourceFile.path)
    if selectedLocation?.file == sourceFile.path {
      await reloadSelectedEntrySource()
    }
  }

  private func renderedPublicationPDF(html: Data, baseURL: URL) async throws -> Data {
    let htmlString = String(decoding: html, as: UTF8.self)
    let pdf: Data
    if let documentPDFRendererForTesting {
      pdf = try await documentPDFRendererForTesting(htmlString, baseURL)
    } else {
      pdf = try await Org2PDFExporter().data(for: htmlString, baseURL: baseURL)
    }
    return try await Task.detached(priority: .userInitiated) {
      try Org2PDFExporter.validated(pdf)
    }.value
  }

  private func documentPublicationDirectory(preview: Bool) -> URL {
    if preview {
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("openorg-publish-preview-\(UUID().uuidString)", isDirectory: true)
    }
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return applicationSupport
      .appendingPathComponent("OpenOrg", isDirectory: true)
      .appendingPathComponent("Publications", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
  }

  private static let chatThreadShareAppearanceKey = "Org2Workspace.chatThreadShareAppearance.v1"

  /// Appearance a paired client chose for a thread it shared through this host.
  var chatThreadShareAppearanceOverrides: [UUID: AIChatThreadShareAppearance] {
    get {
      guard let data = defaults.data(forKey: Self.chatThreadShareAppearanceKey),
            let values = try? JSONDecoder().decode([String: AIChatThreadShareAppearance].self, from: data)
      else { return [:] }
      return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
        UUID(uuidString: key).map { ($0, value) }
      })
    }
    set {
      let values = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString.lowercased(), $0.value) })
      if values.isEmpty {
        defaults.removeObject(forKey: Self.chatThreadShareAppearanceKey)
      } else if let data = try? JSONEncoder().encode(values) {
        defaults.set(data, forKey: Self.chatThreadShareAppearanceKey)
      }
    }
  }

  static func localDocumentPublicationStorageDirectory() -> URL? {
    let applicationFolder: String
    switch Bundle.main.bundleIdentifier {
    case "org.org2.workspace":
      applicationFolder = "OpenOrg"
    case "org.org2.workspace.codex":
      applicationFolder = "OpenOrg Preview"
    default:
      return nil
    }
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return applicationSupport
      .appendingPathComponent(applicationFolder, isDirectory: true)
      .appendingPathComponent("Publications", isDirectory: true)
      .appendingPathComponent("Hosted", isDirectory: true)
  }

  public func exportCurrentDocumentPDF() async {
    guard let sourceFile = currentOrgSourceFile else {
      statusText = "Open an Org file first"
      return
    }
    guard !isExportingCurrentDocumentPDF else { return }
    guard await savePendingEditsBeforeExport(blockedStatus: "Save the current edit before exporting the document") else {
      return
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.directoryURL = sourceFile.deletingLastPathComponent()
    panel.nameFieldStringValue = sourceFile.deletingPathExtension().lastPathComponent + ".pdf"
    panel.allowedContentTypes = [.pdf]
    panel.title = "Export Current Document as PDF"
    panel.prompt = "Export"

    guard panel.runModal() == .OK, let destination = panel.url else {
      statusText = "PDF export cancelled"
      return
    }

    isExportingCurrentDocumentPDF = true
    statusText = "Exporting document as PDF…"
    defer { isExportingCurrentDocumentPDF = false }

    do {
      try await exportCurrentDocumentPDF(sourceFile: sourceFile, destination: destination)
      finishSuccessfulDocumentPDFExport(destination: destination)
    } catch {
      errorText = error.localizedDescription
      statusText = "PDF export failed: \(error.localizedDescription)"
      exportNotice = Org2ExportNotice(
        title: "Couldn’t Export PDF",
        message: error.localizedDescription
      )
    }
  }

  func exportCurrentDocumentPDF(sourceFile: URL, destination: URL) async throws {
    let standardizedSource = sourceFile.standardizedFileURL
    let html = try await renderedCurrentDocumentHTML(sourceFile: standardizedSource)
    let baseURL = standardizedSource.deletingLastPathComponent()
    let pdf: Data
    if let documentPDFRendererForTesting {
      pdf = try await documentPDFRendererForTesting(html, baseURL)
    } else {
      pdf = try await Org2PDFExporter().data(for: html, baseURL: baseURL)
    }
    try await Task.detached(priority: .userInitiated) {
      try Org2PDFExporter.validated(pdf).write(to: destination, options: .atomic)
    }.value
  }

  func renderedCurrentDocumentHTML(sourceFile: URL) async throws -> String {
    let standardizedSource = sourceFile.standardizedFileURL
    let text = try await Task.detached(priority: .userInitiated) {
      try String(contentsOf: standardizedSource, encoding: .utf8)
    }.value
    return try await cli.renderAppHTML(
      text,
      sourcePath: standardizedSource.path,
      sourceLineOffset: 0,
      stylesheetPath: appHTMLStylesheetPath,
      corpusRootPath: corpusRoot?.path,
      resolveEmbeds: false
    )
  }

  func finishSuccessfulDocumentPDFExport(destination: URL) {
    errorText = nil
    let didOpen = documentPDFExportFileOpenerForTesting?(destination)
      ?? NSWorkspace.shared.open(destination)
    if didOpen {
      statusText = "Exported and opened \(destination.lastPathComponent)"
      exportNotice = nil
      return
    }

    statusText = "Exported \(destination.lastPathComponent), but couldn’t open the PDF"
    exportNotice = Org2ExportNotice(
      title: "PDF Exported",
      message: "\(destination.path)\n\nThe PDF was saved, but macOS couldn’t open it automatically."
    )
  }

  public func exportSlides(format: Org2SlideExportFormat) async {
    guard let sourceFile = currentOrgSourceFile else {
      statusText = "Open an Org file first"
      return
    }
    guard !isExportingSlides else { return }
    guard await savePendingEditsBeforeExport(blockedStatus: "Save the current edit before exporting slides") else {
      return
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.directoryURL = sourceFile.deletingLastPathComponent()
    panel.nameFieldStringValue = sourceFile.deletingPathExtension().lastPathComponent + ".\(format.fileExtension)"
    if format == .pdf {
      panel.allowedContentTypes = [.pdf]
    } else {
      panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
    }
    panel.title = "Export Slides as \(format.title)"
    panel.prompt = "Export"

    guard panel.runModal() == .OK, let destination = panel.url else {
      statusText = "Slide export cancelled"
      return
    }

    isExportingSlides = true
    statusText = "Exporting slides…"
    defer { isExportingSlides = false }

    do {
      try await cli.exportBeamer(file: sourceFile, destination: destination, format: format)
      finishSuccessfulSlideExport(format: format, destination: destination)
    } catch {
      errorText = error.localizedDescription
      statusText = "Slide export failed: \(error.localizedDescription)"
      exportNotice = Org2ExportNotice(
        title: "Couldn’t Export Slides",
        message: error.localizedDescription
      )
    }
  }

  func finishSuccessfulSlideExport(
    format: Org2SlideExportFormat,
    destination: URL
  ) {
    errorText = nil

    if format == .pdf {
      let didOpen = slideExportFileOpenerForTesting?(destination)
        ?? NSWorkspace.shared.open(destination)
      if didOpen {
        statusText = "Exported and opened \(destination.lastPathComponent)"
        exportNotice = nil
        return
      }

      statusText = "Exported slides to \(destination.lastPathComponent), but couldn’t open the PDF"
      exportNotice = Org2ExportNotice(
        title: "Slides Exported",
        message: "\(destination.path)\n\nThe PDF was saved, but macOS couldn’t open it automatically."
      )
      return
    }

    statusText = "Exported slides to \(destination.lastPathComponent)"
    exportNotice = Org2ExportNotice(
      title: "Slides Exported",
      message: destination.path
    )
  }

  var currentOrgSourceFile: URL? {
    let path = selectedEntrySource?.file ?? selectedLocation?.file
    guard let path else { return nil }
    let sourceFile = URL(fileURLWithPath: path).standardizedFileURL
    guard ["org", "org2"].contains(sourceFile.pathExtension.lowercased()) else { return nil }
    return sourceFile
  }

  func savePendingEditsBeforeExport(blockedStatus: String) async -> Bool {
    await publishPendingNativeEditorState()
    let hadPendingEdit = entryEditorHasUnsavedChanges
      || liveFileEditorHasUnsavedChanges
      || editingBlockID != nil
    guard hadPendingEdit else { return true }

    await saveActiveEdit()
    let stillPending = entryEditorHasUnsavedChanges
      || liveFileEditorHasUnsavedChanges
      || editingBlockID != nil
    if stillPending {
      statusText = blockedStatus
      return false
    }
    return true
  }

  public var hasActiveEdit: Bool {
    isEditingEntry || editingBlockID != nil
  }

  public var isLiveFileEditorSelected: Bool {
    selectedEntrySourceMode == .page
      && selectedLocation != nil
      && (selectedSurface == .files || selectedFileIsCSV)
  }

  public var selectedFileIsCSV: Bool {
    let file = selectedLocation?.file ?? selectedEntrySource?.file
    guard let file else { return false }
    return URL(fileURLWithPath: file).pathExtension.lowercased() == "csv"
  }

  private func jsonCanvasMutationContext(file: String, root: String) throws -> WorkspaceDocumentCorpusContext {
    let canonicalRoot = WorkspaceDocumentMutationLane.canonicalPath(root)
    guard corpusRoot.map({ WorkspaceDocumentMutationLane.canonicalPath($0.path) }) == canonicalRoot,
          let context = captureDocumentCorpusContext(forFile: file),
          context.mutationRootPath == canonicalRoot else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: file, root: root)
    }
    return context
  }

  nonisolated static func jsonCanvasRelativeResourcePath(file: String, root: String) -> String? {
    let candidate = URL(fileURLWithPath: file).standardizedFileURL.path
    let roots = [
      URL(fileURLWithPath: root).standardizedFileURL.path,
      WorkspaceDocumentMutationLane.canonicalPath(root),
    ]
    for rootPath in roots {
      let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
      if candidate.hasPrefix(prefix) {
        // Keep the candidate lexical: the shared runtime rejects symlinks below the root.
        return String(candidate.dropFirst(prefix.count))
      }
    }
    return nil
  }

  public func mutateJSONCanvas(file: String, root: String, revision: String, operations: Data) async throws -> JSONCanvasMutationPayload {
    let context = try jsonCanvasMutationContext(file: file, root: root)
    let cli = self.cli
    let result: JSONCanvasMutationPayload = try await performDocumentMutation(context: context, files: [file]) { _ in
      try await cli.runJSON([
        "canvas", "edit", "--dir", root, "--file", file,
        "--if-revision", revision, "--stdin", "--apply", "--json"
      ], standardInput: operations)
    }
    guard isCurrentDocumentCorpusContext(context) else { return result }
    invalidateCanonicalDocumentCache(for: file)
    await refreshCorpusFiles()
    guard isCurrentDocumentCorpusContext(context) else { return result }
    statusText = "Saved Canvas"
    return result
  }

  public func createJSONCanvasFromPanel(importing: Bool = false) async {
    guard let root = corpusRoot else { return }
    var importURL: URL?
    if importing {
      let openPanel = NSOpenPanel()
      openPanel.title = "Import JSON Canvas"
      openPanel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .data]
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false
      guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
      importURL = url
    }
    let panel = NSSavePanel()
    panel.title = importing ? "Save imported Canvas in this corpus" : "Create Canvas in this corpus"
    panel.directoryURL = root
    panel.nameFieldStringValue = importURL?.lastPathComponent ?? "Workspace.canvas"
    panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .data]
    guard panel.runModal() == .OK, let target = panel.url else { return }
    do {
      let context = try jsonCanvasMutationContext(file: target.path, root: root.path)
      var arguments = ["canvas", importing ? "import" : "create", "--dir", root.path, "--file", target.path, "--apply", "--json"]
      if let importURL { arguments += ["--from", importURL.path] }
      let cli = self.cli
      let command = arguments
      let result: JSONCanvasMutationPayload = try await performDocumentMutation(context: context, files: [target.path]) { _ in
        try await cli.runJSON(command)
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      await refreshCorpusFiles()
      guard isCurrentDocumentCorpusContext(context) else { return }
      selectCorpusFile(
        CorpusFile(path: result.file, relativePath: relativePath(result.file), modifiedAt: Date(), byteCount: nil),
        surface: selectedSurface == .canvases ? .canvases : .files
      )
      statusText = importing ? "Imported Canvas" : "Created Canvas"
      errorText = nil
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not create Canvas"
    }
  }

  public var selectedFileIsCanvas: Bool {
    guard let file = selectedLocation?.file else { return false }
    return URL(fileURLWithPath: file).pathExtension.lowercased() == "canvas"
  }

  public var selectedFileIsPDF: Bool {
    let file = selectedLocation?.file ?? selectedEntrySource?.file
    guard let file else { return false }
    return Self.isPDFFile(file)
  }

  nonisolated static func isPDFFile(_ path: String) -> Bool {
    URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
  }

  /// Raster image formats the native file view renders with ImageIO.
  nonisolated static let nativeImagePreviewExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"
  ]
  /// Video containers AVFoundation plays in the native file view.
  nonisolated static let nativeVideoPreviewExtensions: Set<String> = [
    "mov", "mp4", "m4v"
  ]

  nonisolated static func isImageFile(_ path: String) -> Bool {
    nativeImagePreviewExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  nonisolated static func isVideoFile(_ path: String) -> Bool {
    nativeVideoPreviewExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  nonisolated static func isMediaFile(_ path: String) -> Bool {
    isImageFile(path) || isVideoFile(path)
  }

  /// Files rendered by a native viewer rather than as Org/text source.
  nonisolated static func isNativePreviewFile(_ path: String) -> Bool {
    isPDFFile(path) || isMediaFile(path)
  }

  public var selectedFileIsImage: Bool {
    guard let file = selectedLocation?.file else { return false }
    return Self.isImageFile(file)
  }

  public var selectedFileIsVideo: Bool {
    guard let file = selectedLocation?.file else { return false }
    return Self.isVideoFile(file)
  }

  /// PDF, image, or video: the detail pane shows a native preview with no
  /// editable source, entity type, or publishing actions.
  public var selectedFileIsNativePreview: Bool {
    selectedFileIsPDF || selectedFileIsImage || selectedFileIsVideo
  }

  public var isLiveFileEditorAvailable: Bool {
    isLiveFileEditorSelected && selectedEntrySource?.isEditable == true
  }

  public var canSaveLiveFileEditor: Bool {
    isLiveFileEditorAvailable && liveFileEditorHasUnsavedChanges && !isSavingEntry
  }

  public var liveFileEditorHasUnsavedChanges: Bool {
    guard let source = selectedEntrySource,
          let selectedLocation,
          isLiveFileEditorSelected,
          URL(fileURLWithPath: source.file).standardizedFileURL.path
            == URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path
    else { return false }
    return liveFileEditorDraftGeneration != liveFileEditorSavedDraftGeneration
  }

  public var entryEditorHasUnsavedChanges: Bool {
    guard isEditingEntry, selectedEntrySource != nil else { return false }
    return sourceEditorDraftGeneration != sourceEditorSavedDraftGeneration
  }

  public func noteSourceEditorLocalTextChanged(_ text: String) {
    guard isEditingEntry else { return }
    // The editor republishes text it already published (a delayed Vim or
    // typing publish, or the binding echoing a save). Counting that as a new
    // edit marked a just-saved draft dirty, so Save & Done stayed open until
    // a second click.
    let current = sourceEditorLocalDraftText ?? editableEntryText
    if text.utf8.count == current.utf8.count, text == current { return }
    sourceEditorLocalDraftText = text
    sourceEditorDraftGeneration &+= 1
  }

  public func cancelActiveEdit() {
    if editingBlockID != nil {
      cancelEditingBlock()
    } else {
      cancelEditingSelectedEntry()
    }
  }

  public func selectBlock(_ block: OrgEditableBlock) {
    guard selectedEntrySource?.isEditable == true else { return }
    guard selectedBlockID != block.id else { return }
    selectedBlockID = block.id
  }

  public func clearSelectedBlock() {
    selectedBlockID = nil
  }

  public func canSelectAdjacentBlock(_ direction: OrgBlockMoveDirection) -> Bool {
    guard let selectedBlock else { return false }
    let blocks = selectableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == selectedBlock.id }) else { return false }
    switch direction {
    case .up:
      return index > 0
    case .down:
      return index < blocks.count - 1
    }
  }

  public func selectAdjacentBlock(_ direction: OrgBlockMoveDirection) {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    let blocks = selectableBlocks
    guard let index = blocks.firstIndex(where: { $0.id == selectedBlock.id }) else {
      selectedBlockID = nil
      return
    }

    let nextIndex: Int
    switch direction {
    case .up:
      nextIndex = max(0, index - 1)
    case .down:
      nextIndex = min(blocks.count - 1, index + 1)
    }
    selectedBlockID = blocks[nextIndex].id
  }

  public func toggleRenderedBlockFold(_ block: OrgEditableBlock) {
    setRenderedBlock(block, folded: !foldedRenderedBlockIDs.contains(block.id))
  }

  @discardableResult
  public func collapseSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    return setRenderedBlock(selectedBlock, folded: true)
  }

  @discardableResult
  public func expandSelectedRenderedBlock() -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    return setRenderedBlock(selectedBlock, folded: false)
  }

  public func collapseAllRenderedBlocks() {
    let foldableIDs = Set(selectedRenderedBlocks.filter {
      OrgRenderedFoldTree.isFoldable($0, in: selectedRenderedBlocks)
    }.map(\.id))
    foldedRenderedBlockIDs = foldableIDs
    if let selectedBlockID,
       let ancestorID = OrgRenderedFoldTree.foldedAncestorID(
        hiding: selectedBlockID,
        foldedBlockIDs: foldableIDs,
        blocks: selectedRenderedBlocks
       ) {
      self.selectedBlockID = ancestorID
    }
    statusText = foldableIDs.isEmpty ? "Nothing to collapse" : "Collapsed rendered blocks"
  }

  public func expandAllRenderedBlocks() {
    foldedRenderedBlockIDs = []
    statusText = "Expanded rendered blocks"
  }

  @discardableResult
  private func setRenderedBlock(_ block: OrgEditableBlock, folded: Bool) -> Bool {
    guard OrgRenderedFoldTree.isFoldable(block, in: selectedRenderedBlocks) else {
      statusText = "Selected block has nothing to \(folded ? "collapse" : "expand")"
      return false
    }

    var nextFoldedIDs = foldedRenderedBlockIDs
    if folded {
      nextFoldedIDs.insert(block.id)
      if let selectedBlockID,
         let range = OrgRenderedFoldTree.childrenRange(for: block, in: selectedRenderedBlocks),
         let selectedIndex = selectedRenderedBlocks.firstIndex(where: { $0.id == selectedBlockID }),
         range.contains(selectedIndex) {
        self.selectedBlockID = block.id
      }
      statusText = "Collapsed block"
    } else {
      nextFoldedIDs.remove(block.id)
      statusText = "Expanded block"
    }
    foldedRenderedBlockIDs = nextFoldedIDs
    return true
  }

  public func beginEditingSelectedBlock() {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    beginEditingSource(for: selectedBlock)
  }

  public func beginEditingSelectedBlock(appending text: String) -> Bool {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return false
    }
    beginEditingSource(
      for: selectedBlock,
      selection: NSRange(location: selectedBlock.rawText.utf16.count, length: 0)
    )
    insertTextInSourceEditor(text)
    return true
  }

  public func insertLiveEmbedDirective(_ directive: String) {
    // The shared runtime has validated and generated this directive. Insertion
    // uses the existing draft/save path and never changes the embedded source.
    let wasEditing = isEditingEntry
    if !wasEditing { beginEditingCurrentScope() }
    guard isEditingEntry else { return }
    if !wasEditing {
      sourceEditorSelection = NSRange(location: sourceEditorInteraction.text.utf16.count, length: 0)
    }
    insertTextInSourceEditor("\n" + directive + "\n")
    sourceEditorPresentation = .split
    scheduleSourceEditorPreview(immediate: true)
  }

  /// Makes an image chosen while typing available to the edited note. An image
  /// outside the corpus is copied into `attachments/`, so the link renders on
  /// every Mac the corpus syncs to. Returns an Org link relative to the note.
  public func importSourceEditorImage(from imageURL: URL) async -> String? {
    guard let corpusRoot, let context = captureDocumentCorpusContext() else {
      statusText = "No corpus selected"
      return nil
    }
    let resolvedRoot = corpusRoot.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedImage = imageURL.standardizedFileURL.resolvingSymlinksInPath()
    let finalURL: URL
    if resolvedImage.path.hasPrefix(resolvedRoot.path + "/") {
      finalURL = resolvedImage
    } else {
      let attachmentsDirectory = corpusRoot.appendingPathComponent("attachments", isDirectory: true)
      do {
        finalURL = try await performDocumentMutation(
          context: context,
          files: [attachmentsDirectory.path],
          priority: .userInitiated
        ) { execution in
          try Self.copyEditorImage(imageURL, into: attachmentsDirectory, execution: execution)
        }.standardizedFileURL.resolvingSymlinksInPath()
      } catch {
        statusText = "Could not add image: \(error.localizedDescription)"
        return nil
      }
    }
    let sourceFile = selectedEntrySource.map {
      OrgHTMLDocumentView.sourceFileURL($0, corpusRoot: corpusRoot).resolvingSymlinksInPath().path
    }
    let target = WorkspaceDateMentions.linkPath(to: finalURL.path, from: sourceFile, corpusRoot: resolvedRoot)
    statusText = "Added image \(finalURL.lastPathComponent)"
    return "[[file:\(target.replacingOccurrences(of: "]", with: "%5D"))]]"
  }

  nonisolated private static func copyEditorImage(
    _ imageURL: URL,
    into attachmentsDirectory: URL,
    execution: WorkspaceDocumentMutationExecution
  ) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    let ext = imageURL.pathExtension.lowercased()
    let baseName = slug(imageURL.deletingPathExtension().lastPathComponent)
    let fileName = ext.isEmpty ? baseName : "\(baseName.isEmpty ? "image" : baseName).\(ext)"
    let finalURL = try execution.authorizeDescendant(
      uniqueAttachmentURL(in: attachmentsDirectory, fileName: fileName),
      ofDeclaredDirectory: attachmentsDirectory
    )
    let temporaryURL = try execution.authorizeDescendant(
      attachmentsDirectory.appendingPathComponent(".openorg-image-\(UUID().uuidString.lowercased()).tmp"),
      ofDeclaredDirectory: attachmentsDirectory
    )
    do {
      try fileManager.copyItem(at: imageURL, to: temporaryURL)
      try fileManager.moveItem(at: temporaryURL, to: finalURL)
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
    return finalURL
  }

  private func insertTextInSourceEditor(_ text: String) {
    guard isEditingEntry, !text.isEmpty else { return }
    let currentText = sourceEditorLocalDraftText ?? sourceEditorInteraction.text
    let range = Self.clampedSourceEditorSelection(sourceEditorSelection, in: currentText)
    let updatedText = (currentText as NSString).replacingCharacters(in: range, with: text)
    let updatedSelection = NSRange(location: range.location + text.utf16.count, length: 0)
    replaceEditableEntryTextFromModel(updatedText)
    sourceEditorLocalDraftText = updatedText
    sourceEditorDraftGeneration &+= 1
    sourceEditorInteraction.reset(text: updatedText, selection: updatedSelection)
  }

  public func duplicateSelectedBlock() async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await duplicateBlock(selectedBlock)
  }

  public func deleteSelectedBlock() async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await deleteBlock(selectedBlock)
  }

  public func moveSelectedBlock(_ direction: OrgBlockMoveDirection) async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await moveBlock(selectedBlock, direction: direction)
  }

  public func insertBlockAfterSelected(_ kind: OrgInsertBlockKind, initialText: String? = nil) async {
    guard let selectedBlock else {
      statusText = "Select a block first"
      return
    }
    await insertBlock(after: selectedBlock, kind: kind, initialText: initialText)
  }

  public func beginAppendingSectionAtEnd() async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }

    if let lastBlock = selectedRenderedBlocks
      .filter({ block in
        block.isEditable
          && block.startLine >= source.startLine
          && block.endLineExclusive <= source.endLineExclusive
      })
      .max(by: { lhs, rhs in
        if lhs.endLineExclusive != rhs.endLineExclusive {
          return lhs.endLineExclusive < rhs.endLineExclusive
        }
        return lhs.startLine < rhs.startLine
      }) {
      await insertBlock(after: lastBlock, kind: .paragraph)
      return
    }

    let draft = appendDraftBlock(kind: .paragraph, in: source)
    transientDraftBlock = draft
    pendingBlockSelection = nil
    isEditingEntry = false
    activateTransientDraft(draft)
    statusText = "Started paragraph draft in \(relativePath(source.file))"
  }

  public func canMoveSelectedBlock(_ direction: OrgBlockMoveDirection) -> Bool {
    guard let selectedBlock else { return false }
    return canMoveBlock(selectedBlock, direction: direction)
  }

  public func saveActiveEdit() async {
    await publishPendingNativeEditorState()
    if isEditingEntry {
      await saveEditedEntry()
      return
    }

    if let draft = transientDraftBlock, editingBlockID == draft.block.id {
      await saveTransientDraftBlock(draft)
      return
    }

    guard let block = activeEditingBlock else {
      if isLiveFileEditorAvailable && liveFileEditorHasUnsavedChanges {
        await saveLiveFileEditor(explicit: true)
        return
      }
      await encryptSelectedFileAfterSave()
      return
    }
    await saveEditedBlock(block)
  }

  /// App menu commands do not pass through `NSTextView`'s key-command path.
  /// Publish and await the exact native-buffer capture before consulting model
  /// dirty generations or constructing an export.
  private func publishPendingNativeEditorState() async {
    _ = OrgSyntaxTextEditorLifecycle.publishPendingTextChanges()
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
  }

  public func saveAndFinishActiveEdit() async {
    if isEditingEntry {
      // The native editor publishes typing (and Vim commands) on a short
      // delay. Without this capture, a publish landing while the save was
      // formatting made the save stand down for the newer text, and Save &
      // Done then stayed in the editor with nothing visibly wrong.
      await publishPendingNativeEditorState()
      if entryEditorHasUnsavedChanges {
        var attempts = 0
        while isEditingEntry, entryEditorHasUnsavedChanges, attempts < 3 {
          attempts += 1
          let generation = sourceEditorDraftGeneration
          await saveEditedEntry()
          // A failed save leaves the draft as it was; keep the editor open.
          // Only newer text arriving mid-save is worth saving again.
          guard sourceEditorDraftGeneration != generation else { break }
          await publishPendingNativeEditorState()
        }
        guard isEditingEntry, !entryEditorHasUnsavedChanges else { return }
        // Saving starts a re-render of the page. Leaving the editor before it
        // publishes swaps in the loading view, then the native preview, then
        // the web page, which reads as a flicker. Keep the editor up until the
        // saved page is ready (bounded so a slow render never traps the user).
        await waitForInFlightEntryRender(
          timeoutNanoseconds: Self.saveAndDoneRenderWaitNanoseconds
        )
      }
      guard isEditingEntry, !entryEditorHasUnsavedChanges else { return }
      cancelEditingSelectedEntry()
      return
    }

    await saveActiveEdit()
  }

  nonisolated static let saveAndDoneRenderWaitNanoseconds: UInt64 = 1_500_000_000

  /// Waits until the selected entry's current render finishes, or until the
  /// timeout. Never cancels the render itself.
  func waitForInFlightEntryRender(timeoutNanoseconds: UInt64) async {
    guard let renderTask = entryHTMLRenderTask else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await renderTask.value }
      group.addTask { try? await Task.sleep(nanoseconds: timeoutNanoseconds) }
      _ = await group.next()
      group.cancelAll()
    }
  }

  private var selectedFileForOrgCryptSave: String? {
    selectedEntrySource?.file ?? selectedLocation?.file
  }

  private func encryptSelectedFileAfterSave() async {
    guard orgCryptEncryptOnSave else {
      statusText = "No active edit to save"
      return
    }
    guard let file = selectedFileForOrgCryptSave else {
      statusText = "No file selected"
      return
    }

    do {
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: file)
      invalidateCanonicalDocumentCache(for: file)
      if encryptedCount > 0 {
        statusText = "Encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        if let selectedLocation {
          await loadEntrySource(for: selectedLocation)
        }
        scheduleAgendaRefresh(preserveSelection: true)
      } else {
        statusText = "No plaintext :crypt: subtrees to encrypt"
      }
    } catch {
      recordOrgCryptEncryptionFailure(error, savedPrefix: nil)
    }
  }

  public func saveEditedEntry() async {
    guard let source = selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    guard source.isEditable else {
      statusText = "Selection is read-only"
      return
    }
    guard entryEditorHasUnsavedChanges else {
      statusText = "No source changes to save"
      return
    }

    isSavingEntry = true
    defer { isSavingEntry = false }

    let draft = sourceEditorLocalDraftText ?? editableEntryText
    let draftGeneration = sourceEditorDraftGeneration
    let formatResult = await formattedEntryTextForSave(draft, source: source)
    let replacement = formatResult.text
    await entrySaveDidFormatHookForTesting?()
    guard selectedEntrySource?.id == source.id,
          isEditingEntry,
          sourceEditorDraftGeneration == draftGeneration
    else {
      return
    }

    let request = EditorPersistenceRequest(
      key: editorPersistenceKey(kind: "source-editor", file: source.file, identity: source.id),
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      expectedOriginal: source.text,
      replacement: replacement
    )
    let outcome = await enqueueEditorPersistence(request, priority: .userInitiated).value
    switch outcome {
    case .saved, .unchanged:
      break
    case .failed(let message, let isConflict):
      errorText = message
      if isConflict {
        presentEditorSaveConflict(source: source, draft: replacement)
        statusText = "Save conflict: file changed on disk"
      } else {
        statusText = "Save failed"
      }
      return
    }

    let savedStatus: String
    do {
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)
      savedStatus = encryptedCount > 0
        ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
        : "Saved \(relativePath(source.file)):\(source.displayRange)"
    } catch {
      recordOrgCryptEncryptionFailure(error, savedPrefix: "Saved, but")
      await finishSavedEntry(source: source, savedText: replacement, keepEditing: true)
      return
    }

    statusText = formatResult.warning.map { "\(savedStatus), but \($0)" } ?? savedStatus
    await finishSavedEntry(
      source: source,
      savedText: replacement,
      keepEditing: !savedStatus.contains("encrypted")
    )
  }

  private func formattedEntryTextForSave(
    _ text: String,
    source: EntrySource
  ) async -> (text: String, warning: String?) {
    let sourceURL = URL(fileURLWithPath: source.file)
    guard Self.isOrgTextFile(sourceURL) else {
      return (text, nil)
    }

    let canonicalOrgSyntax = sourceURL.pathExtension.lowercased() == "org"
    let shouldCanonicalizeSugar = canonicalOrgSyntax && Self.containsOrgSyntaxSugar(text)
    let shouldFormatFullPage = formatOrgFilesOnSave
      && selectedEntrySourceMode == .page
      && source.startLine == 1
      && !source.isSubtree
    guard shouldCanonicalizeSugar || shouldFormatFullPage else {
      return (text, nil)
    }

    do {
      return (try await cli.formatOrgText(text, canonicalOrgSyntax: canonicalOrgSyntax), nil)
    } catch {
      return (text, "formatting failed: \(error.localizedDescription)")
    }
  }

  private func presentEditorSaveConflict(source: EntrySource, draft: String) {
    if let key = editorSaveConflictPersistenceKey,
       let failed = failedEditorPersistenceDraftsByKey[key],
       failed.source.file == source.file,
       failed.draft == draft {
      // Preserve the keyed recovery record installed by the persistence lane.
    } else {
      editorSaveConflictPersistenceKey = nil
    }
    editorSaveConflictSource = source
    editorSaveConflictDraft = draft
    editorSaveConflict = Org2EditorSaveConflict(
      file: source.file,
      canOverwrite: selectedEntrySourceMode == .page
        && source.startLine == 1
        && !source.isSubtree
    )
  }

  public func preserveSourceEditorDraftAfterPublicationConflict(
    _ draft: String,
    source: EntrySource
  ) {
    editorSaveConflictPersistenceKey = nil
    editorSaveConflictSource = source
    editorSaveConflictDraft = draft
    // The selected document may already be different, so a blind overwrite
    // is never offered for this recovery boundary. The exact outgoing draft
    // remains available through the conflict sheet instead of being assigned
    // into the incoming editor binding.
    editorSaveConflict = Org2EditorSaveConflict(file: source.file, canOverwrite: false)
    statusText = "Preserved an outgoing editor draft for review"
  }

  /// Receives a point-in-time native-buffer checkpoint after navigation has
  /// already been allowed to proceed. The request carries the outgoing source
  /// identity, so persistence never depends on whichever document is selected
  /// when the background snapshot completes.
  public func persistSourceEditorCheckpoint(
    _ draft: String,
    source: EntrySource,
    kind: String = "source-editor"
  ) {
    if selectedEntrySource?.id == source.id {
      if sourceEditorLocalDraftText != draft {
        sourceEditorLocalDraftText = draft
        sourceEditorDraftGeneration &+= 1
      }
      if kind == "live-file" {
        editableEntryText = draft
      }
    }
    let request = EditorPersistenceRequest(
      key: editorPersistenceKey(
        kind: kind,
        file: source.file,
        identity: kind == "live-file" ? nil : source.id
      ),
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      expectedOriginal: source.text,
      replacement: draft
    )
    _ = enqueueEditorPersistence(request, priority: .userInitiated)
  }

  func blockEditorCheckpointTarget(
    for block: OrgEditableBlock,
    source: EntrySource?
  ) -> BlockEditorCheckpointTarget? {
    guard let source, source.isEditable else { return nil }
    let identity = [source.id, "block", block.id].joined(separator: "\u{1F}")

    if let transient = transientDraftBlock,
       transient.block.id == block.id {
      let expectedOriginal: String
      if !transient.coveredBlocks.isEmpty {
        expectedOriginal = transient.coveredBlocks.map(\.rawText).joined(separator: "\n")
      } else if transient.replacementEndLineExclusive > transient.insertionLine {
        // Appending into an otherwise empty/whitespace-only source replaces
        // that source range instead of inserting at a zero-width boundary.
        expectedOriginal = source.text
      } else {
        expectedOriginal = ""
      }
      return BlockEditorCheckpointTarget(
        identity: identity,
        key: editorPersistenceKey(
          kind: "block-editor",
          file: source.file,
          identity: block.id
        ),
        file: source.file,
        startLine: transient.insertionLine,
        endLineExclusive: transient.replacementEndLineExclusive,
        expectedOriginal: expectedOriginal,
        replacementPrefix: transient.replacementPrefix,
        replacementSuffix: transient.replacementSuffix,
        transientBlock: transient.block
      )
    }

    let original = activeBlockOriginals[block.id] ?? block
    return BlockEditorCheckpointTarget(
      identity: identity,
      key: editorPersistenceKey(
        kind: "block-editor",
        file: source.file,
        identity: block.id
      ),
      file: source.file,
      startLine: original.startLine,
      endLineExclusive: original.endLineExclusive,
      expectedOriginal: original.rawText,
      replacementPrefix: "",
      replacementSuffix: "",
      transientBlock: nil
    )
  }

  /// Persists a block editor's exact native-buffer checkpoint without reading
  /// current selection/editing state. The target is captured while the editor
  /// is mounted, so navigation may complete before this callback runs.
  func persistBlockEditorCheckpoint(
    _ rawReplacement: String,
    target: BlockEditorCheckpointTarget
  ) {
    let replacementBody: String
    if let transientBlock = target.transientBlock {
      guard let normalized = Self.normalizedTransientDraftText(
        rawReplacement,
        for: transientBlock
      ) else {
        return
      }
      replacementBody = normalized
    } else {
      replacementBody = rawReplacement
    }
    let request = EditorPersistenceRequest(
      key: target.key,
      file: target.file,
      startLine: target.startLine,
      endLineExclusive: target.endLineExclusive,
      expectedOriginal: target.expectedOriginal,
      replacement: target.replacementPrefix + replacementBody + target.replacementSuffix
    )
    _ = enqueueEditorPersistence(request, priority: .userInitiated)
  }

  public func keepEditingAfterSaveConflict() {
    guard editorSaveConflictSource != nil else { return }
    clearEditorSaveConflict()
    statusText = "Kept unsaved editor changes"
  }

  public func reloadAfterSaveConflict() async {
    guard let conflict = editorSaveConflict else { return }
    let shouldResumeEditing = isEditingEntry
    clearEditorSaveConflict()
    errorText = nil
    cancelLiveFileEditorAutosave(resetStatus: true)
    cancelEditingSelectedEntry()
    guard let selectedLocation else {
      statusText = "Could not reload \(relativePath(conflict.file))"
      return
    }
    await loadEntrySource(for: selectedLocation)
    if shouldResumeEditing {
      beginEditingSelectedEntry()
    }
    statusText = "Reloaded \(relativePath(conflict.file)) from disk"
  }

  public func overwriteAfterSaveConflict() async {
    guard let conflict = editorSaveConflict,
          conflict.canOverwrite,
          let source = editorSaveConflictSource,
          let replacement = editorSaveConflictDraft,
          source.file == conflict.file,
          selectedEntrySource?.file == conflict.file
    else {
      statusText = "The conflicted file is no longer selected"
      clearEditorSaveConflict()
      return
    }

    isSavingEntry = true
    defer { isSavingEntry = false }

    let undoSnapshot = await fileUndoSnapshot(for: source.file)
    let backupURL: URL
    do {
      guard let context = captureDocumentCorpusContext(forFile: source.file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(
          file: source.file,
          root: corpusRoot?.path ?? "(none)"
        )
      }
      backupURL = try await performDocumentMutation(context: context, files: [source.file]) {
        execution in
        guard source.startLine == 1, !source.isSubtree else {
          throw WorkspaceEditError.invalidRange(file: source.file, line: source.startLine)
        }
        let url = URL(fileURLWithPath: source.file)
        let snapshot = try await execution.readSnapshot(at: url)
        let backup = try Self.writeOrgRecoveryBackup(
          for: url,
          previousText: snapshot.text,
          reason: "save-conflict"
        )
        try await execution.commit(
          Self.normalizeLineEndings(replacement),
          over: snapshot
        ) { text, url, previous in
          try Self.commitDocumentText(
            text,
            url: url,
            previousText: previous,
            operation: "conflict overwrite"
          )
        }
        return backup
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Conflict overwrite failed"
      return
    }

    clearEditorSaveConflict()
    errorText = nil
    await recordFileUndo(from: undoSnapshot)
    await finishSavedEntry(source: source, savedText: replacement, keepEditing: true)
    statusText = "Saved \(relativePath(source.file)); recovery copy: \(relativePath(backupURL.path))"
  }

  private func clearEditorSaveConflict() {
    if let key = editorSaveConflictPersistenceKey {
      failedEditorPersistenceDraftsByKey.removeValue(forKey: key)
    }
    editorSaveConflict = nil
    editorSaveConflictSource = nil
    editorSaveConflictDraft = nil
    editorSaveConflictPersistenceKey = nil
    presentNextFailedEditorPersistenceDraftIfNeeded()
  }

  private func enqueueEditorPersistence(
    _ request: EditorPersistenceRequest,
    priority: TaskPriority = .utility
  ) -> Task<EditorPersistenceOutcome, Never> {
    let identifier = UUID()
    let predecessor = editorPersistenceTail
    let mutationContext = captureDocumentCorpusContext(forFile: request.file)
    pendingEditorPersistenceCountsByKey[request.key, default: 0] += 1

    let task = Task { @MainActor [weak self, predecessor, request] in
      if let predecessor {
        _ = await predecessor.value
      }
      guard let self else {
        return EditorPersistenceOutcome.failed(
          message: "The workspace closed before the editor draft was saved.",
          isConflict: false
        )
      }

      let resolvedRequest: EditorPersistenceRequest
      if let state = self.editorPersistenceRegionStates[request.key] {
        resolvedRequest = EditorPersistenceRequest(
          key: request.key,
          file: request.file,
          startLine: state.startLine,
          endLineExclusive: state.endLineExclusive,
          expectedOriginal: state.committedText,
          replacement: request.replacement
        )
      } else {
        resolvedRequest = request
      }

      let testDelay = self.editorPersistenceDelayNanosecondsForTesting
      let testFailureMessage = self.editorPersistenceFailureMessageForTesting
      let outcome: EditorPersistenceOutcome
      if let mutationContext {
        do {
          outcome = try await self.performDocumentMutation(
            context: mutationContext,
            files: [resolvedRequest.file],
            priority: priority
          ) { execution in
            if testDelay > 0 {
              try? await Task.sleep(nanoseconds: testDelay)
            }
            if let testFailureMessage {
              return EditorPersistenceOutcome.failed(
                message: testFailureMessage,
                isConflict: false
              )
            }
            return await Self.performEditorPersistence(
              resolvedRequest,
              execution: execution
            )
          }
        } catch {
          outcome = .failed(
            message: error.localizedDescription,
            isConflict: error is WorkspaceDocumentMutationError
          )
        }
      } else {
        outcome = .failed(
          message: WorkspaceDocumentMutationError.outsideCorpus(
            file: resolvedRequest.file,
            root: self.corpusRoot?.path ?? "(none)"
          ).localizedDescription,
          isConflict: false
        )
      }
      self.finishEditorPersistence(
        request: resolvedRequest,
        outcome: outcome,
        identifier: identifier
      )
      return outcome
    }
    editorPersistenceTail = task
    pendingEditorPersistenceTasks[identifier] = task
    return task
  }

  nonisolated private static func performEditorPersistence(
    _ request: EditorPersistenceRequest,
    execution: WorkspaceDocumentMutationExecution
  ) async -> EditorPersistenceOutcome {
    let normalizedExpected = normalizeLineEndings(request.expectedOriginal)
    let normalizedReplacement = normalizeLineEndings(request.replacement)
    let regionState = editorPersistenceRegionState(
      after: request,
      normalizedReplacement: normalizedReplacement
    )
    guard normalizedExpected != normalizedReplacement else {
      return .unchanged(regionState)
    }

    do {
      let url = URL(fileURLWithPath: request.file)
      let snapshot = try await execution.readSnapshot(at: url)
      let current = try sourceRangeText(
        in: snapshot.text,
        file: request.file,
        startLine: request.startLine,
        endLineExclusive: request.endLineExclusive
      )
      // A lifecycle boundary can observe the brief interval after an earlier
      // request has reached disk but before its caller publishes the saved
      // generation back on the main actor. Treat an identical on-disk range as
      // an idempotent success instead of reporting a false external-edit
      // conflict for the duplicate request.
      guard current != normalizedReplacement else { return .unchanged(regionState) }
      let output = try textByReplacingSourceRange(
        in: snapshot.text,
        file: request.file,
        startLine: request.startLine,
        endLineExclusive: request.endLineExclusive,
        replacement: normalizedReplacement,
        expectedOriginal: normalizedExpected
      )
      try await execution.commit(output, over: snapshot) { text, url, previous in
        try commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "editor persistence"
        )
      }
      let undoSnapshot: CompletedFileUndoSnapshot? =
        snapshot.text.utf8.count <= workspaceUndoSnapshotMaxBytes
          && output.utf8.count <= workspaceUndoSnapshotMaxBytes
        ? CompletedFileUndoSnapshot(file: request.file, previous: snapshot.text, next: output)
        : nil
      return .saved(undoSnapshot, regionState)
    } catch {
      let isConflict: Bool
      if case WorkspaceEditError.fileChanged = error {
        isConflict = true
      } else if case WorkspaceDocumentMutationError.fileChanged = error {
        isConflict = true
      } else {
        isConflict = false
      }
      return .failed(message: error.localizedDescription, isConflict: isConflict)
    }
  }

  private func finishEditorPersistence(
    request: EditorPersistenceRequest,
    outcome: EditorPersistenceOutcome,
    identifier: UUID
  ) {
    switch outcome {
    case .saved(let undoSnapshot, let regionState):
      recordFileUndo(from: undoSnapshot)
      editorPersistenceFailuresByKey.removeValue(forKey: request.key)
      clearFailedEditorPersistenceDraft(forKey: request.key)
      editorPersistenceRegionStates[request.key] = regionState
    case .unchanged(let regionState):
      editorPersistenceFailuresByKey.removeValue(forKey: request.key)
      clearFailedEditorPersistenceDraft(forKey: request.key)
      editorPersistenceRegionStates[request.key] = regionState
    case .failed(let message, let isConflict):
      editorPersistenceFailuresByKey[request.key] = message
      let recoverySource = EntrySource(
        file: request.file,
        startLine: request.startLine,
        endLineExclusive: request.endLineExclusive,
        text: request.expectedOriginal,
        isSubtree: false,
        isEditable: true
      )
      failedEditorPersistenceDraftsByKey[request.key] = FailedEditorPersistenceDraft(
        source: recoverySource,
        draft: request.replacement,
        message: message
      )
      editorSaveConflictPersistenceKey = request.key
      editorSaveConflictSource = recoverySource
      editorSaveConflictDraft = request.replacement
      editorSaveConflict = Org2EditorSaveConflict(file: request.file, canOverwrite: false)
      errorText = "Editor autosave failed for \(URL(fileURLWithPath: request.file).lastPathComponent): \(message)"
      statusText = isConflict
        ? "Autosave conflict: exact draft preserved for review"
        : "Autosave failed; exact draft preserved for review"
    }

    pendingEditorPersistenceTasks.removeValue(forKey: identifier)
    let remaining = max(0, pendingEditorPersistenceCountsByKey[request.key, default: 1] - 1)
    if remaining == 0 {
      pendingEditorPersistenceCountsByKey.removeValue(forKey: request.key)
      editorPersistenceRegionStates.removeValue(forKey: request.key)
    } else {
      pendingEditorPersistenceCountsByKey[request.key] = remaining
    }
  }

  private func clearFailedEditorPersistenceDraft(forKey key: String) {
    failedEditorPersistenceDraftsByKey.removeValue(forKey: key)
    guard editorSaveConflictPersistenceKey == key else { return }
    editorSaveConflict = nil
    editorSaveConflictSource = nil
    editorSaveConflictDraft = nil
    editorSaveConflictPersistenceKey = nil
    presentNextFailedEditorPersistenceDraftIfNeeded()
  }

  private func presentNextFailedEditorPersistenceDraftIfNeeded() {
    guard editorSaveConflict == nil,
          let next = failedEditorPersistenceDraftsByKey.sorted(by: {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
          }).first
    else { return }
    editorSaveConflictPersistenceKey = next.key
    editorSaveConflictSource = next.value.source
    editorSaveConflictDraft = next.value.draft
    editorSaveConflict = Org2EditorSaveConflict(
      file: next.value.source.file,
      canOverwrite: false
    )
  }

  func failedEditorPersistenceDraftForTesting(key: String) -> String? {
    failedEditorPersistenceDraftsByKey[key]?.draft
  }

  func failedEditorPersistenceDraftForTesting(file: String) -> String? {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    return failedEditorPersistenceDraftsByKey.values.first(where: {
      URL(fileURLWithPath: $0.source.file).standardizedFileURL.path == standardized
    })?.draft
  }

  nonisolated private static func editorPersistenceRegionState(
    after request: EditorPersistenceRequest,
    normalizedReplacement: String? = nil
  ) -> EditorPersistenceRegionState {
    let replacement = normalizedReplacement ?? normalizeLineEndings(request.replacement)
    let replacementLineCount = replacement.isEmpty
      ? 0
      : replacement.split(separator: "\n", omittingEmptySubsequences: false).count
    return EditorPersistenceRegionState(
      startLine: request.startLine,
      endLineExclusive: request.startLine + replacementLineCount,
      committedText: replacement
    )
  }

  func awaitPendingEditorPersistence() async -> Bool {
    while let task = pendingEditorPersistenceTasks.values.first {
      _ = await task.value
    }
    return editorPersistenceFailuresByKey.isEmpty
  }

  func waitForPendingEditorPersistenceForTesting() async -> Bool {
    await awaitPendingEditorPersistence()
  }

  private func editorPersistenceKey(
    kind: String,
    file: String,
    identity: String? = nil
  ) -> String {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    return [kind, standardized, identity ?? ""].joined(separator: "\u{1F}")
  }

  public func noteLiveFileEditorTextChanged(_ text: String) {
    guard isLiveFileEditorSelected else { return }
    editableEntryText = text
    liveFileEditorStatusText = liveFileEditorHasUnsavedChanges ? "Unsaved" : "Saved"
    scheduleLiveFileEditorAutosave()
  }

  /// Persists a whole-file transform that completed after its originating
  /// editor callback returned. The source identity is carried across that
  /// suspension so a CSV or other native editor cannot install its result in
  /// whichever document happens to be selected later.
  @discardableResult
  public func persistDeferredLiveFileEditorText(
    _ replacement: String,
    expectedText: String,
    source: EntrySource
  ) async -> Bool {
    guard source.isEditable, source.startLine == 1, !source.isSubtree else {
      preserveDeferredLiveFileEditorDraft(
        replacement,
        expectedText: expectedText,
        source: source,
        message: "The deferred editor result was not a whole-file document."
      )
      return false
    }

    let sourcePath = WorkspaceDocumentMutationLane.canonicalPath(source.file)
    let selectedPath = selectedEntrySource.map {
      WorkspaceDocumentMutationLane.canonicalPath($0.file)
    }
    if selectedEntrySource?.id == source.id,
       selectedPath == sourcePath,
       isLiveFileEditorSelected {
      noteLiveFileEditorTextChanged(replacement)
      return true
    }

    guard let context = captureDocumentCorpusContext(forFile: source.file) else {
      preserveDeferredLiveFileEditorDraft(
        replacement,
        expectedText: expectedText,
        source: source,
        message: WorkspaceDocumentMutationError.outsideCorpus(
          file: source.file,
          root: corpusRoot?.path ?? "(none)"
        ).localizedDescription
      )
      return false
    }

    do {
      try await performDocumentMutation(context: context, files: [source.file]) { execution in
        let url = URL(fileURLWithPath: source.file)
        let snapshot = try await execution.readSnapshot(at: url)
        guard snapshot.text == expectedText else {
          throw WorkspaceDocumentMutationError.fileChanged(file: source.file)
        }
        guard replacement != snapshot.text else { return }
        try await execution.commit(replacement, over: snapshot) { text, url, previous in
          try Self.commitDocumentText(
            text,
            url: url,
            previousText: previous,
            operation: "deferred live-file editor persistence"
          )
        }
      }
      invalidateCanonicalDocumentCache(for: source.file)
      let persistenceKey = editorPersistenceKey(kind: "live-file", file: source.file)
      editorPersistenceFailuresByKey.removeValue(forKey: persistenceKey)
      clearFailedEditorPersistenceDraft(forKey: persistenceKey)
      return true
    } catch {
      preserveDeferredLiveFileEditorDraft(
        replacement,
        expectedText: expectedText,
        source: source,
        message: error.localizedDescription
      )
      return false
    }
  }

  private func preserveDeferredLiveFileEditorDraft(
    _ replacement: String,
    expectedText: String,
    source: EntrySource,
    message: String
  ) {
    let key = editorPersistenceKey(kind: "live-file", file: source.file)
    editorPersistenceFailuresByKey[key] = message
    let recoverySource = EntrySource(
      file: source.file,
      startLine: 1,
      endLineExclusive: max(2, Self.lineCount(in: expectedText) + 1),
      text: expectedText,
      isSubtree: false,
      isEditable: true
    )
    failedEditorPersistenceDraftsByKey[key] = FailedEditorPersistenceDraft(
      source: recoverySource,
      draft: replacement,
      message: message
    )
    guard editorSaveConflict == nil else { return }
    editorSaveConflictPersistenceKey = key
    editorSaveConflictSource = recoverySource
    editorSaveConflictDraft = replacement
    editorSaveConflict = Org2EditorSaveConflict(file: source.file, canOverwrite: false)
  }

  public func revertLiveFileEditor() {
    cancelLiveFileEditorAutosave(resetStatus: true)
    replaceEditableEntryTextFromModel(selectedEntrySource?.text ?? "")
    liveFileEditorStatusText = "Reverted"
  }

  public func saveLiveFileEditor(explicit: Bool) async {
    _ = OrgSyntaxTextEditorLifecycle.checkpointPendingTextChanges()
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    if explicit {
      cancelLiveFileEditorAutosave(resetStatus: false)
    }

    guard let source = selectedEntrySource, source.isEditable, isLiveFileEditorSelected else {
      if explicit {
        statusText = "No editable file loaded"
      }
      return
    }

    let replacement = editableEntryText
    let draftGeneration = liveFileEditorDraftGeneration

    if explicit {
      isSavingEntry = true
    } else {
      isLiveFileEditorAutosaving = true
    }
    defer {
      if explicit {
        isSavingEntry = false
      } else {
        isLiveFileEditorAutosaving = false
      }
    }

    let request = EditorPersistenceRequest(
      key: editorPersistenceKey(kind: "live-file", file: source.file),
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      expectedOriginal: source.text,
      replacement: replacement
    )
    let outcome = await enqueueEditorPersistence(
      request,
      priority: explicit ? .userInitiated : .utility
    ).value
    guard outcome.succeeded else {
      if case .failed(let message, let isConflict) = outcome {
        errorText = message
        if isConflict {
          if explicit {
            presentEditorSaveConflict(source: source, draft: replacement)
          }
          liveFileEditorStatusText = "Conflict"
          statusText = "Save conflict: file changed on disk"
        } else {
          liveFileEditorStatusText = explicit ? "Save failed" : "Autosave failed"
          if explicit { statusText = "Save failed" }
        }
      }
      return
    }

    guard selectedEntrySource?.id == source.id else {
      return
    }

    selectedEntrySource = Self.entrySource(source, replacingText: replacement)
    liveFileEditorSavedDraftGeneration = draftGeneration
    invalidateCanonicalDocumentCache(for: source.file)
    if let corpusRoot {
      let file = await Task.detached(priority: .utility) {
        Self.corpusFileOffMain(
          for: URL(fileURLWithPath: source.file),
          corpusRoot: corpusRoot
        )
      }.value
      upsertCorpusFile(file)
    }

    if explicit {
      let savedStatus: String
      do {
        let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)
        savedStatus = encryptedCount > 0
          ? "Saved and encrypted \(encryptedCount) subtree\(encryptedCount == 1 ? "" : "s")"
          : "Saved \(relativePath(source.file))"
      } catch {
        recordOrgCryptEncryptionFailure(error, savedPrefix: "Saved, but")
        liveFileEditorStatusText = "Saved"
        scheduleAgendaRefresh(preserveSelection: true)
        return
      }

      statusText = savedStatus
      liveFileEditorStatusText = liveFileEditorDraftGeneration == draftGeneration ? "Saved" : "Unsaved"
      if savedStatus.contains("encrypted"), let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
    } else {
      liveFileEditorStatusText = liveFileEditorDraftGeneration == draftGeneration ? "Autosaved" : "Unsaved"
      scheduleAgendaRefresh(preserveSelection: true)
    }
  }

  func finishSavedEntry(
    source: EntrySource,
    savedText: String,
    keepEditing: Bool
  ) async {
    invalidateCanonicalDocumentCache(for: source.file)
    let savedSource = Self.entrySource(source, replacingText: savedText)
    selectedEntrySource = savedSource
    replaceEditableEntryTextFromModel(savedSource.text)
    sourceEditorLocalDraftText = keepEditing ? savedSource.text : nil
    sourceEditorInteraction.reset(
      text: savedSource.text,
      selection: Self.clampedSourceEditorSelection(sourceEditorSelection, in: savedSource.text)
    )
    sourceEditorSavedDraftGeneration = sourceEditorDraftGeneration
    isEditingEntry = keepEditing
    if !keepEditing, let selectedLocation {
      cancelSourceEditorPreviewRender(clearStatus: true)
      await loadEntrySource(for: selectedLocation)
    } else {
      renderEntrySource(savedSource, generation: entrySourceLoadGeneration)
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  private func scheduleLiveFileEditorAutosave() {
    guard !isPreparingForTermination, isLiveFileEditorAvailable else { return }
    guard liveFileEditorHasUnsavedChanges else {
      cancelLiveFileEditorAutosave(resetStatus: false)
      liveFileEditorStatusText = "Saved"
      return
    }

    liveFileEditorAutosaveTask?.cancel()
    liveFileEditorAutosaveGeneration += 1
    let generation = liveFileEditorAutosaveGeneration
    liveFileEditorAutosaveTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.liveFileEditorAutosaveDelayNanoseconds)
      } catch {
        return
      }
      guard let self,
            !Task.isCancelled,
            self.liveFileEditorAutosaveGeneration == generation
      else {
        return
      }
      await self.saveLiveFileEditor(explicit: false)
    }
  }

  func cancelLiveFileEditorAutosave(resetStatus: Bool) {
    liveFileEditorAutosaveTask?.cancel()
    liveFileEditorAutosaveTask = nil
    liveFileEditorAutosaveGeneration += 1
    if resetStatus {
      liveFileEditorStatusText = ""
    }
  }

  func persistLiveFileEditorDraftBeforeNavigation(
    checkpointedDocumentIdentities suppliedIdentities: Set<String>? = nil
  ) {
    let checkpointedDocumentIdentities = suppliedIdentities
      ?? OrgSyntaxTextEditorLifecycle.checkpointPendingTextChanges()
    guard let source = selectedEntrySource, source.isEditable else { return }

    // The native checkpoint callback owns the exact outgoing contents and
    // carries this source identity across the navigation boundary. Enqueueing
    // the older observable binding here would race it and could create a false
    // file-change conflict.
    if checkpointedDocumentIdentities.contains(source.id) {
      return
    }

    let request: EditorPersistenceRequest?
    if isEditingEntry {
      request = EditorPersistenceRequest(
        key: editorPersistenceKey(kind: "source-editor", file: source.file, identity: source.id),
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.endLineExclusive,
        expectedOriginal: source.text,
        replacement: sourceEditorLocalDraftText ?? sourceEditorInteraction.text
      )
    } else if isLiveFileEditorSelected {
      // A navigation checkpoint owns any native-buffer edit. If there was no
      // checkpoint, only enqueue the observable mirror when local input made
      // this document dirty. Persisting a clean programmatic load can race an
      // external refresh and manufacture a conflict (or an empty overwrite).
      guard liveFileEditorHasUnsavedChanges else { return }
      request = EditorPersistenceRequest(
        key: editorPersistenceKey(kind: "live-file", file: source.file),
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.endLineExclusive,
        expectedOriginal: source.text,
        replacement: editableEntryText
      )
    } else if let block = activeEditingBlock,
              transientDraftBlock?.block.id != block.id {
      let original = activeBlockOriginals[block.id] ?? block
      request = EditorPersistenceRequest(
        key: editorPersistenceKey(kind: "block-editor", file: source.file, identity: block.id),
        file: source.file,
        startLine: original.startLine,
        endLineExclusive: original.endLineExclusive,
        expectedOriginal: original.rawText,
        replacement: saveReplacementText(for: block)
      )
    } else {
      request = nil
    }

    if let request {
      _ = enqueueEditorPersistence(request)
    }
  }

  private func recordOrgCryptEncryptionFailure(_ error: Error, savedPrefix: String?) {
    let message = error.localizedDescription
    errorText = message
    orgCryptStatusText = message
    if case OrgCryptError.missingEncryptionConfiguration = error {
      statusText = [savedPrefix, "encryption needs configuration"].compactMap(\.self).joined(separator: " ")
      isOrgCryptConfigurationPresented = true
      return
    }
    statusText = [savedPrefix, "encryption failed"].compactMap(\.self).joined(separator: " ")
  }

  func requestSaveRenderedTableView(_ snapshot: OrgHTMLTableViewSnapshot) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This table is read-only"
      return
    }
    guard !isEditingEntry else {
      statusText = "Save or close source editing before saving a table view"
      return
    }
    let blocks = selectedRenderedBlocks
    let revision = entrySourceRenderIdentities[source.id]
    Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        let candidates = blocks.isEmpty
          ? OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
          : blocks
        guard let block = candidates.first(where: { candidate in
          guard candidate.startLine == snapshot.startLine,
                candidate.endLineExclusive - 1 == snapshot.endLine
          else { return false }
          if case .table = candidate.rendered { return true }
          return false
        }) else {
          return RenderedTableSavePlanResult.failure(
            "The table changed; refresh the file and try again"
          )
        }
        guard let replacement = OrgRenderedTableViewMutation.replacement(
          rawText: block.rawText,
          visibleBodyRowIndices: snapshot.visibleBodyRowIndices,
          expectedBodyRowCount: snapshot.totalBodyRowCount
        ) else {
          return .failure("Could not map this view back to the source table")
        }
        let normalizedReplacement = Self.normalizeLineEndings(replacement)
        guard normalizedReplacement != Self.normalizeLineEndings(block.rawText) else {
          return .failure("The source table already matches this view")
        }
        do {
          return .success(RenderedTableSavePlan(
            block: block,
            replacement: normalizedReplacement,
            updatedSource: try Self.replacingSourceBlock(
              block,
              in: source,
              with: normalizedReplacement
            ),
            hiddenRowCount: max(
              0,
              snapshot.totalBodyRowCount - snapshot.visibleBodyRowIndices.count
            ),
            sourceRevision: revision
          ))
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value
      guard let self else { return }
      guard case .success(let plan) = result else {
        if case .failure(let message) = result { self.statusText = message }
        return
      }
      guard self.selectedEntrySource?.id == source.id,
            self.entrySourceRenderIdentities[source.id] == plan.sourceRevision
      else {
        self.statusText = "The table changed; refresh the file and try again"
        return
      }

      let alert = NSAlert()
      alert.alertStyle = plan.hiddenRowCount > 0 ? .warning : .informational
      alert.messageText = "Save this table view to the source?"
      var details: [String] = []
      if snapshot.sortActive {
        details.append("The source rows will use the current sort order.")
      }
      if plan.hiddenRowCount > 0 {
        details.append(
          "The source will keep the \(snapshot.visibleBodyRowIndices.count) visible row\(snapshot.visibleBodyRowIndices.count == 1 ? "" : "s") and remove \(plan.hiddenRowCount) filtered row\(plan.hiddenRowCount == 1 ? "" : "s")."
        )
      }
      details.append("The header is preserved, and the change can be undone from the Edit menu.")
      alert.informativeText = details.joined(separator: " ")
      alert.addButton(withTitle: "Save View")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      await self.saveRenderedTableView(plan, in: source)
    }
  }

  func requestRecalculateRenderedTableFormulas(at startLine: Int) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This table is read-only"
      return
    }
    guard !isEditingEntry else {
      statusText = "Save or close source editing before recalculating a table"
      return
    }
    guard !isSavingBlock else {
      statusText = "Another source update is still in progress"
      return
    }

    Task { @MainActor [weak self, source] in
      guard let self, self.selectedEntrySource?.id == source.id else { return }
      self.isSavingBlock = true
      defer { self.isSavingBlock = false }
      do {
        let undoSnapshot = await self.fileUndoSnapshot(for: source.file)
        guard let context = self.captureDocumentCorpusContext(forFile: source.file) else {
          throw WorkspaceDocumentMutationError.outsideCorpus(
            file: source.file,
            root: self.corpusRoot?.path ?? "(none)"
          )
        }
        let cli = self.cli
        _ = try await self.performDocumentMutation(context: context, files: [source.file]) { _ in
          try await cli.run([
            "table", "recalculate",
            "--file", source.file,
            "--line", String(startLine),
            "--apply", "--format", "json",
          ])
        }
        guard self.isCurrentDocumentCorpusContext(context) else { return }
        await self.recordFileUndo(from: undoSnapshot)
        self.invalidateCanonicalDocumentCache(for: source.file)
        let staleRenderKey = self.entryHTMLRenderKey(for: source)
        self.releaseWorkspaceCacheBoxesOffMain(
          self.renderedHTMLCache.removeValue(forKey: staleRenderKey).map { [$0] } ?? []
        )
        self.renderedHTMLCacheOrder.removeAll { $0 == staleRenderKey }
        if let selectedLocation = self.selectedLocation {
          await self.loadEntrySource(for: selectedLocation)
        }
        self.statusText = "Recalculated table formulas at line \(startLine)"
        self.scheduleAgendaRefresh(preserveSelection: true)
      } catch {
        self.errorText = error.localizedDescription
        self.statusText = "Could not recalculate table formulas"
      }
    }
  }

  private func saveRenderedTableView(
    _ plan: RenderedTableSavePlan,
    in source: EntrySource
  ) async {
    guard selectedEntrySource?.id == source.id else {
      statusText = "The selected file changed before the table view could be saved"
      return
    }
    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: plan.block.startLine,
        endLineExclusive: plan.block.endLineExclusive,
        replacement: plan.replacement,
        expectedOriginal: plan.block.rawText
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
        selectedEntrySource = plan.updatedSource
        renderEntrySource(plan.updatedSource, generation: entrySourceLoadGeneration)
      }
      statusText = "Saved table view to \(relativePath(source.file)):\(plan.block.displayRange)"
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not save table view"
    }
  }

  public func saveEditedBlock(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }

    if let draft = transientDraftBlock, draft.block.id == block.id {
      await saveTransientDraftBlock(draft)
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let replacement = Self.normalizeLineEndings(saveReplacementText(for: block))
      let sourceBlock = activeBlockOriginals[block.id] ?? block
      if await finalizeDeferredStableAutosaveIfCurrent(
        block,
        source: source,
        sourceBlock: sourceBlock,
        replacement: replacement
      ) {
        return
      }

      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      let updatedSource = try await Task.detached(priority: .userInitiated) {
        try Self.replacingSourceBlock(
          sourceBlock,
          in: source,
          with: replacement
        )
      }.value
      let currentRenderedBlocks = selectedRenderedBlocks
      try await replaceDocumentSourceRange(
        file: source.file,
        startLine: sourceBlock.startLine,
        endLineExclusive: sourceBlock.endLineExclusive,
        replacement: replacement,
        expectedOriginal: sourceBlock.rawText
      )
      let encryptedCount = try await encryptOrgCryptSubtreesAfterExplicitSave(file: source.file)

      if encryptedCount > 0 {
        await recordFileUndo(from: undoSnapshot)
        guard selectedEntrySource?.id == source.id else { return }
        deferredStableAutosaves.removeValue(forKey: block.id)
        invalidateCanonicalDocumentCache(for: source.file)
        resetBlockEditing()
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
          with: replacement
        )
      }.value

      guard selectedEntrySource?.id == source.id else {
        await recordFileUndo(from: undoSnapshot)
        return
      }

      await recordFileUndo(from: undoSnapshot)
      deferredStableAutosaves.removeValue(forKey: block.id)
      invalidateCanonicalDocumentCache(for: source.file)
      selectedEntrySource = updatedSource
      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      selectedRenderedBlocks = updatedVisibleBlocks
      selectedBlockID = blockForSelectionLine(
        sourceBlock.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )?.id
      statusText = "Saved block \(relativePath(source.file)):\(sourceBlock.displayRange)"
      resetBlockEditing()
      scheduleAgendaRefresh(preserveSelection: true)
    } catch {
      errorText = error.localizedDescription
      statusText = "Block save failed"
    }
  }

  private func finalizeDeferredStableAutosaveIfCurrent(
    _ block: OrgEditableBlock,
    source: EntrySource,
    sourceBlock: OrgEditableBlock,
    replacement: String
  ) async -> Bool {
    guard let deferred = deferredStableAutosaves[block.id],
          Self.normalizeLineEndings(deferred.block.rawText) == replacement
    else {
      return false
    }
    let file = source.file
    let startLine = deferred.block.startLine
    let endLineExclusive = deferred.block.endLineExclusive
    let fileText = await Task.detached(priority: .userInitiated) {
      try? Self.sourceText(
            file: file,
            startLine: startLine,
            endLineExclusive: endLineExclusive
          )
    }.value
    guard let fileText,
          Self.normalizeLineEndings(fileText) == replacement
    else {
      return false
    }

    deferredStableAutosaves.removeValue(forKey: block.id)
    if selectedEntrySource?.id == source.id {
      selectedEntrySource = deferred.source
    }
    let updatedBlocks = Self.replacingBlock(
      selectedBlock,
      with: deferred.block,
      in: selectedRenderedBlocks
    )
    setSelectedRenderedBlocks(updatedBlocks, preservingMetadata: true)
    selectedBlockID = deferred.block.id
    invalidateCanonicalDocumentCache(for: source.file)
    statusText = "Saved block \(relativePath(source.file)):\(sourceBlock.displayRange)"
    resetBlockEditing()
    return true
  }

  public func autosaveEditedBlock(_ block: OrgEditableBlock, replacement: String) async {
    guard let source = selectedEntrySource, source.isEditable else { return }
    guard editingBlockID == block.id else { return }
    guard transientDraftBlock?.block.id != block.id else { return }

    let normalizedReplacement = Self.normalizeLineEndings(replacement)
    guard normalizedReplacement != block.rawText else { return }
    guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
      return
    }

    do {
      let updatedSource = try await Task.detached(priority: .utility) {
        try Self.replacingSourceBlock(
          block,
          in: source,
          with: normalizedReplacement
        )
      }.value
      let request = EditorPersistenceRequest(
        key: editorPersistenceKey(
          kind: "block-editor",
          file: source.file,
          identity: block.id
        ),
        file: source.file,
        startLine: block.startLine,
        endLineExclusive: block.endLineExclusive,
        expectedOriginal: block.rawText,
        replacement: normalizedReplacement
      )
      let outcome = await enqueueEditorPersistence(request).value
      guard outcome.succeeded else {
        if case .failed(let message, _) = outcome {
          errorText = message
        }
        statusText = "Autosave failed"
        return
      }
      guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
        return
      }

      let currentRenderedBlocks = selectedRenderedBlocks
      let updatedBlocks = await Task.detached(priority: .utility) {
        Self.locallyUpdatingRenderedBlocks(
          currentRenderedBlocks,
          replacing: block,
          with: normalizedReplacement
        )
      }.value
      guard isCurrentAutosaveDraft(block, in: source, replacement: normalizedReplacement) else {
        return
      }

      let updatedVisibleBlocks = blocksWithTransientDraft(updatedBlocks, for: updatedSource)
      let parsedUpdatedBlock = blockForSelectionLine(
        block.startLine,
        mode: .containingOrNearest,
        in: updatedVisibleBlocks
      )
      let updatedBlock = parsedUpdatedBlock?.preservingID(block.id)
      let renderedBlocks = Self.replacingBlock(
        parsedUpdatedBlock,
        with: updatedBlock,
        in: updatedVisibleBlocks
      )
      if shouldPreserveRenderedBlockMetadata(
        original: block,
        updated: updatedBlock,
        renderedBlocks: renderedBlocks
      ), let updatedBlock {
        invalidateCanonicalDocumentCache(for: source.file)
        deferredStableAutosaves[block.id] = DeferredStableAutosave(
          source: updatedSource,
          block: updatedBlock
        )
        activeBlockDrafts[updatedBlock.id] = normalizedReplacement
        pendingAgendaRefreshAfterBlockEditing = true
        return
      }

      invalidateCanonicalDocumentCache(for: source.file)
      selectedEntrySource = updatedSource
      setSelectedRenderedBlocks(
        renderedBlocks,
        preservingMetadata: shouldPreserveRenderedBlockMetadata(
          original: block,
          updated: updatedBlock,
          renderedBlocks: renderedBlocks
        )
      )
      if selectedBlockID != updatedBlock?.id {
        selectedBlockID = updatedBlock?.id
      }
      if editingBlockID != updatedBlock?.id {
        editingBlockID = updatedBlock?.id
      }
      if editableBlockText != normalizedReplacement {
        editableBlockText = normalizedReplacement
      }
      if let updatedBlock {
        activeBlockDrafts[updatedBlock.id] = normalizedReplacement
      }
      pendingAgendaRefreshAfterBlockEditing = true
    } catch {
      errorText = error.localizedDescription
      statusText = "Autosave failed"
    }
  }

  func setSelectedRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    preservingMetadata: Bool
  ) {
    if preservingMetadata {
      preservesSelectedRenderedBlocksMetadataForNextAssignment = true
    }
    selectedRenderedBlocks = blocks
    foldedRenderedBlockIDs = OrgRenderedFoldTree.prunedFoldedIDs(foldedRenderedBlockIDs, blocks: blocks)
  }

  private func shouldPreserveRenderedBlockMetadata(
    original: OrgEditableBlock,
    updated: OrgEditableBlock?,
    renderedBlocks: [OrgEditableBlock]
  ) -> Bool {
    guard let updated else { return false }
    return updated.id == original.id
      && updated.startLine == original.startLine
      && updated.endLineExclusive == original.endLineExclusive
      && renderedBlocks.count == selectedRenderedBlocks.count
      && selectedRenderedBlockIndexes[updated.id] != nil
  }

  private func isCurrentAutosaveDraft(
    _ block: OrgEditableBlock,
    in source: EntrySource,
    replacement: String
  ) -> Bool {
    selectedEntrySource?.id == source.id
      && editingBlockID == block.id
      && Self.normalizeLineEndings(activeBlockDrafts[block.id] ?? "") == replacement
  }

  func saveReplacementText(for block: OrgEditableBlock) -> String {
    editingDraftText(for: block)
  }

  func editingDraftText(for block: OrgEditableBlock) -> String {
    if let draft = activeBlockDrafts[block.id],
       draft != block.rawText {
      return draft
    }
    if editableBlockText != block.rawText {
      return editableBlockText
    }
    return activeBlockDrafts[block.id] ?? editableBlockText
  }

  public func splitEditingBlock(_ block: OrgEditableBlock, atUTF16Offset offset: Int, draftText: String? = nil) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    guard editingBlockID == block.id else {
      statusText = "Block edit is no longer active"
      return
    }
    let activeTransientDraft = transientDraftBlock?.block.id == block.id ? transientDraftBlock : nil
    let sourceBlock = activeTransientDraft == nil ? activeBlockOriginals[block.id] ?? block : block
    guard block.isEditable,
          sourceBlock.startLine >= source.startLine,
          sourceBlock.endLineExclusive <= source.endLineExclusive || activeTransientDraft != nil
    else {
      statusText = "Block cannot be split"
      return
    }
    let draft = draftText ?? editingDraftText(for: block)
    guard let plan = Self.splitBlockPlan(for: block, draft: draft, utf16Offset: offset) else {
      statusText = "Block cannot be split"
      return
    }
    if let activeTransientDraft {
      await splitTransientDraftBlock(activeTransientDraft, originalBlock: block, plan: plan)
      return
    }

    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: source.file)
      if let replacement = plan.replacement {
        try await replaceDocumentSourceRange(
          file: source.file,
          startLine: sourceBlock.startLine,
          endLineExclusive: sourceBlock.endLineExclusive,
          replacement: replacement,
          expectedOriginal: sourceBlock.rawText
        )
        await recordFileUndo(from: undoSnapshot)
        invalidateCanonicalDocumentCache(for: source.file)
      }
      isEditingEntry = false

      let draftToActivate: TransientDraftBlock?
      if let draftSpec = plan.draft {
        let draft = transientDraftBlock(
          from: draftSpec,
          sourceFile: source.file,
          originalBlock: sourceBlock
        )
        transientDraftBlock = draft
        draftToActivate = draft
        statusText = "Started draft in \(relativePath(source.file))"
      } else if let newBlockLineOffset = plan.newBlockLineOffset {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
        pendingBlockSelection = PendingBlockSelection(
          file: source.file,
          line: sourceBlock.startLine + newBlockLineOffset,
          mode: .containingOrNearest,
          beginEditing: true
        )
        statusText = "Split block in \(relativePath(source.file))"
      } else {
        draftToActivate = nil
      }

      if plan.replacement != nil, let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      if let draftToActivate {
        activateTransientDraft(draftToActivate)
      }
      if plan.replacement != nil {
        scheduleAgendaRefresh(preserveSelection: true)
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Split failed"
    }
  }

  private func splitTransientDraftBlock(
    _ activeDraft: TransientDraftBlock,
    originalBlock block: OrgEditableBlock,
    plan: SplitBlockPlan
  ) async {
    isSavingBlock = true
    defer { isSavingBlock = false }

    do {
      let undoSnapshot = await fileUndoSnapshot(for: activeDraft.file)
      if let replacementBody = plan.replacement {
        let replacement = "\(activeDraft.replacementPrefix)\(replacementBody)\(activeDraft.replacementSuffix)"
        try await replaceDocumentSourceRange(
          file: activeDraft.file,
          startLine: activeDraft.insertionLine,
          endLineExclusive: activeDraft.replacementEndLineExclusive,
          replacement: replacement
        )
        await recordFileUndo(from: undoSnapshot)
        invalidateCanonicalDocumentCache(for: activeDraft.file)
      }

      selectedRenderedBlocks.removeAll { $0.id == activeDraft.block.id }
      activeBlockDrafts.removeValue(forKey: activeDraft.block.id)
      activeBlockOriginals.removeValue(forKey: activeDraft.block.id)
      isEditingEntry = false
      let bodyLineOffset = Self.lineBreakCount(in: activeDraft.replacementPrefix)

      let draftToActivate: TransientDraftBlock?
      if let draftSpec = plan.draft {
        let draftBaseBlock = bodyLineOffset == 0
          ? block
          : Self.shiftedBlock(block, by: bodyLineOffset)
        let nextDraft = transientDraftBlock(
          from: draftSpec,
          sourceFile: activeDraft.file,
          originalBlock: draftBaseBlock
        )
        transientDraftBlock = nextDraft
        draftToActivate = nextDraft
        statusText = "Started draft in \(relativePath(activeDraft.file))"
      } else if let newBlockLineOffset = plan.newBlockLineOffset {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
        pendingBlockSelection = PendingBlockSelection(
          file: activeDraft.file,
          line: block.startLine + bodyLineOffset + newBlockLineOffset,
          mode: .containingOrNearest,
          beginEditing: true
        )
        statusText = "Split block in \(relativePath(activeDraft.file))"
      } else {
        draftToActivate = nil
        transientDraftBlock = nil
        resetBlockEditing()
      }

      if plan.replacement != nil, let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      if let draftToActivate {
        activateTransientDraft(draftToActivate)
      }
      if plan.replacement != nil {
        scheduleAgendaRefresh(preserveSelection: true)
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Split failed"
    }
  }
}
