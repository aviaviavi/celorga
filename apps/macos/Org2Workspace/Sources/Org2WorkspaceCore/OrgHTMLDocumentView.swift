import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

public enum RenderedDocumentWidth: String, CaseIterable, Identifiable, Sendable {
  case readable
  case comfortable
  case wide
  case full

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .readable: "Readable"
    case .comfortable: "Comfortable"
    case .wide: "Wide"
    case .full: "Full Width"
    }
  }

  var cssValue: String {
    switch self {
    case .readable: "760px"
    case .comfortable: "960px"
    case .wide: "1200px"
    case .full: "100%"
    }
  }
}

public enum RenderedDocumentMargin: String, CaseIterable, Identifiable, Sendable {
  case compact
  case standard
  case roomy

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .compact: "Compact"
    case .standard: "Standard"
    case .roomy: "Roomy"
    }
  }

  var cssValue: String {
    switch self {
    case .compact: "16px"
    case .standard: "28px"
    case .roomy: "44px"
    }
  }
}

public enum SourceEditorPresentation: String, CaseIterable, Identifiable, Sendable {
  case source
  case split
  case prose

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .source: "Source"
    case .split: "Split"
    case .prose: "Prose"
    }
  }

  public var systemImage: String {
    switch self {
    case .source: "doc.plaintext"
    case .split: "rectangle.split.2x1"
    case .prose: "text.alignleft"
    }
  }
}

public enum OrgDocumentPreviewKind: String, CaseIterable, Identifiable, Sendable {
  case document
  case slides

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .document: "Document"
    case .slides: "Slides"
    }
  }

  public var systemImage: String {
    switch self {
    case .document: "doc.richtext"
    case .slides: "rectangle.on.rectangle"
    }
  }
}

public enum OrgDocumentPreviewPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case document
  case slides

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .automatic: "Automatic"
    case .document: "Document"
    case .slides: "Slides"
    }
  }

  public var systemImage: String {
    switch self {
    case .automatic: "wand.and.stars"
    case .document: OrgDocumentPreviewKind.document.systemImage
    case .slides: OrgDocumentPreviewKind.slides.systemImage
    }
  }
}

struct OrgHTMLDocumentLayout: Equatable {
  let width: RenderedDocumentWidth
  let margin: RenderedDocumentMargin

  nonisolated static let styleElementID = "org2-app-layout"

  /// Puts the chosen width and margin into the page itself, so the first
  /// paint already has the final layout instead of reflowing at load end.
  func injecting(into html: String) -> String {
    let element = "<style id=\"\(Self.styleElementID)\">:root { --org2-content-width: \(width.cssValue); --org2-page-padding: \(margin.cssValue); }</style>"
    if let range = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) {
      var result = html
      result.replaceSubrange(range, with: element + "</head>")
      return result
    }
    return element + html
  }
}

/// Decides how a rendered document reload is presented. Re-rendering the
/// file that is already on screen (after a save, an external change, or a
/// checkbox edit) keeps the previous frame and exact scroll offset until the
/// new page has settled, so saving does not flash or jump.
enum OrgHTMLDocumentReloadStyle: Equatable {
  case fresh
  case preservingFrame

  static func style(
    loadedSourceFile: String?,
    nextSourceFile: String,
    hasLoadedPage: Bool
  ) -> OrgHTMLDocumentReloadStyle {
    guard hasLoadedPage, let loadedSourceFile, loadedSourceFile == nextSourceFile else {
      return .fresh
    }
    return .preservingFrame
  }
}

struct OrgHTMLTableViewSnapshot: Equatable, Sendable {
  let startLine: Int
  let endLine: Int
  let visibleBodyRowIndices: [Int]
  let totalBodyRowCount: Int
  let filterActive: Bool
  let sortActive: Bool

  init?(_ messageBody: Any) {
    guard let body = messageBody as? [String: Any],
          let startLine = (body["startLine"] as? NSNumber)?.intValue,
          let endLine = (body["endLine"] as? NSNumber)?.intValue,
          let indices = body["visibleBodyRowIndices"] as? [NSNumber],
          let totalBodyRowCount = (body["totalBodyRowCount"] as? NSNumber)?.intValue,
          startLine > 0,
          endLine >= startLine,
          totalBodyRowCount > 0
    else {
      return nil
    }
    let visibleBodyRowIndices = indices.map(\.intValue)
    guard !visibleBodyRowIndices.isEmpty,
          Set(visibleBodyRowIndices).count == visibleBodyRowIndices.count,
          visibleBodyRowIndices.allSatisfy({ $0 >= 0 && $0 < totalBodyRowCount })
    else {
      return nil
    }
    self.startLine = startLine
    self.endLine = endLine
    self.visibleBodyRowIndices = visibleBodyRowIndices
    self.totalBodyRowCount = totalBodyRowCount
    self.filterActive = (body["filterActive"] as? NSNumber)?.boolValue ?? false
    self.sortActive = (body["sortActive"] as? NSNumber)?.boolValue ?? false
  }

  init(
    startLine: Int,
    endLine: Int,
    visibleBodyRowIndices: [Int],
    totalBodyRowCount: Int,
    filterActive: Bool,
    sortActive: Bool
  ) {
    self.startLine = startLine
    self.endLine = endLine
    self.visibleBodyRowIndices = visibleBodyRowIndices
    self.totalBodyRowCount = totalBodyRowCount
    self.filterActive = filterActive
    self.sortActive = sortActive
  }
}

@MainActor
final class OrgHTMLDocumentWebView: WKWebView {
  private var pendingContextMenuLocationInWindow: NSPoint?

  override func rightMouseDown(with event: NSEvent) {
    pendingContextMenuLocationInWindow = event.locationInWindow
    super.rightMouseDown(with: event)
  }

  func recordContextMenuLocationInWindow(_ point: NSPoint) {
    pendingContextMenuLocationInWindow = point
  }

  func consumeContextMenuLocation() -> NSPoint? {
    guard let point = pendingContextMenuLocationInWindow else { return nil }
    pendingContextMenuLocationInWindow = nil
    return convert(point, from: nil)
  }
}

