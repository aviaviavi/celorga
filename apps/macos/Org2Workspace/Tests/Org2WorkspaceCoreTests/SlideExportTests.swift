import AppKit
import PDFKit
import XCTest
@testable import Org2WorkspaceCore

final class SlideExportTests: XCTestCase {
  func testSlideExportFormatMetadata() {
    XCTAssertEqual(Org2SlideExportFormat.pdf.fileExtension, "pdf")
    XCTAssertEqual(Org2SlideExportFormat.pdf.title, "PDF")
    XCTAssertEqual(Org2SlideExportFormat.latex.fileExtension, "tex")
    XCTAssertEqual(Org2SlideExportFormat.latex.title, "LaTeX")
  }

  func testDocumentPreviewKindMetadata() {
    XCTAssertEqual(OrgDocumentPreviewKind.document.title, "Document")
    XCTAssertEqual(OrgDocumentPreviewKind.document.systemImage, "doc.richtext")
    XCTAssertEqual(OrgDocumentPreviewKind.slides.title, "Slides")
    XCTAssertEqual(OrgDocumentPreviewKind.slides.systemImage, "rectangle.on.rectangle")
    XCTAssertEqual(OrgDocumentPreviewPreference.automatic.title, "Automatic")
    XCTAssertEqual(OrgDocumentPreviewPreference.automatic.systemImage, "wand.and.stars")
  }

  @MainActor
  func testAutomaticPreviewInferenceAndOverridesAreScopedPerDocument() {
    let suiteName = "Org2SlidePreviewPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory),
      defaults: defaults
    )
    let talk = EntrySource(
      file: "/tmp/talk.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "#+LATEX_CLASS: beamer\n* Slide\n",
      isSubtree: false
    )
    let note = EntrySource(
      file: "/tmp/note.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "#+TITLE: Note\n* Heading\n",
      isSubtree: false
    )

    store.selectedEntrySource = talk
    store.updateInferredDocumentPreviewKind(
      from: #"<meta name="org2-document-kind" content="slides" />"#
    )
    XCTAssertEqual(store.documentPreviewPreference, .automatic)
    XCTAssertEqual(store.documentPreviewKind, .slides)

    XCTAssertTrue(store.showsSlideActions)

    store.selectedEntrySource = note
    store.updateInferredDocumentPreviewKind(
      from: #"<meta name="org2-document-kind" content="document" />"#
    )
    XCTAssertEqual(store.documentPreviewKind, .document)
    XCTAssertFalse(store.showsSlideActions)

    store.selectedEntrySource = talk
    XCTAssertEqual(store.documentPreviewKind, .slides)
    store.setDocumentPreviewPreference(.document)
    XCTAssertEqual(store.documentPreviewKind, .document)

    store.selectedEntrySource = note
    XCTAssertEqual(store.documentPreviewPreference, .automatic)
    store.selectedEntrySource = talk
    XCTAssertEqual(store.documentPreviewPreference, .document)
    XCTAssertEqual(store.documentPreviewKind, .document)

    let restoredStore = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory),
      defaults: defaults
    )
    restoredStore.selectedEntrySource = talk
    restoredStore.updateInferredDocumentPreviewKind(
      from: #"<meta name="org2-document-kind" content="slides" />"#
    )
    XCTAssertEqual(restoredStore.documentPreviewPreference, .document)
    XCTAssertEqual(restoredStore.documentPreviewKind, .document)

    store.setDocumentPreviewPreference(.automatic)
    XCTAssertEqual(store.documentPreviewKind, .slides)
  }

  func testSlideSourceLineMarkerURLParsing() {
    XCTAssertEqual(
      OrgPDFDocumentView.sourceLine(from: URL(string: "org2-source-line://417")),
      417
    )
    XCTAssertNil(OrgPDFDocumentView.sourceLine(from: URL(string: "https://example.com/417")))
    XCTAssertNil(OrgPDFDocumentView.sourceLine(from: URL(string: "org2-source-line://0")))
  }

  @MainActor
  func testSlidePreviewRestoresTheSavedPageAcrossPDFReplacementAndViewRecreation() throws {
    let initialPDF = try makeSlideDeckPDF(sourceLines: [10, 20, 30, 40, 50, 60])
    let refreshedPDF = try makeSlideDeckPDF(sourceLines: [10, 20, 30, 40, 50, 70])
    var reportedLine: Int?
    var reportedPageIndex: Int?
    var reportedPageIndexes: [Int?] = []
    let initialView = OrgPDFDocumentView(
      data: initialPDF,
      reportViewportSourceLine: { reportedLine = $0 },
      reportViewportPageIndex: {
        reportedPageIndex = $0
        reportedPageIndexes.append($0)
      }
    )
    let coordinator = initialView.makeCoordinator()
    let pdfView = PDFView()
    initialView.update(pdfView, coordinator: coordinator)
    pdfView.go(to: try XCTUnwrap(pdfView.document?.page(at: 4)))
    coordinator.reportCurrentPage(in: pdfView)

    XCTAssertEqual(reportedLine, 50)
    XCTAssertEqual(reportedPageIndex, 4)
    reportedPageIndexes = []

    let refreshedView = OrgPDFDocumentView(
      data: refreshedPDF,
      restorationSourceLine: 50,
      restorationPageIndex: 4,
      reportViewportSourceLine: { reportedLine = $0 },
      reportViewportPageIndex: { reportedPageIndex = $0 }
    )
    refreshedView.update(pdfView, coordinator: coordinator)

    XCTAssertEqual(pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }, 4)
    XCTAssertEqual(reportedLine, 50)
    XCTAssertEqual(reportedPageIndex, 4)
    XCTAssertEqual(reportedPageIndexes, [4])

    let recreatedCoordinator = refreshedView.makeCoordinator()
    let recreatedPDFView = PDFView()
    refreshedView.update(recreatedPDFView, coordinator: recreatedCoordinator)

    XCTAssertEqual(
      recreatedPDFView.currentPage.flatMap { recreatedPDFView.document?.index(for: $0) },
      4
    )
  }

  @MainActor
  func testSlidePreviewSourceLineJumpReusesCompiledPDF() throws {
    let pdf = try makeSlideDeckPDF(sourceLines: [10, 30, 60])
    var reportedLine: Int?
    let initialView = OrgPDFDocumentView(
      data: pdf,
      scrollRequest: DetailScrollRequest(id: 1, target: .sourceLine(58)),
      reportViewportSourceLine: { reportedLine = $0 }
    )
    let coordinator = initialView.makeCoordinator()
    let pdfView = PDFView()
    initialView.update(pdfView, coordinator: coordinator)
    let compiledDocument = try XCTUnwrap(pdfView.document)

    XCTAssertEqual(pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }, 2)
    XCTAssertEqual(reportedLine, 60)

    let jumpedView = OrgPDFDocumentView(
      data: pdf,
      scrollRequest: DetailScrollRequest(id: 2, target: .sourceLine(12)),
      reportViewportSourceLine: { reportedLine = $0 }
    )
    jumpedView.update(pdfView, coordinator: coordinator)

    XCTAssertTrue(pdfView.document === compiledDocument)
    XCTAssertEqual(pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }, 0)
    XCTAssertEqual(reportedLine, 10)
  }

  @MainActor
  func testSlidePreviewPageNavigationReusesCompiledPDF() throws {
    let pdf = try makeSlideDeckPDF(sourceLines: [10, 20, 30])
    var reportedPageCount = 0
    var reportedPageIndex: Int?
    let initialView = OrgPDFDocumentView(
      data: pdf,
      reportViewportPageIndex: { reportedPageIndex = $0 },
      reportPageCount: { reportedPageCount = $0 }
    )
    let coordinator = initialView.makeCoordinator()
    let pdfView = PDFView()
    initialView.update(pdfView, coordinator: coordinator)
    let compiledDocument = try XCTUnwrap(pdfView.document)

    XCTAssertEqual(reportedPageCount, 3)
    XCTAssertEqual(reportedPageIndex, 0)

    let nextView = OrgPDFDocumentView(
      data: pdf,
      navigationRequest: OrgPDFPageNavigationRequest(id: 1, target: .next),
      reportViewportPageIndex: { reportedPageIndex = $0 }
    )
    nextView.update(pdfView, coordinator: coordinator)

    XCTAssertTrue(pdfView.document === compiledDocument)
    XCTAssertEqual(reportedPageIndex, 1)

    let exactView = OrgPDFDocumentView(
      data: pdf,
      navigationRequest: OrgPDFPageNavigationRequest(id: 2, target: .page(2)),
      reportViewportPageIndex: { reportedPageIndex = $0 }
    )
    exactView.update(pdfView, coordinator: coordinator)
    XCTAssertEqual(reportedPageIndex, 2)
  }

  func testSlidePreviewZoomStepsIncludeFitAndClampAtEnds() {
    XCTAssertEqual(WorkspaceStore.previousSlidePreviewZoomScale(before: 1), 0.875)
    XCTAssertEqual(WorkspaceStore.nextSlidePreviewZoomScale(after: 1), 1.25)
    XCTAssertEqual(WorkspaceStore.previousSlidePreviewZoomScale(before: 0.4), 0.4)
    XCTAssertEqual(WorkspaceStore.nextSlidePreviewZoomScale(after: 4), 4)
  }

  func testOrg2CLIIncludesMacTeXInChildProcessPath() {
    let path = Org2CLI.processEnvironment()["PATH"] ?? ""
    XCTAssertTrue(path.split(separator: ":").contains("/Library/TeX/texbin"))
  }

  @MainActor
  func testWorkspaceOffersSlideExportOnlyForOrgFiles() {
    let suiteName = "Org2SlideExportTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory),
      defaults: defaults
    )

    store.selectedEntrySource = EntrySource(
      file: "/tmp/talk.org2",
      startLine: 1,
      endLineExclusive: 2,
      text: "* Slide\n",
      isSubtree: false
    )
    XCTAssertTrue(store.canExportSlides)
    XCTAssertTrue(store.canPreviewSlides)

    store.selectedEntrySource = EntrySource(
      file: "/tmp/notes.md",
      startLine: 1,
      endLineExclusive: 2,
      text: "# Notes\n",
      isSubtree: false
    )
    XCTAssertFalse(store.canExportSlides)
    XCTAssertFalse(store.canPreviewSlides)
  }

  @MainActor
  func testWorkspaceOffersCurrentDocumentPDFExportOnlyForOrgFiles() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )

    store.selectedEntrySource = EntrySource(
      file: "/tmp/notes.org2",
      startLine: 8,
      endLineExclusive: 12,
      text: "* Selected entry\n",
      isSubtree: true
    )
    XCTAssertTrue(store.canExportCurrentDocumentPDF)

    store.selectedEntrySource = EntrySource(
      file: "/tmp/notes.md",
      startLine: 1,
      endLineExclusive: 2,
      text: "# Notes\n",
      isSubtree: false
    )
    XCTAssertFalse(store.canExportCurrentDocumentPDF)
  }

  @MainActor
  func testCurrentDocumentPDFExportRendersTheEntireFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-document-pdf-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("notes.org2")
    let destination = root.appendingPathComponent("notes.pdf")
    try """
    #+TITLE: Full document
    * First section
    Content outside the selected entry.
    * Selected entry
    Export this too.
    """.write(to: source, atomically: true, encoding: .utf8)

    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    )
    store.selectedEntrySource = EntrySource(
      file: source.path,
      startLine: 4,
      endLineExclusive: 6,
      text: "* Selected entry\nExport this too.\n",
      isSubtree: true
    )
    var renderedHTML = ""
    var renderedBaseURL: URL?
    store.documentPDFRendererForTesting = { html, baseURL in
      renderedHTML = html
      renderedBaseURL = baseURL
      return Data("%PDF-1.4\n% test\n".utf8)
    }

    try await store.exportCurrentDocumentPDF(sourceFile: source, destination: destination)

    XCTAssertTrue(renderedHTML.contains("Full document"))
    XCTAssertTrue(renderedHTML.contains("First section"))
    XCTAssertTrue(renderedHTML.contains("Selected entry"))
    XCTAssertEqual(renderedBaseURL, root)
    XCTAssertTrue(try Data(contentsOf: destination).starts(with: Data("%PDF".utf8)))
  }

  @MainActor
  func testSuccessfulDocumentPDFExportOpensTheFile() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/notes.pdf")
    var openedURL: URL?
    store.documentPDFExportFileOpenerForTesting = { url in
      openedURL = url
      return true
    }

    store.finishSuccessfulDocumentPDFExport(destination: destination)

    XCTAssertEqual(openedURL, destination)
    XCTAssertEqual(store.statusText, "Exported and opened notes.pdf")
    XCTAssertNil(store.exportNotice)
    XCTAssertNil(store.errorText)
  }

  func testOrg2CLIRendersPresentationPDFFromStandardInput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slide-preview-cli-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    const fs = require("fs");
    fs.writeFileSync("arguments.json", JSON.stringify(process.argv.slice(2)));
    fs.writeFileSync("input.org2", fs.readFileSync(0));
    process.stdout.write("%PDF-1.4\\n");
    """.write(
      to: dist.appendingPathComponent("render-presentation-pdf.js"),
      atomically: true,
      encoding: .utf8
    )

    let cli = Org2CLI(repoRoot: root)
    let sourcePath = "/tmp/unsaved-talk.org2"
    let draft = "#+TITLE: Unsaved\n* Section\n** Draft slide\n"
    let pdf = try await cli.renderPresentationPDF(
      draft,
      sourcePath: sourcePath,
      passes: 1
    )

    XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("input.org2"), encoding: .utf8),
      draft
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        [String].self,
        from: Data(contentsOf: root.appendingPathComponent("arguments.json"))
      ),
      ["--source-path", sourcePath, "--passes", "1"]
    )
  }

  @MainActor
  func testLiveSlidePreviewKeepsLastSuccessfulPDFWhenDraftFails() async throws {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let source = EntrySource(
      file: "/tmp/talk.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "#+TITLE: Talk\n* Section\n** Initial\n",
      isSubtree: false
    )
    let expectedPDF = Data("%PDF-1.4\npreview".utf8)
    let recorder = SlidePreviewRecorder(pdf: expectedPDF)
    store.slidePreviewRendererForTesting = { text, sourcePath, passes in
      try await recorder.render(text: text, sourcePath: sourcePath, passes: passes)
    }
    store.selectedEntrySource = source
    store.beginEditingSelectedEntry()
    store.sourceEditorPresentation = .split
    store.setDocumentPreviewPreference(.slides)

    let validDraft = "#+TITLE: Talk\n* Section\n** Live draft\n"
    store.editableEntryText = validDraft
    store.scheduleSourceEditorPreview(immediate: true)
    try await waitForSlidePreview(store) { $0.slidePreviewPDF == expectedPDF }

    let invalidDraft = "#+TITLE: Talk\n* Section\nBROKEN\n"
    store.editableEntryText = invalidDraft
    store.scheduleSourceEditorPreview(immediate: true)
    try await waitForSlidePreview(store) { $0.slidePreviewError != nil }

    XCTAssertEqual(store.slidePreviewPDF, expectedPDF)
    XCTAssertEqual(store.slidePreviewError, "Draft could not compile")
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls.map(\.text), [validDraft, invalidDraft])
    XCTAssertTrue(calls.allSatisfy { $0.sourcePath == source.file && $0.passes == 1 })
  }

  @MainActor
  func testRenderedDocumentSlidePreviewUsesSelectedSourceOutsideEditMode() async throws {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let source = EntrySource(
      file: "/tmp/rendered-talk.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "#+TITLE: Talk\n* Section\n** Rendered slide\n",
      isSubtree: false
    )
    let expectedPDF = Data("%PDF-1.4\nrendered-preview".utf8)
    let recorder = SlidePreviewRecorder(pdf: expectedPDF)
    store.slidePreviewRendererForTesting = { text, sourcePath, passes in
      try await recorder.render(text: text, sourcePath: sourcePath, passes: passes)
    }
    store.selectedEntrySource = source
    store.setDocumentPreviewPreference(.slides)

    XCTAssertFalse(store.isEditingEntry)
    store.scheduleSlidePreview(text: source.text, source: source, immediate: true)
    try await waitForSlidePreview(store) { $0.slidePreviewPDF == expectedPDF }

    store.setSlidePreviewPageCount(3)
    XCTAssertTrue(store.handleGlobalKeyDown(slideKeyDown("-", keyCode: 27, modifiers: [.command])))
    XCTAssertEqual(store.slidePreviewZoomScale, 0.875)
    XCTAssertFalse(store.handleGlobalKeyDown(
      slideKeyDown("-", keyCode: 27, modifiers: [.command]),
      scope: .globalOnly
    ))
    XCTAssertTrue(store.handleWorkspaceKeyDown(slideKeyDown("→", keyCode: 124)))
    XCTAssertEqual(store.slidePreviewNavigationRequest?.target, .next)

    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls.map(\.text), [source.text])
    XCTAssertTrue(calls.allSatisfy { $0.sourcePath == source.file && $0.passes == 1 })
  }

  func testOrg2CLIExportsBeamerPDFWithApplyFlag() async throws {
    try await assertExportArguments(
      format: .pdf,
      expectedTail: ["--pdf", "--format", "json", "--apply"]
    )
  }

  func testOrg2CLIExportsBeamerLatexWithoutPDFFlag() async throws {
    try await assertExportArguments(
      format: .latex,
      expectedTail: ["--format", "json", "--apply"]
    )
  }

  @MainActor
  func testSuccessfulPDFExportOpensTheDeckAutomatically() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.pdf")
    var openedURL: URL?
    store.slideExportFileOpenerForTesting = { url in
      openedURL = url
      return true
    }

    store.finishSuccessfulSlideExport(format: .pdf, destination: destination)

    XCTAssertEqual(openedURL, destination)
    XCTAssertEqual(store.statusText, "Exported and opened talk.pdf")
    XCTAssertNil(store.exportNotice)
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testSuccessfulLatexExportDoesNotOpenTheFile() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.tex")
    var didAttemptOpen = false
    store.slideExportFileOpenerForTesting = { _ in
      didAttemptOpen = true
      return true
    }

    store.finishSuccessfulSlideExport(format: .latex, destination: destination)

    XCTAssertFalse(didAttemptOpen)
    XCTAssertEqual(store.statusText, "Exported slides to talk.tex")
    XCTAssertEqual(store.exportNotice?.message, destination.path)
  }

  @MainActor
  func testPDFOpenFailureKeepsTheSuccessfulExport() {
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory)
    )
    let destination = URL(fileURLWithPath: "/tmp/talk.pdf")
    store.slideExportFileOpenerForTesting = { _ in false }

    store.finishSuccessfulSlideExport(format: .pdf, destination: destination)

    XCTAssertTrue(store.statusText.contains("but couldn’t open the PDF"))
    XCTAssertEqual(store.exportNotice?.title, "Slides Exported")
    XCTAssertTrue(store.exportNotice?.message.contains("was saved") == true)
    XCTAssertNil(store.errorText)
  }

  private func assertExportArguments(
    format: Org2SlideExportFormat,
    expectedTail: [String]
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slide-export-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("talk.org2")
    let destination = root.appendingPathComponent("talk.\(format.fileExtension)")
    try "* Slide\n".write(to: source, atomically: true, encoding: .utf8)
    try """
    const fs = require("fs");
    fs.writeFileSync("arguments.json", JSON.stringify(process.argv.slice(2)));
    """.write(
      to: dist.appendingPathComponent("cli.js"),
      atomically: true,
      encoding: .utf8
    )

    let argumentsFile = root.appendingPathComponent("arguments.json")
    let cli = Org2CLI(repoRoot: root)
    try await cli.exportBeamer(
      file: source,
      destination: destination,
      format: format
    )

    let arguments = try JSONDecoder().decode(
      [String].self,
      from: Data(contentsOf: argumentsFile)
    )
    XCTAssertEqual(
      arguments,
      [
        "export", "beamer",
        "--file", source.standardizedFileURL.path,
        "--out", destination.standardizedFileURL.path,
      ] + expectedTail
    )
  }

  @MainActor
  private func waitForSlidePreview(
    _ store: WorkspaceStore,
    condition: (WorkspaceStore) -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition(store) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for slide preview")
  }
}

private func makeSlideDeckPDF(sourceLines: [Int]) throws -> Data {
  let document = PDFDocument()
  for (index, sourceLine) in sourceLines.enumerated() {
    let image = NSImage(size: NSSize(width: 320, height: 180))
    image.lockFocus()
    NSColor(calibratedWhite: CGFloat(index + 1) / CGFloat(sourceLines.count + 1), alpha: 1).setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()
    let page = try XCTUnwrap(PDFPage(image: image))
    let marker = PDFAnnotation(
      bounds: NSRect(x: 0, y: 0, width: 1, height: 1),
      forType: .link,
      withProperties: nil
    )
    marker.url = URL(string: "org2-source-line://\(sourceLine)")
    page.addAnnotation(marker)
    document.insert(page, at: index)
  }
  return try XCTUnwrap(document.dataRepresentation())
}

private func slideKeyDown(
  _ characters: String,
  keyCode: UInt16,
  modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: modifiers,
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: characters,
    isARepeat: false,
    keyCode: keyCode
  )!
}

private actor SlidePreviewRecorder {
  struct Call: Sendable {
    let text: String
    let sourcePath: String
    let passes: Int
  }

  private let pdf: Data
  private var calls: [Call] = []

  init(pdf: Data) {
    self.pdf = pdf
  }

  func render(text: String, sourcePath: String, passes: Int) throws -> Data {
    calls.append(Call(text: text, sourcePath: sourcePath, passes: passes))
    if text.contains("BROKEN") {
      throw Org2CLIError.commandFailed(status: 1, message: "Draft could not compile")
    }
    return pdf
  }

  func recordedCalls() -> [Call] {
    calls
  }
}