final class OrgHTMLLocalResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
  nonisolated static let scheme = "org2-resource"

  private let lock = NSLock()
  private var sourceDirectory: URL?
  private var corpusRoot: URL?
  private var allowsAbsoluteImagesOutsideCorpus = false
  private var chatAttachments: [String: AIChatAttachment] = [:]

  /// - Parameter allowsAbsoluteImagesOutsideCorpus: Documents the user wrote
  ///   may show an image linked by an explicit absolute or `~/` path anywhere
  ///   on this Mac. Agent-written chat replies stay confined to the corpus.
  func configure(
    source: EntrySource,
    corpusRoot: URL?,
    allowsAbsoluteImagesOutsideCorpus: Bool = false
  ) {
    let sourceURL = OrgHTMLDocumentView.sourceFileURL(source, corpusRoot: corpusRoot)
    lock.withLock {
      sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
      self.corpusRoot = corpusRoot?.standardizedFileURL
      self.allowsAbsoluteImagesOutsideCorpus = allowsAbsoluteImagesOutsideCorpus
    }
  }

  func configureChatAttachments(_ attachments: [AIChatAttachment]) {
    let images = attachments.filter {
      AIChatAttachmentPresentation.previewKind(for: $0) == .image
    }
    lock.withLock {
      chatAttachments = Dictionary(
        images.map { ($0.id.uuidString.lowercased(), $0) },
        uniquingKeysWith: { _, latest in latest }
      )
    }
  }

  nonisolated static func chatAttachmentResourceURL(
    for attachment: AIChatAttachment
  ) -> URL? {
    guard AIChatAttachmentPresentation.previewKind(for: attachment) == .image else {
      return nil
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = "attachment"
    components.path = "/" + attachment.id.uuidString.lowercased()
    components.queryItems = [
      URLQueryItem(name: "revision", value: attachment.persistedContentDigest)
    ]
    return components.url
  }

  nonisolated static func rewritingLocalImageSources(in html: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"(<img\b[^>]*\bsrc\s*=\s*")([^"]+)(")"#,
      options: [.caseInsensitive]
    ) else { return html }

    let source = html as NSString
    let matches = expression.matches(
      in: html,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return html }

    let rewritten = NSMutableString(string: html)
    for match in matches.reversed() {
      guard match.numberOfRanges == 4 else { continue }
      let rawTarget = source.substring(with: match.range(at: 2))
      let target = decodeHTMLAttribute(rawTarget)
      guard isLocalResourceTarget(target),
            let resourceURL = resourceURL(for: target)
      else { continue }
      rewritten.replaceCharacters(in: match.range(at: 2), with: resourceURL.absoluteString)
    }
    return rewritten as String
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(resourceError(.fileReadNoPermission))
      return
    }

    if requestURL.host == "attachment" {
      serveChatAttachment(for: requestURL, to: urlSchemeTask)
      return
    }

    guard let fileURL = fileURL(for: requestURL),
          let contentType = UTType(filenameExtension: fileURL.pathExtension),
          contentType.conforms(to: .image),
          let mimeType = contentType.preferredMIMEType
    else {
      urlSchemeTask.didFailWithError(resourceError(.fileReadNoPermission))
      return
    }

    do {
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      let response = URLResponse(
        url: requestURL,
        mimeType: mimeType,
        expectedContentLength: data.count,
        textEncodingName: nil
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  private func serveChatAttachment(
    for requestURL: URL,
    to urlSchemeTask: any WKURLSchemeTask
  ) {
    let id = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    let revision = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "revision" })?
      .value
    guard !id.isEmpty,
          let attachment = lock.withLock({ chatAttachments[id] }),
          revision == attachment.persistedContentDigest,
          AIChatAttachmentPresentation.previewKind(for: attachment) == .image,
          let mimeType = chatAttachmentMIMEType(attachment)
    else {
      urlSchemeTask.didFailWithError(resourceError(.fileReadNoPermission))
      return
    }

    do {
      let data = try attachment.loadData()
      let response = URLResponse(
        url: requestURL,
        mimeType: mimeType,
        expectedContentLength: data.count,
        textEncodingName: nil
      )
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  private func chatAttachmentMIMEType(_ attachment: AIChatAttachment) -> String? {
    let declared = attachment.mimeType.lowercased()
    if declared.hasPrefix("image/") {
      return declared
    }
    return UTType(filenameExtension: URL(fileURLWithPath: attachment.fileName).pathExtension)?
      .preferredMIMEType
  }

  private func fileURL(for requestURL: URL) -> URL? {
    guard requestURL.scheme?.lowercased() == Self.scheme,
          requestURL.host == "local",
          let target = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value,
          !target.isEmpty
    else { return nil }

    let roots = lock.withLock { (sourceDirectory, corpusRoot, allowsAbsoluteImagesOutsideCorpus) }
    guard let sourceDirectory = roots.0 else { return nil }
    let expandedTarget = NSString(string: target).expandingTildeInPath
    let allowedRoots = [roots.1, roots.0]
      .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath() }
    let explicitCandidate: URL?
    if let explicitURL = URL(string: expandedTarget), explicitURL.isFileURL {
      explicitCandidate = explicitURL
    } else if NSString(string: expandedTarget).isAbsolutePath {
      explicitCandidate = URL(fileURLWithPath: expandedTarget)
    } else {
      explicitCandidate = nil
    }

    if let explicitCandidate {
      let resolved = explicitCandidate.standardizedFileURL.resolvingSymlinksInPath()
      guard roots.2 || allowedRoots.contains(where: { Self.contains(resolved, within: $0) }) else {
        return nil
      }
      return resolved
    }

    // Relative targets resolve beside the note first, then from the corpus
    // root, matching the native media view. Capture writes corpus-relative
    // attachment links into notes that live in subdirectories such as daily/.
    let candidates = [sourceDirectory, roots.1].compactMap { $0 }.map {
      $0.appendingPathComponent(expandedTarget).standardizedFileURL.resolvingSymlinksInPath()
    }.filter { candidate in
      allowedRoots.contains(where: { Self.contains(candidate, within: $0) })
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
  }

  private nonisolated static func contains(_ file: URL, within root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return file.path == root.path || file.path.hasPrefix(rootPath)
  }

  private nonisolated static func isLocalResourceTarget(_ target: String) -> Bool {
    if target.hasPrefix("//") { return false }
    guard let scheme = URL(string: target)?.scheme?.lowercased() else { return true }
    return scheme == "file"
  }

  private nonisolated static func resourceURL(for target: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "local"
    components.queryItems = [URLQueryItem(name: "target", value: target)]
    return components.url
  }

  private nonisolated static func decodeHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  private func resourceError(_ code: CocoaError.Code) -> Error {
    CocoaError(code, userInfo: [NSLocalizedDescriptionKey: "The local Org image could not be loaded."])
  }
}

enum OrgHTMLRenderedEntryAction: Sendable {
  case entryView
  case edit
  case askAI
  case startWork
  case refile
  case schedule(PlanningDateTarget)
  case todo(TodoEditStatus?)
  case deadline(PlanningDateTarget)
  case priority(String?)
  case encrypt
  case decrypt
  case viewDecrypted
  case copy
  case cut
  case copyReference
  case delete
}

private enum EntryContextMenuTag: Int {
  case entryView = 1
  case edit
  case askAI
  case refile
  case scheduleToday
  case scheduleTomorrow
  case scheduleNextMonday
  case scheduleNextMonth
  case todo
  case todoInProgress
  case todoDone
  case todoCanceled
  case todoToggle
  case deadlineToday
  case deadlineTomorrow
  case deadlineNextMonday
  case deadlineNextMonth
  case priorityA
  case priorityB
  case priorityC
  case priorityClear
  case encrypt
  case decrypt
  case copy
  case cut
  case copyReference
  case delete
  case startWork
  case viewDecrypted

  var action: OrgHTMLRenderedEntryAction? {
    switch self {
    case .entryView: .entryView
    case .edit: .edit
    case .askAI: .askAI
    case .refile: .refile
    case .scheduleToday: .schedule(.today)
    case .scheduleTomorrow: .schedule(.tomorrow)
    case .scheduleNextMonday: .schedule(.upcomingMonday)
    case .scheduleNextMonth: .schedule(.nextMonth)
    case .todo: .todo(.todo)
    case .todoInProgress: .todo(.inProgress)
    case .todoDone: .todo(.done)
    case .todoCanceled: .todo(.canceled)
    case .todoToggle: .todo(nil)
    case .deadlineToday: .deadline(.today)
    case .deadlineTomorrow: .deadline(.tomorrow)
    case .deadlineNextMonday: .deadline(.upcomingMonday)
    case .deadlineNextMonth: .deadline(.nextMonth)
    case .priorityA: .priority("A")
    case .priorityB: .priority("B")
    case .priorityC: .priority("C")
    case .priorityClear: .priority(nil)
    case .encrypt: .encrypt
    case .decrypt: .decrypt
    case .copy: .copy
    case .cut: .cut
    case .copyReference: .copyReference
    case .delete: .delete
    case .startWork: .startWork
    case .viewDecrypted: .viewDecrypted
    }
  }

  var requiresEditableSource: Bool {
    switch self {
    case .entryView, .askAI, .copy, .copyReference, .viewDecrypted:
      false
    case .edit, .refile, .startWork,
         .scheduleToday, .scheduleTomorrow, .scheduleNextMonday, .scheduleNextMonth,
         .todo, .todoInProgress, .todoDone, .todoCanceled, .todoToggle,
         .deadlineToday, .deadlineTomorrow, .deadlineNextMonday, .deadlineNextMonth,
         .priorityA, .priorityB, .priorityC, .priorityClear,
         .encrypt, .decrypt, .cut, .delete:
      true
    }
  }
}

struct OrgHTMLDocumentView: NSViewRepresentable {
  @Environment(\.openOrgFileReference) private var openOrgFileReference
  @Environment(\.openOrgFileReferenceInNewTab) private var openOrgFileReferenceInNewTab
  @Environment(\.openWorkspaceWebLink) private var openWorkspaceWebLink
  @Environment(\.recordUsageEvent) private var recordUsageEvent
  @Environment(\.orgRoamLinkResolver) private var linkResolver

  let html: String
  var renderIdentity: String? = nil
  let source: EntrySource
  let corpusRoot: URL?
  let searchQuery: String?
  let searchOccurrenceIndex: Int?
  let searchOccurrenceCount: Int
  let scrollRequest: DetailScrollRequest?
  var restorationSourceLine: Int? = nil
  let layout: OrgHTMLDocumentLayout
  var activateWorkspacePane: @MainActor () -> Void = {}
  let askAIAboutHeading: @MainActor (Int) -> Void
  let performEntryAction: @MainActor (OrgHTMLRenderedEntryAction, Int) -> Void
  var peekEncryptedText: (@MainActor (Int) -> Void)? = nil
  var allowsEntryContextMenu = true
  let reportStatus: @MainActor (String) -> Void
  var allowsCheckboxMutations = false
  var setCheckboxState: @MainActor (_ line: Int, _ checked: Bool) async -> Bool = { _, _ in false }
  var allowsTablePersistence = false
  var saveTableView: @MainActor (OrgHTMLTableViewSnapshot) -> Void = { _ in }
  var recalculateTableFormulas: @MainActor (Int) -> Void = { _ in }
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }
  /// Non-nil enables the hover "Start work" button on open TODO headings.
  var startWorkAtHeading: (@MainActor (Int) -> Void)? = nil
  var openWorkAtHeading: @MainActor (Int) -> Void = { _ in }
  var headingWorkBadges: [HeadingWorkBadge] = []

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.viewportMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.tableViewMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.tableFormulaMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.entryContextMenuMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.paneActivationMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.checkboxMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.encryptedPeekMessageHandlerName
    )
    configuration.userContentController.add(
      context.coordinator,
      name: OrgLinkHoverPreview.messageHandlerName
    )
    configuration.userContentController.addUserScript(WKUserScript(
      source: Coordinator.paneActivationInstallationScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    ))
    configuration.setURLSchemeHandler(
      context.coordinator.localResourceHandler,
      forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme
    )

    let webView = OrgHTMLDocumentWebView(frame: .zero, configuration: configuration)
    context.coordinator.webView = webView
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = .clear
    webView.allowsMagnification = true
    webView.setAccessibilityLabel("Rendered Org document")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.activateWorkspacePane = activateWorkspacePane
    coordinator.openOrgFileReference = openOrgFileReference
    coordinator.openOrgFileReferenceInNewTab = openOrgFileReferenceInNewTab
    coordinator.openWorkspaceWebLink = openWorkspaceWebLink
    coordinator.recordUsageEvent = recordUsageEvent
    coordinator.linkResolver = linkResolver
    coordinator.source = source
    coordinator.corpusRoot = corpusRoot
    coordinator.localResourceHandler.configure(
      source: source,
      corpusRoot: corpusRoot,
      allowsAbsoluteImagesOutsideCorpus: true
    )
    coordinator.askAIAboutHeading = askAIAboutHeading
    coordinator.startWorkAtHeading = startWorkAtHeading
    coordinator.openWorkAtHeading = openWorkAtHeading
    let headingWorkChanged = coordinator.headingWorkBadges != headingWorkBadges
      || coordinator.startWorkEnabled != (startWorkAtHeading != nil)
    coordinator.headingWorkBadges = headingWorkBadges
    coordinator.startWorkEnabled = startWorkAtHeading != nil
    coordinator.performEntryAction = performEntryAction
    coordinator.peekEncryptedText = peekEncryptedText
    coordinator.allowsEntryContextMenu = allowsEntryContextMenu
    coordinator.reportStatus = reportStatus
    let checkboxMutationsChanged = coordinator.allowsCheckboxMutations != allowsCheckboxMutations
    coordinator.allowsCheckboxMutations = allowsCheckboxMutations
    coordinator.setCheckboxState = setCheckboxState
    let tablePersistenceChanged = coordinator.allowsTablePersistence != allowsTablePersistence
    coordinator.allowsTablePersistence = allowsTablePersistence
    coordinator.saveTableView = saveTableView
    coordinator.recalculateTableFormulas = recalculateTableFormulas
    coordinator.reportViewportSourceLine = reportViewportSourceLine
    coordinator.restorationSourceLine = restorationSourceLine
    let layoutChanged = coordinator.layout != layout
    coordinator.layout = layout
    // Read the theme here rather than relying on the parent view: this is
    // tracked by SwiftUI, and the coordinator also observes theme changes.
    let themeStylesheet = WorkspaceThemeCenter.shared.trackedDocumentStylesheet()
    let themeChanged = coordinator.themeStylesheet != themeStylesheet
    coordinator.themeStylesheet = themeStylesheet
    coordinator.observeThemeChanges()

    let renderID = renderIdentity ?? "\(source.id)|\(html.utf8.count)|\(html.hashValue)"
    if coordinator.renderID != renderID {
      coordinator.renderID = renderID
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      coordinator.load(
        html: layout.injecting(into: WorkspaceThemeDocumentStyle.injecting(
          themeStylesheet,
          into: OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in: html)
        )),
        baseURL: Self.sourceFileURL(source, corpusRoot: corpusRoot).deletingLastPathComponent(),
        sourceFile: source.file,
        in: webView
      )
    } else if layoutChanged || themeChanged {
      if layoutChanged { coordinator.applyLayout(to: webView) }
      if themeChanged { coordinator.applyTheme(to: webView) }
    } else if checkboxMutationsChanged {
      coordinator.applyCheckboxMutations(to: webView)
    } else if tablePersistenceChanged {
      coordinator.applyTablePersistence(to: webView)
    } else if coordinator.searchQuery != searchQuery {
      coordinator.searchQuery = searchQuery
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      coordinator.applySearch(to: webView, backwards: false)
    } else if coordinator.searchOccurrenceIndex != searchOccurrenceIndex {
      let previousIndex = coordinator.searchOccurrenceIndex
      coordinator.searchOccurrenceIndex = searchOccurrenceIndex
      let movesBackward = Self.movesSearchBackward(
        from: previousIndex,
        to: searchOccurrenceIndex,
        count: searchOccurrenceCount
      )
      coordinator.applySearch(to: webView, backwards: movesBackward)
    }

    if coordinator.scrollRequestID != scrollRequest?.id {
      coordinator.scrollRequestID = scrollRequest?.id
      coordinator.applyScrollRequest(scrollRequest, to: webView)
    }
    if headingWorkChanged, coordinator.renderID == renderID, !webView.isLoading {
      coordinator.applyHeadingWork(to: webView)
    }
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.cancelFileLinkResolution()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.viewportMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.tableViewMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.tableFormulaMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.entryContextMenuMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.paneActivationMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.checkboxMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.encryptedPeekMessageHandlerName
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: OrgLinkHoverPreview.messageHandlerName
    )
  }

  private static func movesSearchBackward(from previous: Int?, to next: Int?, count: Int) -> Bool {
    guard let previous, let next, count > 1 else { return false }
    if previous == 0 && next == count - 1 { return true }
    if previous == count - 1 && next == 0 { return false }
    return next < previous
  }

  nonisolated static func sourceFileURL(_ source: EntrySource, corpusRoot: URL?) -> URL {
    let expandedPath = NSString(string: source.file).expandingTildeInPath
    if NSString(string: expandedPath).isAbsolutePath {
      return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }
    if let corpusRoot {
      return corpusRoot.appendingPathComponent(expandedPath).standardizedFileURL
    }
    return URL(fileURLWithPath: expandedPath).standardizedFileURL
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated static let viewportMessageHandlerName = "org2ViewportSourceLine"
    nonisolated static let tableViewMessageHandlerName = "org2TableView"
    nonisolated static let tableFormulaMessageHandlerName = "org2TableFormula"
    nonisolated static let entryContextMenuMessageHandlerName = "org2EntryContextMenu"
    nonisolated static let paneActivationMessageHandlerName = "org2PaneActivation"
    nonisolated static let checkboxMessageHandlerName = "org2CheckboxMutation"
    nonisolated static let encryptedPeekMessageHandlerName = "org2EncryptedPeek"
    weak var webView: WKWebView?
    var renderID: String?
    var searchQuery: String?
    var searchOccurrenceIndex: Int?
    var scrollRequestID: Int?
    var scrollRequest: DetailScrollRequest?
    var restorationSourceLine: Int?
    var layout = OrgHTMLDocumentLayout(width: .comfortable, margin: .standard)
    var themeStylesheet = ""
    var openOrgFileReference: @MainActor (AIChatFileReference) -> Void = { _ in }
    var openOrgFileReferenceInNewTab: (@MainActor (AIChatFileReference) -> Void)?
    var openWorkspaceWebLink = OpenWorkspaceWebLinkAction()
    var recordUsageEvent: @MainActor (OpenOrgUsageEvent, [String: OpenOrgUsageValue]) -> Void = { _, _ in }
    private var linkPreviewTask: Task<Void, Never>?
    var linkResolver = OrgRoamLinkResolver.empty
    var source: EntrySource?
    var corpusRoot: URL?
    var activateWorkspacePane: @MainActor () -> Void = {}
    var askAIAboutHeading: @MainActor (Int) -> Void = { _ in }
    var startWorkAtHeading: (@MainActor (Int) -> Void)?
    var openWorkAtHeading: @MainActor (Int) -> Void = { _ in }
    var headingWorkBadges: [HeadingWorkBadge] = []
    var startWorkEnabled = false
    var performEntryAction: @MainActor (OrgHTMLRenderedEntryAction, Int) -> Void = { _, _ in }
    var peekEncryptedText: (@MainActor (Int) -> Void)?
    var allowsEntryContextMenu = true
    var entryContextMenuLine: Int?
    var reportStatus: @MainActor (String) -> Void = { _ in }
    var allowsCheckboxMutations = false
    var setCheckboxState: @MainActor (_ line: Int, _ checked: Bool) async -> Bool = { _, _ in false }
    var allowsTablePersistence = false
    var saveTableView: @MainActor (OrgHTMLTableViewSnapshot) -> Void = { _ in }
    var recalculateTableFormulas: @MainActor (Int) -> Void = { _ in }
    var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }
    let localResourceHandler = OrgHTMLLocalResourceSchemeHandler()
    var fileLinkResolver: @Sendable (String, String, URL?) async -> OrgHTMLResolvedFileTarget? = {
      target, sourceFile, corpusRoot in
      await OrgHTMLLinkTarget.resolve(
        target,
        relativeTo: sourceFile,
        corpusRoot: corpusRoot
      )
    }
    private var fileLinkResolutionTask: Task<Void, Never>?
    private var fileLinkResolutionGeneration: UInt64 = 0

    // MARK: Reloading without a flash

    private var loadedSourceFile: String?
    private var hasLoadedPage = false
    private var loadGeneration: UInt64 = 0
    /// Exact scroll offset to restore after a same-document re-render.
    private var preservedScrollY: Double?
    /// The scroll request already applied when the reload began. Only a newer
    /// request (for example, a jump to a search hit) overrides the preserved
    /// offset; a stale one would otherwise re-scroll on every save.
    private var scrollRequestIDAtPreservedLoad: Int?
    private var freezeFrameView: NSImageView?

    func load(html: String, baseURL: URL, sourceFile: String, in webView: WKWebView) {
      loadGeneration &+= 1
      let generation = loadGeneration
      let style = OrgHTMLDocumentReloadStyle.style(
        loadedSourceFile: loadedSourceFile,
        nextSourceFile: sourceFile,
        hasLoadedPage: hasLoadedPage && !webView.isLoading && webView.bounds.width > 0
      )
      loadedSourceFile = sourceFile
      scrollRequestIDAtPreservedLoad = scrollRequestID
      guard style == .preservingFrame else {
        preservedScrollY = nil
        removeFreezeFrame(animated: false)
        webView.loadHTMLString(html, baseURL: baseURL)
        return
      }
      // Capture the exact scroll offset and the current frame, cover the web
      // view with that frame, then load. didFinish restores the offset and
      // removes the cover once the new page has painted.
      webView.evaluateJavaScript("window.scrollY") { [weak self, weak webView] value, _ in
        MainActor.assumeIsolated {
          guard let self, let webView, generation == self.loadGeneration else { return }
          self.preservedScrollY = (value as? NSNumber)?.doubleValue
          webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
            MainActor.assumeIsolated {
              guard let self, let webView, generation == self.loadGeneration else { return }
              if let image { self.showFreezeFrame(image, over: webView) }
              webView.loadHTMLString(html, baseURL: baseURL)
              // Never leave a stale frame up if the load stalls.
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.removeFreezeFrame(animated: true)
              }
            }
          }
        }
      }
    }

    private func showFreezeFrame(_ image: NSImage, over webView: WKWebView) {
      removeFreezeFrame(animated: false)
      let view = NSImageView(frame: webView.bounds)
      view.image = image
      view.imageScaling = .scaleAxesIndependently
      view.autoresizingMask = [.width, .height]
      view.wantsLayer = true
      webView.addSubview(view)
      freezeFrameView = view
    }

    private func removeFreezeFrame(animated: Bool) {
      guard let view = freezeFrameView else { return }
      freezeFrameView = nil
      guard animated else {
        view.removeFromSuperview()
        return
      }
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.08
        view.animator().alphaValue = 0
      }, completionHandler: {
        view.removeFromSuperview()
      })
    }

    /// Restores the exact pre-reload offset, waits for the next painted
    /// frame, then lifts the freeze frame.
    private func finishPreservedReload(scrollY: Double, in webView: WKWebView) {
      let generation = loadGeneration
      webView.callAsyncJavaScript(
        """
        window.scrollTo(0, y);
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        window.scrollTo(0, y);
        return true;
        """,
        arguments: ["y": scrollY],
        in: nil,
        in: .page
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, generation == self.loadGeneration else { return }
          self.removeFreezeFrame(animated: true)
        }
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      hasLoadedPage = true
      applyLayout(to: webView)
      themeStylesheet = WorkspaceThemeCenter.shared.trackedDocumentStylesheet()
      applyTheme(to: webView)
      applyCheckboxMutations(to: webView)
      applyTablePersistence(to: webView)
      installRichCopyHandler(in: webView)
      if allowsEntryContextMenu {
        installEntryContextMenuHandler(in: webView)
      }
      installViewportSourceLineReporter(in: webView)
      webView.evaluateJavaScript(Self.encryptedPeekInstallationScript)
      webView.evaluateJavaScript(OrgLinkHoverPreview.installationScript)
      applyHeadingWork(to: webView)
      applySearch(to: webView, backwards: false)
      let preservedScrollY = self.preservedScrollY
      self.preservedScrollY = nil
      if let preservedScrollY, scrollRequestID == scrollRequestIDAtPreservedLoad {
        finishPreservedReload(scrollY: preservedScrollY, in: webView)
      } else if let scrollRequest {
        applyScrollRequest(scrollRequest, to: webView)
        removeFreezeFrame(animated: true)
      } else {
        if let restorationSourceLine {
          applySourceLineScroll(restorationSourceLine, to: webView)
        }
        removeFreezeFrame(animated: true)
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      switch message.name {
      case OrgLinkHoverPreview.messageHandlerName:
        guard let payload = message.body as? [String: Any],
              let target = payload["target"] as? String,
              let token = (payload["token"] as? NSNumber)?.intValue
        else { return }
        showLinkPreview(target: target, token: token)
      case Self.paneActivationMessageHandlerName:
        activateWorkspacePane()
      case Self.viewportMessageHandlerName:
        let line = (message.body as? NSNumber)?.intValue
        reportViewportSourceLine(line.flatMap { $0 > 0 ? $0 : nil })
      case Self.tableViewMessageHandlerName:
        guard allowsTablePersistence,
              let snapshot = OrgHTMLTableViewSnapshot(message.body)
        else { return }
        saveTableView(snapshot)
      case Self.tableFormulaMessageHandlerName:
        guard allowsTablePersistence,
              let body = message.body as? [String: Any],
              let startLine = (body["startLine"] as? NSNumber)?.intValue,
              startLine > 0
        else { return }
        recalculateTableFormulas(startLine)
      case Self.entryContextMenuMessageHandlerName:
        guard let payload = message.body as? [String: Any],
              let line = (payload["line"] as? NSNumber)?.intValue,
              line > 0,
              let x = (payload["x"] as? NSNumber)?.doubleValue,
              let y = (payload["y"] as? NSNumber)?.doubleValue
        else { return }
        presentEntryContextMenu(line: line, x: x, y: y)
      case Self.encryptedPeekMessageHandlerName:
        guard let line = (message.body as? NSNumber)?.intValue, line > 0 else { return }
        peekEncryptedText?(line)
      case Self.checkboxMessageHandlerName:
        guard allowsCheckboxMutations,
              let payload = message.body as? [String: Any],
              let line = (payload["line"] as? NSNumber)?.intValue,
              line > 0,
              let checked = (payload["checked"] as? NSNumber)?.boolValue
        else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          let persisted = await self.setCheckboxState(line, checked)
          self.finishCheckboxMutation(
            at: line,
            requestedChecked: checked,
            persisted: persisted
          )
        }
      default:
        return
      }
    }

    func applyHeadingWork(to webView: WKWebView) {
      let script = OrgHTMLHeadingWorkScript.installation
        + "\nwindow.__org2InstallStartWork?.(\(startWorkEnabled));"
        + "\nwindow.__org2SetWorkBadges?.(\(OrgHTMLHeadingWorkScript.badgesPayload(headingWorkBadges)));"
      webView.evaluateJavaScript(script)
    }

    func installEntryContextMenuHandler(in webView: WKWebView) {
      webView.evaluateJavaScript(Self.entryContextMenuInstallationScript)
    }

    nonisolated static let paneActivationInstallationScript =
      "window.addEventListener('mousedown', () => window.webkit.messageHandlers.org2PaneActivation.postMessage(true), true);"

    nonisolated static var entryContextMenuInstallationScript: String {
      """
      (() => {
        if (window.__org2EntryContextMenuInstalled) return;
        window.__org2EntryContextMenuInstalled = true;
        document.addEventListener('contextmenu', (event) => {
          const selection = window.getSelection();
          if (selection && !selection.isCollapsed && selection.toString().trim()) return;
          const target = event.target instanceof Element ? event.target : event.target?.parentElement;
          const entry = target?.closest('details.org2-headline[data-org2-start-line]');
          if (!entry) return;
          const line = Number(entry.dataset.org2StartLine || 0);
          if (!line) return;
          event.preventDefault();
          event.stopPropagation();
          window.webkit.messageHandlers.\(Self.entryContextMenuMessageHandlerName).postMessage({
            line,
            x: event.clientX,
            y: event.clientY
          });
        }, true);
      })();
      """
    }

    func presentEntryContextMenu(line: Int, x: Double, y: Double) {
      guard let webView else { return }
      entryContextMenuLine = line
      let menu = makeEntryContextMenu()
      let point = (webView as? OrgHTMLDocumentWebView)?.consumeContextMenuLocation()
        ?? Self.fallbackEntryContextMenuPoint(
          x: x,
          y: y,
          viewHeight: Double(webView.bounds.height),
          isFlipped: webView.isFlipped
        )
      menu.popUp(positioning: nil, at: point, in: webView)
    }

    nonisolated static func fallbackEntryContextMenuPoint(
      x: Double,
      y: Double,
      viewHeight: Double,
      isFlipped: Bool
    ) -> NSPoint {
      NSPoint(x: x, y: isFlipped ? y : viewHeight - y)
    }

    func makeEntryContextMenu() -> NSMenu {
      let menu = NSMenu(title: "Entry")
      menu.autoenablesItems = false

      menu.addItem(contextMenuItem("Entry View", symbol: "doc.text.magnifyingglass", tag: .entryView))
      menu.addItem(contextMenuItem("Edit Entry", symbol: "square.and.pencil", tag: .edit))
      menu.addItem(contextMenuItem("Ask AI", symbol: "sparkles", tag: .askAI))
      menu.addItem(contextMenuItem("Start Work with AI…", symbol: "play.circle", tag: .startWork))
      menu.addItem(.separator())
      menu.addItem(contextMenuItem("Move / Refile…", symbol: "arrowshape.turn.up.right", tag: .refile))

      menu.addItem(submenuItem(
        "Schedule",
        symbol: "calendar",
        items: [
          contextMenuItem("Today", tag: .scheduleToday),
          contextMenuItem("Tomorrow", tag: .scheduleTomorrow),
          contextMenuItem("Next Monday", tag: .scheduleNextMonday),
          contextMenuItem("Next Month", tag: .scheduleNextMonth),
        ]
      ))
      menu.addItem(submenuItem(
        "Todo Status",
        symbol: "checkmark.circle",
        items: [
          contextMenuItem("TODO", tag: .todo),
          contextMenuItem("In Progress", tag: .todoInProgress),
          contextMenuItem("Done", tag: .todoDone),
          contextMenuItem("Canceled", tag: .todoCanceled),
          .separator(),
          contextMenuItem("Toggle", tag: .todoToggle),
        ]
      ))
      menu.addItem(submenuItem(
        "Deadline",
        symbol: "calendar.badge.exclamationmark",
        items: [
          contextMenuItem("Today", tag: .deadlineToday),
          contextMenuItem("Tomorrow", tag: .deadlineTomorrow),
          contextMenuItem("Next Monday", tag: .deadlineNextMonday),
          contextMenuItem("Next Month", tag: .deadlineNextMonth),
        ]
      ))
      menu.addItem(submenuItem(
        "Priority",
        symbol: "flag",
        items: [
          contextMenuItem("A", tag: .priorityA),
          contextMenuItem("B", tag: .priorityB),
          contextMenuItem("C", tag: .priorityC),
          .separator(),
          contextMenuItem("Clear", tag: .priorityClear),
        ]
      ))
      menu.addItem(submenuItem(
        "Encrypt / Decrypt",
        symbol: "lock",
        items: [
          contextMenuItem("View Decrypted", tag: .viewDecrypted),
          .separator(),
          contextMenuItem("Encrypt", tag: .encrypt),
          contextMenuItem("Decrypt in File", tag: .decrypt),
        ]
      ))

      menu.addItem(.separator())
      menu.addItem(contextMenuItem("Copy", symbol: "doc.on.doc", tag: .copy))
      menu.addItem(contextMenuItem("Cut", symbol: "scissors", tag: .cut))
      menu.addItem(contextMenuItem("Copy Reference", symbol: "link", tag: .copyReference))
      menu.addItem(.separator())
      menu.addItem(contextMenuItem("Delete", symbol: "trash", tag: .delete))
      return menu
    }

    private func submenuItem(_ title: String, symbol: String, items: [NSMenuItem]) -> NSMenuItem {
      let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      let submenu = NSMenu(title: title)
      submenu.autoenablesItems = false
      items.forEach(submenu.addItem)
      parent.submenu = submenu
      return parent
    }

    private func contextMenuItem(
      _ title: String,
      symbol: String? = nil,
      tag: EntryContextMenuTag
    ) -> NSMenuItem {
      let item = NSMenuItem(
        title: title,
        action: #selector(performEntryContextMenuAction(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = tag.rawValue
      item.isEnabled = !tag.requiresEditableSource || source?.isEditable == true
      if let symbol {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      }
      return item
    }

    @objc private func performEntryContextMenuAction(_ sender: NSMenuItem) {
      performEntryContextMenuAction(tag: sender.tag)
    }

    func performEntryContextMenuAction(tag rawTag: Int) {
      guard let line = entryContextMenuLine,
            let tag = EntryContextMenuTag(rawValue: rawTag),
            let action = tag.action
      else { return }
      performEntryAction(action, line)
    }

    func installViewportSourceLineReporter(in webView: WKWebView) {
      let script = """
      (() => {
        if (window.__org2ViewportSourceLineInstalled) {
          window.__org2ReportViewportSourceLine?.();
          return;
        }
        window.__org2ViewportSourceLineInstalled = true;
        let pending = null;
        const sourceLine = () => {
          const viewportHeight = Math.max(1, window.innerHeight || 1);
          const anchorY = Math.min(Math.max(viewportHeight * 0.32, 48), viewportHeight - 1);
          const entries = Array.from(document.querySelectorAll('[data-org2-start-line]'))
            .map((element) => {
              const start = Number(element.dataset.org2StartLine || 0);
              const end = Number(element.dataset.org2EndLine || start);
              return { start, end, rect: element.getBoundingClientRect() };
            })
            .filter((entry) =>
              entry.start > 0 &&
              entry.rect.bottom >= 0 &&
              entry.rect.top <= viewportHeight
            );
          if (entries.length === 0) return null;
          const containing = entries.filter((entry) =>
            entry.rect.top <= anchorY && entry.rect.bottom >= anchorY
          );
          const candidates = containing.length > 0 ? containing : entries;
          candidates.sort((lhs, rhs) => {
            if (containing.length > 0) {
              const sourceSpan = (lhs.end - lhs.start) - (rhs.end - rhs.start);
              if (sourceSpan !== 0) return sourceSpan;
              const visualSpan = lhs.rect.height - rhs.rect.height;
              if (visualSpan !== 0) return visualSpan;
            }
            return Math.abs(lhs.rect.top - anchorY) - Math.abs(rhs.rect.top - anchorY);
          });
          return candidates[0]?.start || null;
        };
        const report = () => {
          pending = null;
          window.webkit.messageHandlers.\(Self.viewportMessageHandlerName).postMessage(sourceLine());
        };
        window.__org2ReportViewportSourceLine = () => {
          if (pending !== null) clearTimeout(pending);
          pending = setTimeout(report, 80);
        };
        window.addEventListener('scroll', window.__org2ReportViewportSourceLine, { passive: true });
        window.addEventListener('resize', window.__org2ReportViewportSourceLine, { passive: true });
        requestAnimationFrame(window.__org2ReportViewportSourceLine);
      })();
      """
      webView.evaluateJavaScript(script)
    }

    func installRichCopyHandler(in webView: WKWebView) {
      webView.evaluateJavaScript(OrgHTMLRichCopy.installationScript)
    }

    func applyLayout(to webView: WKWebView) {
      let script = """
      document.documentElement.style.setProperty('--org2-content-width', '\(layout.width.cssValue)');
      document.documentElement.style.setProperty('--org2-page-padding', '\(layout.margin.cssValue)');
      """
      webView.evaluateJavaScript(script)
    }

    func applyTheme(to webView: WKWebView) {
      webView.evaluateJavaScript(WorkspaceThemeDocumentStyle.replacementScript(themeStylesheet))
    }

    private var isObservingTheme = false

    /// Recolor the loaded page whenever the active theme pair changes, even if
    /// SwiftUI does not call `updateNSView` for this representable.
    func observeThemeChanges() {
      guard !isObservingTheme else { return }
      isObservingTheme = true
      withObservationTracking {
        _ = WorkspaceThemeCenter.shared.trackedDocumentStylesheet()
      } onChange: { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.isObservingTheme = false
          let stylesheet = WorkspaceThemeCenter.shared.trackedDocumentStylesheet()
          if stylesheet != self.themeStylesheet, let webView = self.webView {
            self.themeStylesheet = stylesheet
            self.applyTheme(to: webView)
          }
          self.observeThemeChanges()
        }
      }
    }

    func applyTablePersistence(to webView: WKWebView) {
      let enabled = allowsTablePersistence ? "true" : "false"
      webView.evaluateJavaScript("window.__org2SetTablePersistenceEnabled?.(\(enabled));")
    }

    func applyCheckboxMutations(to webView: WKWebView) {
      let enabled = allowsCheckboxMutations ? "true" : "false"
      webView.evaluateJavaScript(Self.checkboxMutationInstallationScript)
      webView.evaluateJavaScript("window.__org2SetCheckboxMutationsEnabled?.(\(enabled));")
    }

    func finishCheckboxMutation(
      at line: Int,
      requestedChecked: Bool,
      persisted: Bool
    ) {
      let checked = requestedChecked ? "true" : "false"
      let saved = persisted ? "true" : "false"
      webView?.evaluateJavaScript(
        "window.__org2FinishCheckboxMutation?.(\(line), \(checked), \(saved));"
      )
    }

    /// Clicking (or pressing Return/Space on) an encrypted card asks the app
    /// to show the plaintext in a temporary sheet. The page never sees it.
    nonisolated static var encryptedPeekInstallationScript: String {
      """
      (() => {
        if (window.__org2EncryptedPeekInstalled) return;
        window.__org2EncryptedPeekInstalled = true;
        const peek = (event) => {
          const target = event.target instanceof Element ? event.target : event.target?.parentElement;
          const card = target?.closest('.org2-encrypted[data-org2-start-line]');
          if (!card) return;
          const line = Number(card.dataset.org2StartLine || 0);
          if (!line) return;
          event.preventDefault();
          event.stopPropagation();
          window.webkit.messageHandlers.\(Self.encryptedPeekMessageHandlerName).postMessage(line);
        };
        document.addEventListener('click', peek, true);
        document.addEventListener('keydown', (event) => {
          if (event.key === 'Enter' || event.key === ' ') peek(event);
        }, true);
      })();
      """
    }

    nonisolated static var checkboxMutationInstallationScript: String {
      """
      (() => {
        if (!window.__org2CheckboxMutationInstalled) {
          window.__org2CheckboxMutationInstalled = true;
          document.addEventListener('change', (event) => {
            const checkbox = event.target instanceof HTMLInputElement ? event.target : null;
            if (!checkbox || checkbox.type !== 'checkbox' || checkbox.dataset.org2InteractiveCheckbox !== 'true') return;
            const item = checkbox.closest('li[data-org2-start-line]');
            const line = Number(item?.dataset.org2StartLine || 0);
            if (!line) return;
            checkbox.disabled = true;
            checkbox.setAttribute('aria-busy', 'true');
            window.webkit.messageHandlers.\(Self.checkboxMessageHandlerName).postMessage({
              line,
              checked: checkbox.checked
            });
          }, true);
        }
        window.__org2SetCheckboxMutationsEnabled = (enabled) => {
          window.__org2CheckboxMutationsEnabled = Boolean(enabled);
          for (const checkbox of document.querySelectorAll('li[data-org2-start-line] > input[type="checkbox"]')) {
            checkbox.dataset.org2InteractiveCheckbox = enabled ? 'true' : 'false';
            checkbox.disabled = !enabled;
            checkbox.style.cursor = enabled ? 'pointer' : '';
            checkbox.removeAttribute('aria-busy');
            checkbox.title = enabled
              ? (checkbox.checked ? 'Mark incomplete' : 'Mark complete')
              : '';
          }
        };
        window.__org2FinishCheckboxMutation = (line, requestedChecked, persisted) => {
          const item = document.querySelector(`li[data-org2-start-line="${line}"]`);
          const checkbox = item?.querySelector(':scope > input[type="checkbox"]');
          if (!checkbox) return;
          if (!persisted) checkbox.checked = !requestedChecked;
          checkbox.disabled = !window.__org2CheckboxMutationsEnabled;
          checkbox.removeAttribute('aria-busy');
          checkbox.title = window.__org2CheckboxMutationsEnabled
            ? (checkbox.checked ? 'Mark incomplete' : 'Mark complete')
            : '';
        };
      })();
      """
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }

      if url.scheme?.lowercased() == AIChatFileReference.deepLinkScheme,
         url.host == "ask-ai",
         let rawLine = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "line" })?
           .value,
         let line = Int(rawLine),
         line > 0 {
        askAIAboutHeading(line)
        decisionHandler(.cancel)
        return
      }

      if url.scheme?.lowercased() == AIChatFileReference.deepLinkScheme,
         url.host == "start-work" || url.host == "open-work",
         let rawLine = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "line" })?
           .value,
         let line = Int(rawLine),
         line > 0 {
        if url.host == "start-work" {
          startWorkAtHeading?(line)
        } else {
          openWorkAtHeading(line)
        }
        decisionHandler(.cancel)
        return
      }

      if url.scheme?.lowercased() == AIChatFileReference.deepLinkScheme,
         url.host == "open-link",
         let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
           .queryItems?
           .first(where: { $0.name == "target" })?
           .value {
        open(target: target, inNewTab: navigationAction.modifierFlags.contains(.command))
        decisionHandler(.cancel)
        return
      }

      if url.scheme?.lowercased() == AIChatFileReference.deepLinkScheme {
        decisionHandler(.cancel)
        return
      }

      guard navigationAction.navigationType == .linkActivated else {
        decisionHandler(.allow)
        return
      }

      if url.scheme?.lowercased() == "http"
          || url.scheme?.lowercased() == "https"
          || url.scheme?.lowercased() == "mailto" {
        openWorkspaceWebLink(url, inNewTab: navigationAction.modifierFlags.contains(.command))
        decisionHandler(.cancel)
        return
      }

      if url.fragment != nil {
        decisionHandler(.allow)
        return
      }

      decisionHandler(.cancel)
    }

    func applySearch(to webView: WKWebView, backwards: Bool) {
      let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let configuration = WKFindConfiguration()
      configuration.caseSensitive = false
      configuration.wraps = true
      configuration.backwards = backwards
      guard !query.isEmpty else {
        webView.find(query, configuration: configuration) { _ in }
        return
      }
      // WebKit find does not search a closed details subtree. Reveal only
      // source blocks containing the query before asking it to select a match.
      Task { @MainActor in
        _ = try? await webView.callAsyncJavaScript(
          Self.revealSourceSearchMatchesScript,
          arguments: ["query": query],
          in: nil,
          contentWorld: .page
        )
        webView.find(query, configuration: configuration) { _ in }
      }
    }

    nonisolated static let revealSourceSearchMatchesScript = """
    const needle = query.toLocaleLowerCase();
    if (needle) {
      for (const disclosure of document.querySelectorAll('details.org2-large-source:not([open])')) {
        if (disclosure.querySelector('code')?.textContent.toLocaleLowerCase().includes(needle)) {
          disclosure.open = true;
        }
      }
    }
    """

    func applyScrollRequest(_ request: DetailScrollRequest?, to webView: WKWebView) {
      scrollRequest = request
      guard let request else { return }
      if case .sourceLine(let line) = request.target {
        applySourceLineScroll(line, to: webView)
        return
      }
      guard case .page(let direction) = request.target else { return }
      guard let scrollView = webView.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
      guard let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height
      guard visibleHeight > 0 else { return }

      let distance = max(120, visibleHeight * 0.8)
      let directionMultiplier: CGFloat = direction == .down ? 1 : -1
      let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
      let maxY = max(0, documentView.bounds.height - visibleHeight)
      var origin = clipView.bounds.origin
      origin.y = min(max(0, origin.y + distance * directionMultiplier * flippedMultiplier), maxY)
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    private func applySourceLineScroll(_ line: Int, to webView: WKWebView) {
      let script = """
        (() => {
          const line = \(line);
          const reveal = () => {
            const elements = Array.from(document.querySelectorAll('[data-org2-start-line]'));
            const candidates = elements.filter((element) => {
              const start = Number(element.dataset.org2StartLine || 0);
              const end = Number(element.dataset.org2EndLine || start);
              return start <= line && end >= line;
            });
            const containingTarget = candidates.sort((lhs, rhs) => {
              const lhsSpan = Number(lhs.dataset.org2EndLine || 0) - Number(lhs.dataset.org2StartLine || 0);
              const rhsSpan = Number(rhs.dataset.org2EndLine || 0) - Number(rhs.dataset.org2StartLine || 0);
              return lhsSpan - rhsSpan;
            })[0];
            const followingTarget = elements
              .filter((element) => Number(element.dataset.org2StartLine || 0) >= line)
              .sort((lhs, rhs) =>
                Number(lhs.dataset.org2StartLine || 0) - Number(rhs.dataset.org2StartLine || 0)
              )[0];
            const precedingTarget = elements
              .filter((element) => Number(element.dataset.org2StartLine || 0) < line)
              .sort((lhs, rhs) =>
                Number(rhs.dataset.org2StartLine || 0) - Number(lhs.dataset.org2StartLine || 0)
              )[0];
            const target = containingTarget || followingTarget || precedingTarget;
            if (target) {
              const source = target.closest('details.org2-large-source');
              if (source && line > Number(source.dataset.org2StartLine || 0)) source.open = true;
              const viewportHeight = Math.max(1, window.innerHeight || 1);
              const anchorY = Math.min(Math.max(viewportHeight * 0.32, 48), viewportHeight - 1);
              const targetY = window.scrollY + target.getBoundingClientRect().top;
              window.scrollTo({ top: Math.max(0, targetY - anchorY), behavior: 'auto' });
            }
          };
          requestAnimationFrame(() => requestAnimationFrame(reveal));
          setTimeout(reveal, 120);
          setTimeout(reveal, 350);
        })();
        """
      webView.evaluateJavaScript(script)
    }

    /// Resolves a workspace link target to a file and line without opening it.
    private func resolveWorkspaceTarget(_ target: String) async -> AIChatFileReference? {
      if let resolved = linkResolver.resolve(target: target) { return resolved.fileReference }
      if OrgHTMLDocumentLinkRouting.externalURL(for: target, linkResolver: linkResolver) != nil { return nil }
      guard let source else { return nil }
      guard let fileTarget = await fileLinkResolver(target, source.file, corpusRoot),
            OrgHTMLDocumentLinkRouting.opensInWorkspace(fileTarget.url),
            FileManager.default.fileExists(atPath: fileTarget.url.path)
      else { return nil }
      return AIChatFileReference(path: fileTarget.url.path, line: fileTarget.line)
    }

    private func showLinkPreview(target rawTarget: String, token: Int) {
      let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return }
      linkPreviewTask?.cancel()
      linkPreviewTask = Task { @MainActor [weak self] in
        guard let self, let reference = await self.resolveWorkspaceTarget(target) else { return }
        let path = reference.path
        guard !path.lowercased().hasSuffix(".pdf"), !Task.isCancelled else { return }
        let relative: String = {
          guard let root = self.corpusRoot?.standardizedFileURL.path else { return URL(fileURLWithPath: path).lastPathComponent }
          let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
          return standardized.hasPrefix(root + "/") ? String(standardized.dropFirst(root.count + 1)) : URL(fileURLWithPath: path).lastPathComponent
        }()
        guard let preview = await OrgLinkHoverPreview.load(path: path, line: reference.line, relativePath: relative),
              !Task.isCancelled
        else { return }
        self.webView?.evaluateJavaScript(
          "window.__org2ShowLinkPreview?.(\(token), \(preview.scriptPayload));",
          completionHandler: nil
        )
        self.recordUsageEvent(.linkPreview, ["kind": target.hasPrefix("id:") ? "id" : "file"])
      }
    }

    func open(target rawTarget: String, inNewTab: Bool = false) {
      let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return }

      fileLinkResolutionTask?.cancel()
      fileLinkResolutionTask = nil
      fileLinkResolutionGeneration &+= 1

      let openReference: @MainActor (AIChatFileReference) -> Void = { [weak self] reference in
        guard let self else { return }
        if inNewTab, let openInNewTab = self.openOrgFileReferenceInNewTab {
          openInNewTab(reference)
        } else {
          self.openOrgFileReference(reference)
        }
      }

      if let resolved = linkResolver.resolve(target: target) {
        openReference(resolved.fileReference)
        return
      }

      if let externalURL = OrgHTMLDocumentLinkRouting.externalURL(
        for: target,
        linkResolver: linkResolver
      ) {
        openWorkspaceWebLink(externalURL, inNewTab: inNewTab)
        return
      }

      guard let source else {
        reportStatus("Could not resolve link: \(target)")
        return
      }

      let generation = fileLinkResolutionGeneration
      let sourceFile = source.file
      let requestedCorpusRoot = corpusRoot
      let resolver = fileLinkResolver
      fileLinkResolutionTask = Task { @MainActor [weak self] in
        let fileTarget = await resolver(target, sourceFile, requestedCorpusRoot)
        guard !Task.isCancelled,
              let self,
              generation == self.fileLinkResolutionGeneration,
              self.source?.file == sourceFile,
              self.corpusRoot?.standardizedFileURL == requestedCorpusRoot?.standardizedFileURL
        else {
          return
        }
        self.fileLinkResolutionTask = nil
        guard let fileTarget else {
          self.reportStatus("Could not resolve link: \(target)")
          return
        }

        if OrgHTMLDocumentLinkRouting.opensInWorkspace(fileTarget.url) {
          openReference(AIChatFileReference(
            path: fileTarget.url.path,
            line: fileTarget.line
          ))
        } else if FileManager.default.fileExists(atPath: fileTarget.url.path) {
          NSWorkspace.shared.open(fileTarget.url)
        } else {
          self.reportStatus("Linked file not found: \(fileTarget.url.lastPathComponent)")
        }
      }
    }

    func cancelFileLinkResolution() {
      linkPreviewTask?.cancel()
      linkPreviewTask = nil
      fileLinkResolutionGeneration &+= 1
      fileLinkResolutionTask?.cancel()
      fileLinkResolutionTask = nil
    }
  }
}

enum OrgHTMLDocumentLinkRouting {
  private static let workspaceExtensions = Set(["org", "org2", "md", "csv", "pdf"])
  /// Code and plain-text files open in the workspace, where the shared
  /// renderer (`src/codeHighlight.ts`) shows them as highlighted,
  /// line-addressable source instead of handing them to another app.
  static let codeFileExtensions: Set<String> = [
    "py", "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "swift", "go", "rs", "java", "kt", "kts",
    "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs", "rb", "php", "sh", "bash", "zsh", "fish",
    "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "sql", "html", "htm", "xml", "css", "scss",
    "hs", "scala", "lua", "r", "ex", "exs", "el", "clj", "nix", "txt", "log",
  ]

  static func externalURL(
    for rawTarget: String,
    linkResolver: OrgRoamLinkResolver
  ) -> URL? {
    let expandedTarget = linkResolver.expandedLinkTarget(rawTarget)
    guard let url = URL(string: expandedTarget),
          let scheme = url.scheme?.lowercased(),
          Set(["http", "https", "mailto"]).contains(scheme)
    else {
      return nil
    }
    return url
  }

  static func opensInWorkspace(_ url: URL) -> Bool {
    workspaceExtensions.contains(url.pathExtension.lowercased())
      || codeFileExtensions.contains(url.pathExtension.lowercased())
      || WorkspaceStore.isMediaFile(url.path)
  }
}

enum OrgHTMLRichCopy {
  nonisolated static let installationScript = #"""
  (() => {
    if (window.__org2RichCopyInstalled) return;
    window.__org2RichCopyInstalled = true;

    const copyPayload = () => {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    const selectedText = selection.toString();
    if (!selectedText) return null;

    const tables = Array.from(document.querySelectorAll('table')).filter((table) => {
      try { return range.intersectsNode(table); } catch (_) { return false; }
    });
    const selectedTable = tables.find((table) => {
      const cells = Array.from(table.querySelectorAll('th, td')).filter((cell) => {
        try { return range.intersectsNode(cell); } catch (_) { return false; }
      });
      return cells.length >= 2;
    });

    if (selectedTable) {
      const clone = selectedTable.cloneNode(true);
      clone.removeAttribute('id');
      clone.querySelectorAll('.org2-column-resizer, .org2-table-sort-button').forEach((element) => element.remove());
      clone.querySelectorAll('tr[hidden]').forEach((row) => row.remove());
      clone.style.borderCollapse = 'collapse';
      clone.style.borderSpacing = '0';
      clone.style.fontFamily = '-apple-system, BlinkMacSystemFont, sans-serif';
      clone.style.fontSize = '13px';
      clone.style.color = '#1f2328';
      clone.style.backgroundColor = '#ffffff';
      clone.querySelectorAll('th, td').forEach((cell) => {
        cell.style.border = '1px solid #c8cdd3';
        cell.style.padding = '6px 10px';
        cell.style.textAlign = 'left';
        cell.style.verticalAlign = 'top';
      });
      clone.querySelectorAll('th').forEach((cell) => {
        cell.style.fontWeight = '600';
        cell.style.backgroundColor = '#f2f4f7';
      });
      const text = Array.from(clone.rows).map((row) =>
        Array.from(row.cells).map((cell) => cell.innerText.trim()).join('\t')
      ).join('\n');
      return { html: clone.outerHTML, text };
    }

    const container = document.createElement('div');
    container.appendChild(range.cloneContents());
    return { html: container.innerHTML, text: selectedText };
    };

    document.addEventListener('copy', (event) => {
      const payload = copyPayload();
      if (!payload || !event.clipboardData) return;
      event.clipboardData.setData('text/html', payload.html);
      event.clipboardData.setData('text/plain', payload.text);
      event.preventDefault();
    });
  })();
  """#
}

struct OrgHTMLResolvedFileTarget: Equatable, Sendable {
  let url: URL
  let line: Int?
}

enum OrgHTMLLinkTarget {
  nonisolated static func resolve(
    _ rawTarget: String,
    relativeTo sourceFile: String,
    corpusRoot: URL?
  ) async -> OrgHTMLResolvedFileTarget? {
    await Task.detached(priority: .userInitiated) {
      resolveOffMain(rawTarget, relativeTo: sourceFile, corpusRoot: corpusRoot)
    }.value
  }

  private nonisolated static func resolveOffMain(
    _ rawTarget: String,
    relativeTo sourceFile: String,
    corpusRoot: URL?
  ) -> OrgHTMLResolvedFileTarget? {
    var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    if target.lowercased().hasPrefix("file:") {
      target = String(target.dropFirst(5))
    } else {
      let pathExtension = URL(fileURLWithPath: target).pathExtension
      guard target.contains("/") || !pathExtension.isEmpty else { return nil }
    }

    let components = target.components(separatedBy: "::")
    let rawPath = components[0].removingPercentEncoding ?? components[0]
    guard !rawPath.isEmpty else { return nil }

    let expandedPath: String
    if rawPath == "~" {
      expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
    } else if rawPath.hasPrefix("~/") {
      expandedPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(rawPath.dropFirst(2)))
        .path
    } else {
      expandedPath = rawPath
    }

    let url: URL
    if expandedPath.hasPrefix("/") {
      url = URL(fileURLWithPath: expandedPath).standardizedFileURL
    } else {
      let sourceDirectory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
      let sourceRelative = sourceDirectory.appendingPathComponent(expandedPath).standardizedFileURL
      if FileManager.default.fileExists(atPath: sourceRelative.path) || corpusRoot == nil {
        url = sourceRelative
      } else {
        url = corpusRoot!.appendingPathComponent(expandedPath).standardizedFileURL
      }
    }

    let search = components.dropFirst().joined(separator: "::").trimmingCharacters(in: .whitespacesAndNewlines)
    let line: Int?
    if let explicitLine = Int(search) {
      line = max(1, explicitLine)
    } else if !search.isEmpty {
      line = headingLine(search, in: url)
    } else {
      line = nil
    }

    return OrgHTMLResolvedFileTarget(url: url, line: line)
  }

  private static func headingLine(_ rawHeading: String, in url: URL) -> Int? {
    let expected = rawHeading
      .replacingOccurrences(of: #"^\*+\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expected.isEmpty,
          let source = try? String(contentsOf: url, encoding: .utf8)
    else {
      return nil
    }

    for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let raw = String(line)
      guard raw.first == "*",
            let space = raw.firstIndex(of: " ")
      else {
        continue
      }
      var title = String(raw[raw.index(after: space)...])
        .replacingOccurrences(of: #"\s+:[A-Za-z0-9_@#%:]+:\s*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      title = title
        .replacingOccurrences(of: #"^(?:TODO|IN_PROGRESS|DONE|CANCELED|CANCELLED|WAITING|NEXT)\s+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
      if Org2Display.cleanInline(title).caseInsensitiveCompare(Org2Display.cleanInline(expected)) == .orderedSame {
        return index + 1
      }
    }
    return nil
  }
}
