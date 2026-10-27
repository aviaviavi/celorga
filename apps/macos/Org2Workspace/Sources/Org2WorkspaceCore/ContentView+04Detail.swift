import AppKit
import SwiftUI

struct DetailHeader: View {
  @Environment(WorkspaceStore.self) private var store
  @ObservedObject var sourceEditorInteraction: SourceEditorInteractionModel
  @FocusState private var isPageSearchFocused: Bool
  @State private var pageSearchDraft = ""
  let location: WorkspaceLocation
  let renderedViewportSourceLine: Int?

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      // The title row matches `HeaderBar` (same insets, type, and row height)
      // so the document pane lines up with the surface pane beside it.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 16) {
          detailIdentity
            .frame(maxWidth: .infinity, alignment: .leading)
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
              .fixedSize(horizontal: true, vertical: false)
          }
          inlineDetailActions
          DetailPaneControlGroup()
        }
        .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)

        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .center, spacing: 8) {
            detailIdentity
              .frame(maxWidth: .infinity, alignment: .leading)
            inlineDetailActions
            DetailPaneControlGroup()
          }
          .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
          }
        }
      }

      if !usesInlineDetailActions {
        detailActionBar
      }

      if store.selectedFileIsDataNotebook,
         let failure = store.dataNotebookRefreshFailure {
        dataNotebookRefreshFailureBanner(failure)
      }

      if store.isPageSearchPresented {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(WorkspaceDesign.secondaryText)
          TextField("Find in page", text: $pageSearchDraft)
            .textFieldStyle(.roundedBorder)
            .focused($isPageSearchFocused)
            .task(id: pageSearchDraft) {
              try? await Task.sleep(nanoseconds: 80_000_000)
              guard !Task.isCancelled, store.pageSearchQuery != pageSearchDraft else { return }
              store.pageSearchQuery = pageSearchDraft
            }
            .onSubmit {
              if store.pageSearchQuery != pageSearchDraft {
                store.pageSearchQuery = pageSearchDraft
              }
              store.selectNextPageSearchOccurrence()
            }
          Text(pageSearchDraft == store.pageSearchQuery ? store.pageSearchOccurrenceSummary : "Searching…")
            .font(.caption.monospacedDigit())
            .foregroundStyle(store.pageSearchOccurrenceCount == 0
              ? WorkspaceDesign.secondaryText
              : WorkspaceDesign.primaryText)
            .frame(minWidth: 72, alignment: .trailing)
          Button {
            store.selectPreviousPageSearchOccurrence()
          } label: {
            Label("Previous Occurrence", systemImage: "chevron.up")
          }
          .labelStyle(.iconOnly)
          .help("Previous occurrence")
          .disabled(pageSearchDraft != store.pageSearchQuery || !store.canNavigatePageSearchOccurrences)
          Button {
            store.selectNextPageSearchOccurrence()
          } label: {
            Label("Next Occurrence", systemImage: "chevron.down")
          }
          .labelStyle(.iconOnly)
          .help("Next occurrence")
          .disabled(pageSearchDraft != store.pageSearchQuery || !store.canNavigatePageSearchOccurrences)
          if !pageSearchDraft.isEmpty {
            Button {
              store.clearRenderedSearchHighlight()
            } label: {
              Label("Clear Page Search", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .help("Clear page search")
          }
        }
        .frame(maxWidth: 560)
        .onAppear {
          pageSearchDraft = store.pageSearchQuery
          isPageSearchFocused = true
        }
      }
    }
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkspaceDesign.surfaceBackground)
    .onChange(of: store.pageSearchFocusToken) {
      pageSearchDraft = store.pageSearchQuery
      isPageSearchFocused = true
    }
  }

  private var detailIdentity: some View {
    HStack(alignment: .center, spacing: 9) {
      WorkspaceIconBadge(systemImage: locationIcon, tint: .accentColor, fill: Color.accentColor.opacity(0.09))
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(location.title)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(location.title)
          if !store.selectedFileIsNativePreview,
             !store.selectedFileIsCSV,
             store.selectedEntrySource != nil {
            NodeEntityTypeMenu()
          }
          if !store.currentDocumentGoogleDrivePublications.isEmpty {
            GoogleDrivePublicationMenu(
              publications: store.currentDocumentGoogleDrivePublications
            )
          }
        }
        detailLocationLine
      }
    }
  }

  /// Zone/subtitle and source path share one caption line so the identity
  /// block stays the same height as other pane headers.
  private var detailLocationLine: some View {
    let path = store.relativePath(location.file)
      + (store.selectedFileIsNativePreview ? "" : ":\(location.lineForEditor)")
    let subtitle = location.subtitle
    let pathText = Text(path)
      .font(.caption2.monospaced())
      .foregroundColor(WorkspaceDesign.tertiaryText)
    let line: Text = subtitle.isEmpty
      ? pathText
      : Text(subtitle)
        .font(.caption)
        .foregroundColor(WorkspaceDesign.secondaryText)
        + Text("  ·  ")
        .font(.caption)
        .foregroundColor(WorkspaceDesign.tertiaryText)
        + pathText
    return line
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .help(subtitle.isEmpty ? path : "\(subtitle) · \(path)")
  }

  /// Previews and canvases have only a single file-level control, so it sits
  /// in the title row instead of adding a second toolbar row.
  private var usesInlineDetailActions: Bool {
    store.selectedFileIsCanvas || store.selectedFileIsNativePreview
  }

  @ViewBuilder
  private var inlineDetailActions: some View {
    if store.selectedFileIsCanvas {
      Button("Reveal Canvas", systemImage: "folder") { store.revealFile(path: location.file) }
        .labelStyle(.iconOnly)
        .help("Reveal canvas in Finder")
        .controlSize(.small)
        .buttonStyle(WorkspaceActionButtonStyle())
    } else if store.selectedFileIsNativePreview {
      WorkspaceControlStrip { sourceMenu }
        .controlSize(.small)
        .buttonStyle(WorkspaceActionButtonStyle())
        .fixedSize()
    }
  }

  private var headerMetadataRows: [(String, String)] {
    DetailMetadata.rows(for: location).filter { row in
      !(row.0 == "Zone" && row.1 == location.subtitle)
    }
  }

  private var locationIcon: String {
    switch location {
    case .agenda:
      return "calendar"
    case .assigned:
      return "person.crop.circle.badge.checkmark"
    case .search:
      return "magnifyingglass"
    case .backlink:
      return "link"
    case .aiChatThreadRecord:
      if store.selectedFileIsPDF { return "doc.richtext" }
      if store.selectedFileIsImage { return "photo" }
      if store.selectedFileIsVideo { return "film" }
      return store.selectedFileIsCSV ? "tablecells" : "doc.text"
    case .meeting:
      return "waveform.and.mic"
    }
  }

  private var detailActionBar: some View {
    // Canvas and preview controls render inline in the title row instead.
    ViewThatFits(in: .horizontal) {
      fullDetailActionBar
      condensedDetailActionBar
      compactDetailActionBar
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }

  private func dataNotebookRefreshFailureBanner(_ failure: DataNotebookRefreshFailure) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: failure.needsCredentialUpdate ? "key.slash.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(failure.title)
          .font(.callout.weight(.semibold))
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(WorkspaceDesign.secondaryText)
          .lineLimit(3)
      }

      Spacer(minLength: 12)

      if failure.needsCredentialUpdate {
        Button("Update Credentials") {
          store.presentScarfMetabaseConfiguration()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Button {
        Task { await store.refreshSelectedDataNotebook() }
      } label: {
        Label("Retry Refresh", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Retry data refresh")
      .disabled(store.isRefreshingDataNotebook)

      Button {
        store.dismissDataNotebookRefreshFailure()
      } label: {
        Label("Dismiss", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Dismiss refresh error")
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
    }
  }

  private var fullDetailActionBar: some View {
    HStack(spacing: 7) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }
      Spacer(minLength: 8)
      WorkspaceControlStrip {
        primaryDocumentControls
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var compactDetailActionBar: some View {
    WorkspaceControlStrip {
      detailNavigationControls
      viewAndResourceControls
      primaryDocumentControls
    }
    .labelStyle(.iconOnly)
    .fixedSize(horizontal: true, vertical: false)
  }

  private var condensedDetailActionBar: some View {
    HStack(spacing: 7) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }
      .labelStyle(.iconOnly)
      Spacer(minLength: 8)
      WorkspaceControlStrip {
        primaryDocumentControls
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var detailNavigationControls: some View {
    Group {
      if store.hasRenderedSearchHighlight {
        Button {
          store.clearRenderedSearchHighlight()
        } label: {
          Label("Clear Highlight", systemImage: "xmark.circle")
        }
        .labelStyle(.iconOnly)
        .help("Clear search match highlights")
      }
    }
  }

  private var viewAndResourceControls: some View {
    HStack(spacing: 7) {
      if !store.selectedFileIsCSV {
        if !store.isLiveFileEditorSelected && !store.hasActiveEdit {
          scopePicker
        }
        if !store.hasActiveEdit {
          documentLayoutMenu
        }
      }
      sourceMenu
      intelligenceMenu
    }
  }

  private var primaryDocumentControls: some View {
    HStack(spacing: 7) {
      if store.selectedFileIsDataNotebook {
        Button {
          Task { await store.refreshSelectedDataNotebook() }
        } label: {
          if store.isRefreshingDataNotebook {
            HStack(spacing: 5) {
              WorkspaceActivityIndicator(size: .small)
              Text("Refreshing Data")
            }
          } else {
            Label("Refresh Data", systemImage: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(!store.canRefreshSelectedDataNotebook)
        .help("Run every named data result in this notebook and update its generated tables")
      }
      editControls
      if !store.selectedFileIsCSV {
        organizeMenu
      }
    }
  }

  private var documentLayoutMenu: some View {
    @Bindable var store = store
    return Menu {
      Picker("Preview", selection: documentPreviewPreferenceBinding) {
        Label(
          "Automatic (\(store.inferredDocumentPreviewKind.title))",
          systemImage: OrgDocumentPreviewPreference.automatic.systemImage
        )
          .tag(OrgDocumentPreviewPreference.automatic)
        Label("Document", systemImage: OrgDocumentPreviewPreference.document.systemImage)
          .tag(OrgDocumentPreviewPreference.document)
        Label("Slides", systemImage: OrgDocumentPreviewPreference.slides.systemImage)
          .tag(OrgDocumentPreviewPreference.slides)
          .disabled(!store.canPreviewSlides)
      }

      Divider()

      Picker("Document Width", selection: $store.renderedDocumentWidth) {
        ForEach(RenderedDocumentWidth.allCases) { width in
          Text(width.title).tag(width)
        }
      }

      Picker("Side Margins", selection: $store.renderedDocumentMargin) {
        ForEach(RenderedDocumentMargin.allCases) { margin in
          Text(margin.title).tag(margin)
        }
      }

      Divider()

      Button {
        store.openAppHTMLStylesheet()
      } label: {
        Label(
          store.hasAppHTMLStylesheet ? "Edit Custom Stylesheet" : "Create Custom Stylesheet",
          systemImage: "paintbrush"
        )
      }

      if store.hasAppHTMLStylesheet {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Reload Custom Styles", systemImage: "arrow.clockwise")
        }
      }
    } label: {
      Label("View", systemImage: store.documentPreviewKind.systemImage)
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("\(store.documentPreviewPreferenceLabel) preview, width, margins, and stylesheet")
  }

  private var documentPreviewPreferenceBinding: Binding<OrgDocumentPreviewPreference> {
    Binding(
      get: { store.documentPreviewPreference },
      set: { store.setDocumentPreviewPreference($0) }
    )
  }

  private var sourceMenu: some View {
    Menu {
      LiveEmbedInsertButton()
      Divider()
      if store.selectedFileIsHTML {
        Button {
          store.showHTMLFileSource(!store.htmlFileShowsSource)
        } label: {
          Label(store.htmlFileShowsSource ? "View as Web Page" : "View HTML Source", systemImage: store.htmlFileShowsSource ? "globe" : "chevron.left.forwardslash.chevron.right")
        }
        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: location.file))
        } label: {
          Label("Open in Default Browser", systemImage: "safari")
        }
        Divider()
      }
      if !store.selectedFileIsNativePreview {
        PluginActionsMenu(context: .heading(file: location.file, line: location.lineForEditor), title: "Plugin Actions for Heading")
        PluginActionsMenu(context: .note(file: location.file), title: "Plugin Actions for Note")
      }
      Button {
        store.togglePinnedFile(path: location.file)
      } label: {
        Label(
          store.isFilePinned(path: location.file) ? "Unpin File" : "Pin File",
          systemImage: store.isFilePinned(path: location.file) ? "pin.slash" : "pin"
        )
      }

      Divider()

      Button {
        if store.selectedFileIsNativePreview {
          NSWorkspace.shared.open(URL(fileURLWithPath: location.file))
        } else {
          store.open(location)
        }
      } label: {
        Label(
          store.selectedFileIsNativePreview ? "Open in Default App" : "Open Source",
          systemImage: "arrow.up.forward.square"
        )
      }

      Button {
        store.revealSelectedLocation()
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      if !store.selectedFileIsNativePreview {
        Divider()

        Button {
          store.presentDocumentPublisher()
        } label: {
          Label("Publish Document…", systemImage: "square.and.arrow.up")
        }
        .disabled(!store.canPublishCurrentDocument)

        Button {
          Task { await store.exportCurrentDocumentPDF() }
        } label: {
          Label("Export Current Document as PDF…", systemImage: "doc.richtext")
        }
        .disabled(!store.canExportCurrentDocumentPDF)

        Divider()

        Button {
          Task { await store.exportSlides(format: .pdf) }
        } label: {
          Label("Export Slides as PDF…", systemImage: "rectangle.on.rectangle")
        }
        .disabled(!store.canExportSlides)

        Button {
          Task { await store.exportSlides(format: .latex) }
        } label: {
          Label("Export Slides as LaTeX…", systemImage: "doc.plaintext")
        }
        .disabled(!store.canExportSlides)

        Divider()

        Button {
          Task { await store.linkifyCurrentFile() }
        } label: {
          Label("Linkify File", systemImage: "link.badge.plus")
        }
        .disabled(!store.canLinkifyCurrentFile)
      }

    } label: {
      Label("File", systemImage: "doc.text.magnifyingglass")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Open, reveal, export, or linkify this file")
  }

  private var intelligenceMenu: some View {
    Menu {
      Button {
        store.askAIChatAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskAIChatAboutCurrentSelection || store.isLoadingEntrySource)

      Button {
        store.openCanonicalAIChatResourceThread()
      } label: {
        Label(
          "AI Thread",
          systemImage: store.hasCanonicalAIChatResourceThread ? "text.bubble.fill" : "text.bubble"
        )
      }
      .disabled(!store.canOpenCanonicalAIChatResourceThread)

      Divider()

      Button {
        store.toggleNodeContextPane()
      } label: {
        Label(store.isNodeContextPanePresented ? "Hide Context" : "Show Context", systemImage: "sidebar.right")
      }

      Button {
        Task { await store.briefCurrentNode() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Brief", systemImage: "hourglass")
        } else {
          Label("Brief", systemImage: "text.bubble")
        }
      }
      .disabled(!store.canBriefCurrentNode)

      Button {
        store.isNodeBriefOptionsPresented = true
      } label: {
        Label("Brief Options…", systemImage: "slider.horizontal.3")
      }

      if case .meeting = location {
        Button {
          store.askAIChatAboutSelectedMeeting()
        } label: {
          Label("Meeting", systemImage: "waveform.and.mic")
        }
      }
    } label: {
      Label("AI", systemImage: "sparkles")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Ask AI, open this resource's thread, or inspect context")
  }

  private var scopePicker: some View {
    Menu {
      Picker("Document Scope", selection: entrySourceModeSelection) {
        ForEach(EntrySourceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
    } label: {
      Label(store.selectedEntrySourceMode.title, systemImage: "doc.text")
    }
    .accessibilityLabel("Document scope")
    .fixedSize(horizontal: true, vertical: false)
    .onChange(of: store.selectedEntrySourceMode) {
      Task { await store.reloadSelectedEntrySource() }
    }
    .help("Render entry or full page scope")
  }

  private var entrySourceModeSelection: Binding<EntrySourceMode> {
    Binding(
      get: { store.selectedEntrySourceMode },
      set: { store.selectEntrySourceMode($0) }
    )
  }

  @ViewBuilder
  private var editControls: some View {
    HStack(spacing: 6) {
      editStatusIndicator

      if store.selectedFileIsCSV {
        Button {
          Task { await store.saveLiveFileEditor(explicit: true) }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .disabled(!store.canSaveLiveFileEditor)
        .help("Save CSV changes (Command-S)")

        Button {
          store.revertLiveFileEditor()
        } label: {
          Label("Revert", systemImage: "arrow.uturn.backward")
        }
        .disabled(!store.liveFileEditorHasUnsavedChanges || isPersistingEditorChanges)
        .help("Discard unsaved CSV changes")
      } else if store.hasActiveEdit {
        Button {
          Task { await store.saveActiveEdit() }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .disabled(!store.canSaveActiveEdit)
        .help("Save changes (Command-S)")

        Button {
          store.cancelActiveEdit()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .help(hasPendingEditorChanges ? "Discard changes" : "Close source editor")

        Button {
          Task { await store.saveAndFinishActiveEdit() }
        } label: {
          Label("Save & Done", systemImage: "checkmark.circle")
        }
        .disabled(isPersistingEditorChanges)
        .help(hasPendingEditorChanges ? "Save changes and close the editor" : "Close the editor")
      } else {
        Button {
          store.beginEditingCurrentScope(atSourceLine: renderedViewportSourceLine)
        } label: {
          Label("Edit", systemImage: "square.and.pencil")
        }
        .disabled(store.selectedEntrySource?.isEditable != true || store.isLoadingEntrySource)
        .help("Edit this file")
      }
    }
  }

  private var editStatusIndicator: some View {
    ZStack {
      if isPersistingEditorChanges {
        WorkspaceActivityIndicator(size: .small)
          .accessibilityLabel("Saving changes")
      } else if hasPendingEditorChanges {
        Image(systemName: "circle.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.orange)
          .accessibilityLabel("Unsaved changes")
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(width: 24, height: 24)
    .help(editStatusHelp)
  }

  private var isPersistingEditorChanges: Bool {
    store.isSavingEntry || store.isSavingBlock || store.isLiveFileEditorAutosaving
  }

  private var hasPendingEditorChanges: Bool {
    store.entryEditorHasUnsavedChanges
      || store.editingBlockID != nil
      || store.liveFileEditorHasUnsavedChanges
  }

  private var editStatusHelp: String {
    if isPersistingEditorChanges {
      return "Saving changes"
    }
    if hasPendingEditorChanges {
      return "Unsaved changes. Press Command-S to save."
    }
    return "No unsaved editor changes"
  }

  @ViewBuilder
  private var organizeMenu: some View {
    Menu {
      Menu {
        Button("TODO") {
          Task { await store.applyTodoShortcut(.todo) }
        }
        Button("In Progress") {
          Task { await store.applyTodoShortcut(.inProgress) }
        }
        Button("Done") {
          Task { await store.applyTodoShortcut(.done) }
        }
        Button("Canceled") {
          Task { await store.applyTodoShortcut(.canceled) }
        }
        Divider()
        Button {
          Task { await store.applyTodoShortcut(nil) }
        } label: {
          Label("Toggle", systemImage: "arrow.triangle.2.circlepath")
        }
      } label: {
        Label("Status", systemImage: "checkmark.circle")
      }

      Menu {
        planningButton("Today", kind: .scheduled, target: .today)
        planningButton("Tomorrow", kind: .scheduled, target: .tomorrow)
        planningButton("Next Monday", kind: .scheduled, target: .upcomingMonday)
        planningButton("Next Month", kind: .scheduled, target: .nextMonth)
      } label: {
        Label("Schedule", systemImage: "calendar")
      }

      Menu {
        planningButton("Today", kind: .deadline, target: .today)
        planningButton("Tomorrow", kind: .deadline, target: .tomorrow)
        planningButton("Next Monday", kind: .deadline, target: .upcomingMonday)
        planningButton("Next Month", kind: .deadline, target: .nextMonth)
      } label: {
        Label("Deadline", systemImage: "calendar.badge.exclamationmark")
      }

      Menu {
        Button("A") {
          Task { await store.applyPriorityShortcut("A") }
        }
        Button("B") {
          Task { await store.applyPriorityShortcut("B") }
        }
        Button("C") {
          Task { await store.applyPriorityShortcut("C") }
        }
        Divider()
        Button("Clear") {
          Task { await store.applyPriorityShortcut(nil) }
        }
      } label: {
        Label("Priority", systemImage: "flag")
      }

      Divider()

      Button {
        Task { await store.presentSimilarTodoAssignment() }
      } label: {
        Label("Find Similar TODOs...", systemImage: "rectangle.stack.badge.plus")
      }

      Menu {
        AgentHandoffMenuItems { profile in
          Task { await store.applyAgentHandoffShortcut(agentProfile: profile) }
        }
      } label: {
        Label("Pass to Agent", systemImage: "person.crop.circle.badge.checkmark")
      }

      Button {
        Task { await store.applyApproveAndAgentHandoffShortcut() }
      } label: {
        Label("Approve & Hand Off", systemImage: "checkmark.seal")
      }

      Button {
        store.promptAndApplyRejectApprovalShortcut()
      } label: {
        Label("Reject", systemImage: "xmark.octagon")
      }

      Button {
        store.promptAndApplyPropertyShortcut()
      } label: {
        Label("Set Property", systemImage: "tag")
      }
    } label: {
      Label("Organize", systemImage: "ellipsis.circle")
    }
    .disabled(!store.canOrganizeCurrentHeadline)
    .help("Status, schedule, deadline, priority, agent handoff, and properties")
  }

  private func planningButton(_ title: String, kind: PlanningEditKind, target: PlanningDateTarget) -> some View {
    Button(title) {
      Task { await store.applyPlanningShortcut(kind: kind, target: target) }
    }
  }
}

struct LiveFileEditorBody: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    Group {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.selectedFileIsCSV {
          CSVDocumentEditorView(source: source)
        } else if store.isEditingEntry {
          OrgSourceEditorWithLinkTools(interaction: store.sourceEditorInteraction)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering page",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        EmptyStateView(title: "Source Unavailable", detail: store.statusText, action: "Reveal File") {
          store.revealFile(path: location.file)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct OrgRenderedDocumentPreview: View {
  @Environment(WorkspaceStore.self) private var store
  let source: EntrySource
  let loadingLabel: String
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  private var startWorkAction: (@MainActor (Int) -> Void)? {
    guard source.isEditable else { return nil }
    let store = self.store
    return { line in store.startWork(onHeadingAt: line) }
  }

  var body: some View {
    Group {
      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane(reportViewportSourceLine: reportViewportSourceLine)
          .task(id: source) {
            store.scheduleSlidePreview(text: source.text, source: source, immediate: true)
          }
      } else if let html = store.selectedEntryHTML {
        VStack(spacing: 0) {
          if WorkspaceStore.showsEntityActionItems(for: source) {
            EntityActionItemsPanel(
              payload: store.entityActionItems,
              isLoading: store.isLoadingEntityActionItems,
              selectItem: store.selectEntityActionItem
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)
          }
          OrgHTMLDocumentView(
            html: html,
            renderIdentity: store.selectedEntryHTMLRenderIdentity,
            source: source,
            corpusRoot: store.corpusRoot,
            searchQuery: store.renderedSearchHighlightQuery,
            searchOccurrenceIndex: store.pageSearchSelectedOccurrenceIndex,
            searchOccurrenceCount: store.pageSearchOccurrenceCount,
            scrollRequest: store.detailScrollRequest,
            restorationSourceLine: store.documentViewportSourceLine(for: source),
            layout: store.renderedDocumentLayout,
            activateWorkspacePane: { store.activateWorkspacePane(.detail) },
            askAIAboutHeading: { store.askAIChatAboutSourceHeading(at: $0) },
            performEntryAction: { store.performRenderedEntryAction($0, at: $1) },
            peekEncryptedText: { line in Task { await store.peekOrgCrypt(line: line) } },
            reportStatus: { store.statusText = $0 },
            allowsCheckboxMutations: source.isEditable,
            setCheckboxState: { line, checked in
              await store.setRenderedDocumentCheckbox(at: line, checked: checked)
            },
            allowsTablePersistence: source.isEditable,
            saveTableView: { store.requestSaveRenderedTableView($0) },
            recalculateTableFormulas: { store.requestRecalculateRenderedTableFormulas(at: $0) },
            reportViewportSourceLine: reportViewportSourceLine,
            startWorkAtHeading: startWorkAction,
            openWorkAtHeading: { store.openWork(onHeadingAt: $0) },
            headingWorkBadges: store.headingWorkBadges(for: source)
          )
          .frame(maxHeight: .infinity)
        }
      } else if store.isSelectedRenderedBlocksReady {
        nativePreview
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        OrgHTMLLoadingView(label: loadingLabel, onCancel: store.cancelSelectedEntryLoading)
      }
    }
    .task(id: "\(source.id):\(WorkspaceStore.entityType(for: source)?.rawValue ?? "untyped")") {
      await store.loadEntityActionItems(for: source)
    }
  }

  private var nativePreview: some View {
    VStack(spacing: 0) {
      if WorkspaceStore.showsEntityActionItems(for: source) {
        EntityActionItemsPanel(
          payload: store.entityActionItems,
          isLoading: store.isLoadingEntityActionItems,
          selectItem: store.selectEntityActionItem
        )
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
      }

      if let error = store.selectedEntryRenderError {
        HStack(spacing: 8) {
          Label("Enhanced preview unavailable", systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .help(error)
          Spacer(minLength: 0)
          Button {
            store.retrySelectedEntryRendering()
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }
          .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(WorkspaceDesign.controlFill)
      }

      ScrollView {
        LegacyStructuredEntryEditorView(source: source)
          .padding(16)
      }
    }
  }
}

private struct EntityActionItemsPanel: View {
  let payload: NodeActionItemsPayload?
  let isLoading: Bool
  let selectItem: (NodeActionItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: "checklist")
          .foregroundStyle(.secondary)
        Text("Action items")
          .font(.callout.weight(.semibold))
        if let payload {
          Text(summary(payload))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let payload {
        if payload.open.isEmpty {
          Text("No open action items")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(payload.open) { item in
            actionRow(item, completed: false)
          }
        }

        if !payload.recentlyCompleted.isEmpty {
          Divider()
          Text("Recently completed")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(payload.recentlyCompleted) { item in
            actionRow(item, completed: true)
          }
        }
      } else if !isLoading {
        Text("Action items are unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(WorkspaceDesign.panelFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
    )
  }

  private func actionRow(_ item: NodeActionItem, completed: Bool) -> some View {
    Button {
      selectItem(item)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(completed ? Color.green : Color.secondary)
        if !completed {
          Text(statusLabel(item.todo))
            .font(.caption2.weight(.medium))
            .foregroundStyle(item.todo.uppercased() == "IN_PROGRESS" ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
              Capsule()
                .fill(Color.primary.opacity(0.05))
            )
        }
        Text(Org2Display.cleanInline(item.title))
          .font(.caption)
          .foregroundStyle(completed ? .secondary : .primary)
          .strikethrough(completed, color: .secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let metadata = metadata(item, completed: completed) {
          Text(metadata)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func summary(_ payload: NodeActionItemsPayload) -> String {
    var parts = ["\(payload.counts.open) open"]
    if payload.counts.recentlyCompleted > 0 {
      parts.append("\(payload.counts.recentlyCompleted) recent")
    }
    return parts.joined(separator: " · ")
  }

  private func metadata(_ item: NodeActionItem, completed: Bool) -> String? {
    if let date = item.date {
      if completed { return date }
      if item.dateKind == "deadline" { return "Due \(date)" }
      return date
    }
    if let meeting = item.meeting {
      return "From \(Org2Display.cleanInline(meeting.title))"
    }
    return nil
  }

  private func statusLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "IN_PROGRESS": return "In progress"
    case "WAITING": return "Waiting"
    case "BLOCKED": return "Blocked"
    case "NEXT": return "Next"
    default: return "Open"
    }
  }
}

private struct LegacyStructuredEntryEditorView: View {
  @Environment(WorkspaceStore.self) private var store
  let source: EntrySource

  var body: some View {
    OrgRenderedEntryView(
      blocks: store.selectedRenderedBlocks,
      blocksRenderSignature: store.selectedRenderedBlocksRenderSignature,
      source: OrgRenderedEntrySourceContext(source),
      corpusRoot: store.corpusRoot,
      selectedBlockID: store.selectedBlockID,
      selectedBlockIndex: store.selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] },
      editingBlockID: store.editingBlockID,
      foldedBlockIDs: store.foldedRenderedBlockIDs,
      detailScrollRequest: store.detailScrollRequest,
      sourceBlockRunsRenderSignature: store.sourceBlockRunsRenderSignature,
      sourceBlockRuns: store.sourceBlockRuns,
      searchHighlightQuery: store.renderedSearchHighlightQuery
    )
    .equatable()
  }
}

private struct OrgHTMLLoadingView: View {
  let label: String
  var onCancel: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        WorkspaceActivityIndicator(size: .small, style: .scan)
        Text(label)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let onCancel {
        Button("Stop Waiting", action: onCancel)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

struct LinkedPDFPreviewPane: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var zoomScale: CGFloat = 1
  @State private var pageCount = 0
  @State private var pageIndex: Int?
  @State private var navigationGeneration = 0
  @State private var navigationRequest: OrgPDFPageNavigationRequest?

  var body: some View {
    ZStack {
      if let data = store.linkedPDFPreviewData {
        OrgPDFDocumentView(
          data: data,
          zoomScale: zoomScale,
          navigationRequest: navigationRequest,
          reportViewportPageIndex: { pageIndex = $0 },
          reportPageCount: { pageCount = $0 }
        )
      } else if store.isLoadingLinkedPDFPreview {
        OrgHTMLLoadingView(label: "Loading PDF", onCancel: store.cancelLinkedPDFPreview)
      } else {
        unavailableView
      }
    }
    .overlay(alignment: .bottom) {
      if store.linkedPDFPreviewData != nil, pageCount > 0 {
        OrgPDFPreviewControls(
          pageIndex: pageIndex,
          pageCount: pageCount,
          zoomScale: zoomScale,
          navigate: navigate,
          zoomOut: {
            zoomScale = WorkspaceStore.previousSlidePreviewZoomScale(before: zoomScale)
          },
          resetZoom: { zoomScale = 1 },
          zoomIn: {
            zoomScale = WorkspaceStore.nextSlidePreviewZoomScale(after: zoomScale)
          }
        )
        .padding(14)
      }
    }
    .overlay(alignment: .topTrailing) {
      if store.linkedPDFPreviewData != nil {
        Button {
          store.retryLinkedPDFPreview()
        } label: {
          if store.isLoadingLinkedPDFPreview {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(9)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(WorkspaceDesign.hairline))
        .padding(12)
        .disabled(store.isLoadingLinkedPDFPreview)
        .help(store.isLoadingLinkedPDFPreview ? "Refreshing PDF preview" : "Refresh PDF preview")
        .accessibilityLabel(store.isLoadingLinkedPDFPreview ? "Refreshing PDF preview" : "Refresh PDF preview")
      }
    }
    .task(id: store.selectedLocation?.file) {
      zoomScale = 1
      pageCount = 0
      pageIndex = nil
      navigationRequest = nil
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private func navigate(_ target: OrgPDFPageNavigationTarget) {
    navigationGeneration += 1
    navigationRequest = OrgPDFPageNavigationRequest(id: navigationGeneration, target: target)
  }

  private var unavailableView: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.richtext")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("PDF preview unavailable")
        .font(.headline)
      Text(store.linkedPDFPreviewError ?? "Preparing the linked PDF.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      Button {
        store.retryLinkedPDFPreview()
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSlidePreviewPane: View {
  @Environment(WorkspaceStore.self) private var store
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

  var body: some View {
    ZStack {
      if let pdf = store.slidePreviewPDF {
        OrgPDFDocumentView(
          data: pdf,
          scrollRequest: store.detailScrollRequest,
          restorationSourceLine: store.currentDocumentViewportSourceLine,
          restorationPageIndex: store.currentDocumentSlidePageIndex,
          zoomScale: store.slidePreviewZoomScale,
          navigationRequest: store.slidePreviewNavigationRequest,
          reportViewportSourceLine: reportViewportSourceLine,
          reportViewportPageIndex: { store.recordDocumentSlidePageIndex($0) },
          reportPageCount: { store.setSlidePreviewPageCount($0) }
        )
      } else if store.isRenderingSlidePreview {
        OrgHTMLLoadingView(label: "Compiling slides", onCancel: store.cancelSlidePreview)
      } else {
        unavailableView
      }
    }
    .overlay(alignment: .topTrailing) {
      if store.slidePreviewPDF != nil,
         store.isRenderingSlidePreview {
        HStack(spacing: 6) {
          WorkspaceActivityIndicator(size: .small)
          Text("Compiling")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
      }
    }
    .overlay(alignment: .topLeading) {
      if store.slidePreviewPDF != nil,
         let error = store.slidePreviewError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .lineLimit(2)
          Button("Retry") {
            store.retrySlidePreview()
          }
          .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
      }
    }
    .overlay(alignment: .bottom) {
      if store.slidePreviewPDF != nil, store.slidePreviewPageCount > 0 {
        OrgPDFPreviewControls(
          pageIndex: store.currentDocumentSlidePageIndex,
          pageCount: store.slidePreviewPageCount,
          zoomScale: store.slidePreviewZoomScale,
          navigate: store.requestSlidePreviewNavigation,
          zoomOut: store.zoomSlidePreviewOut,
          resetZoom: store.resetSlidePreviewZoom,
          zoomIn: store.zoomSlidePreviewIn
        )
          .padding(14)
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private var unavailableView: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle.slash")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Slide preview unavailable")
        .font(.headline)
      Text(unavailableMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      if store.canPreviewSlides {
        Button {
          store.retrySlidePreview()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var unavailableMessage: String {
    if !store.canPreviewSlides {
      return "Open the full Org page to compile its slide deck."
    }
    return store.slidePreviewError ?? "Preparing the compiled PDF."
  }
}

private struct OrgPDFPreviewControls: View {
  let pageIndex: Int?
  let pageCount: Int
  let zoomScale: CGFloat
  let navigate: (OrgPDFPageNavigationTarget) -> Void
  let zoomOut: () -> Void
  let resetZoom: () -> Void
  let zoomIn: () -> Void
  @State private var pageNumberText = "1"

  var body: some View {
    HStack(spacing: 8) {
      Button {
        navigate(.previous)
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled((pageIndex ?? 0) <= 0)
      .help("Previous page")

      TextField("Page", text: $pageNumberText)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .frame(width: 30)
        .onSubmit(jumpToEnteredPage)
        .accessibilityLabel("Page number")

      Text("of \(pageCount)")
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Button {
        navigate(.next)
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled((pageIndex ?? 0) >= pageCount - 1)
      .help("Next page")

      Divider()
        .frame(height: 16)

      Button {
        zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .help("Zoom out (Command-Minus)")

      Button {
        resetZoom()
      } label: {
        Text("\(Int((zoomScale * 100).rounded()))%")
          .monospacedDigit()
          .frame(minWidth: 36)
      }
      .help("Fit PDF to the window")

      Button {
        zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .help("Zoom in (Command-Plus)")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(WorkspaceDesign.hairline))
    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    .onAppear(perform: updatePageNumberText)
    .onChange(of: pageIndex) { updatePageNumberText() }
  }

  private func jumpToEnteredPage() {
    guard let pageNumber = Int(pageNumberText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      updatePageNumberText()
      return
    }
    let clampedPage = min(max(1, pageNumber), pageCount)
    pageNumberText = String(clampedPage)
    navigate(.page(clampedPage - 1))
  }

  private func updatePageNumberText() {
    pageNumberText = String((pageIndex ?? 0) + 1)
  }
}

private struct OrgHTMLRenderFailureView: View {
  @Environment(WorkspaceStore.self) private var store
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Preview unavailable")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      HStack(spacing: 8) {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
        if store.selectedEntrySource?.isEditable == true {
          Button {
            store.beginEditingSelectedEntry()
          } label: {
            Label("Edit Source", systemImage: "square.and.pencil")
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSourceEditorWithLinkTools: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  @ObservedObject var interaction: SourceEditorInteractionModel
  @State private var sourcePreviewLine: Int?
  @State private var sourceCaretLocalLine: Int?
  @State private var sourceSelectionSnapshot: OrgSyntaxTextEditorSelectionSnapshot?
  @State private var sourcePreviewScrollTask: Task<Void, Never>?
  @State private var dateMentionState = WorkspaceDateMentionCompletionState()
  @State private var slashCommandState = WorkspaceSlashCommandCompletionState()
  @StateObject private var prose = OrgProseEditorController()
  @State private var showsProseSidebar = true

  private var isProse: Bool { store.sourceEditorPresentation == .prose }

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      sourceEditorCommandBar

      if store.sourceEditorPresentation == .split {
        HSplitView {
          sourceColumn
            .frame(minWidth: 360)
          sourcePreview
            .frame(minWidth: 320)
        }
      } else if isProse {
        proseColumn
      } else {
        sourceColumn
      }
    }
    .sheet(item: $prose.alternativeDraft) { draft in
      OrgProseAlternativeSheet(controller: prose, draft: draft)
    }
    .onAppear {
      prose.onStatus = { [store] status in store.statusText = status }
    }
    .task {
      scheduleSourcePreviewScroll()
      if store.sourceEditorPresentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: interaction.text) {
      store.noteSourceEditorLocalTextChanged(interaction.text)
      store.scheduleSourceEditorPreview(text: interaction.text)
    }
    .onChange(of: store.sourceEditorPresentation) { _, presentation in
      scheduleSourcePreviewScroll()
      if presentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: store.documentPreviewKind) {
      scheduleSourcePreviewScroll()
      store.scheduleSourceEditorPreview(immediate: true)
    }
    .onChange(of: store.selectedEntrySource?.id) {
      sourceCaretLocalLine = nil
      sourceSelectionSnapshot = nil
      sourcePreviewLine = nil
    }
    .onDisappear {
      sourcePreviewScrollTask?.cancel()
    }
  }

  private var proseColumn: some View {
    HStack(spacing: 0) {
      ZStack {
        // Clicking the empty prose margin collapses the selection so the
        // highlight never feels stuck; clicks on text stay with the editor.
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onTapGesture { prose.clearSelectionKeepingCaret() }
        sourceEditor(prose: true)
          .frame(maxWidth: OrgProsePresentation.measure)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(WorkspaceDesign.surfaceBackground)
      if showsProseSidebar {
        OrgProseSidebar(controller: prose)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
  }

  private var sourceColumn: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 8) {
      sourceEditor(prose: false)
      .frame(minHeight: 320, maxHeight: .infinity)
      .layoutPriority(1)
      .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )

      if hasSelection && !isProse {
        ParagraphInlineFormatBar(
          text: $interaction.text,
          selectedRange: $interaction.selection,
          insertBacklink: insertBacklinkForSelection,
          createNodeFromSelection: createNodeFromSelection
        )
      }

      if let wikiLinkCompletionMatch {
        ParagraphWikiLinkCompletionPanel(
          query: wikiLinkCompletionMatch.query,
          candidates: orgRoamLinkResolver.searchCandidates(matching: wikiLinkCompletionMatch.query, limit: 6),
          choose: { node in
            resolveWikiLinkCompletion(wikiLinkCompletionMatch, to: node)
          },
          create: {
            createNodeFromWikiLinkCompletion(wikiLinkCompletionMatch)
          }
        )
      } else if let slashMatch = sourceSelectionSnapshot.flatMap(WorkspaceSlashCommands.match(in:)),
                !slashCommandState.isDismissed(slashMatch) {
        let options = WorkspaceSlashCommands.options(for: slashMatch)
        WorkspaceSlashCommandPanel(
          options: options,
          selectedIndex: slashCommandState.selectedIndex(for: slashMatch, optionCount: options.count),
          choose: { command in
            let removedNatively = OrgSyntaxTextEditorInsertionTarget.focused()?.replace(
              slashMatch.replacementRange,
              with: "",
              expectedPrefix: "/"
            ) == true
            if !removedNatively {
              OrgSyntaxTextEditor.publishPendingTextChanges()
              let text = interaction.text as NSString
              guard NSMaxRange(slashMatch.replacementRange) <= text.length else { return }
              applyInlineEdit(InlineSelectionReplacement(
                text: text.replacingCharacters(in: slashMatch.replacementRange, with: ""),
                selectedRange: NSRange(location: slashMatch.replacementRange.location, length: 0)
              ))
            }
            runSlashCommand(command)
          }
        )
      } else if let dateMentionMatch = sourceSelectionSnapshot.flatMap(WorkspaceDateMentions.match(in:)),
                !dateMentionState.isDismissed(dateMentionMatch) {
        let options = dateMentionOptions(for: dateMentionMatch)
        if !options.isEmpty {
          WorkspaceDateMentionCompletionPanel(
            options: options,
            selectedIndex: dateMentionState.selectedIndex(for: dateMentionMatch, optionCount: options.count),
            choose: { option in
              completeDateMention(dateMentionMatch, with: option)
            }
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func sourceEditor(prose: Bool) -> some View {
    @Bindable var store = store
    let sourceAtMount = store.selectedEntrySource
    let activeProse: OrgProseEditorController? = prose ? self.prose : nil
    let dateMentionKeyHandler: ((OrgSyntaxTextEditorCompletionKey, OrgSyntaxTextEditorSelectionSnapshot) -> OrgSyntaxTextEditorCompletionKeyResult)? =
      prose ? nil : { key, snapshot in
        let slashResult = handleSlashCommandKey(key, snapshot: snapshot)
        if case .ignored = slashResult {
          return handleDateMentionKey(key, snapshot: snapshot)
        }
        return slashResult
      }
    // Code, markup, config, and data files are highlighted as their own
    // language and skip Org-only analysis and writing commands.
    let codeLanguage = prose ? nil : OrgCodeHighlighter.language(forPath: sourceAtMount?.file)
    let analyzer: ((String) async -> OrgSourceEditorSemanticSnapshot?)? = prose || codeLanguage != nil
      ? nil
      : { text in await store.analyzeSourceEditorText(text) }
    OrgSyntaxTextEditor(
      text: $interaction.text,
      monospaced: !prose,
      showsScrollers: true,
      textInset: prose ? NSSize(width: 28, height: 32) : NSSize(width: 12, height: 12),
      focusOnAppear: true,
      textPublishing: .deferred(milliseconds: 500),
      liveHighlighting: true,
      incrementalHighlighting: true,
      incrementalHighlightingDelayMilliseconds: 120,
      concealsSyntax: prose,
      orgWritingCommands: !prose && codeLanguage == nil,
      pasteAsOrgEnabled: { store.experimentalFeaturesEnabled && codeLanguage == nil },
      textChecking: codeLanguage == nil ? .spellingAndGrammar : .disabled,
      caretPublishingDelayMilliseconds: 180,
      semanticAnalysisDelayMilliseconds: 900,
      commandRequest: store.sourceEditorCommandRequest,
      semanticAnalyzer: analyzer,
      diagnostics: $store.sourceEditorDiagnostics,
      onCommandStatus: { status in
        store.statusText = status
      },
      selection: $interaction.selection,
      onSelectionSnapshot: { snapshot in
        sourceSelectionSnapshot = snapshot
        if sourceCaretLocalLine != snapshot.sourceLine {
          sourceCaretLocalLine = snapshot.sourceLine
          scheduleSourcePreviewScroll()
        }
      },
      onViewportSourceLine: { line in
        guard let source = store.selectedEntrySource else { return }
        store.recordDocumentViewportSourceLine(
          source.startLine + line - 1,
          for: source
        )
      },
      onGutterBacklinks: { line in
        store.showSourceEditorBacklinks(at: line)
      },
      onLocalTextChange: { text in
        store.noteSourceEditorLocalTextChanged(text)
        if store.sourceEditorPresentation == .split {
          store.scheduleSourceEditorPreview(text: text)
        }
      },
      documentIdentity: sourceAtMount?.id,
      onCheckpointText: { text in
        if let sourceAtMount {
          store.persistSourceEditorCheckpoint(text, source: sourceAtMount)
        }
      },
      documentGeneration: { interaction.documentGeneration },
      bindingGeneration: { interaction.bindingGeneration },
      onTextPublicationConflict: { text in
        if let sourceAtMount {
          store.preserveSourceEditorDraftAfterPublicationConflict(
            text,
            source: sourceAtMount
          )
        }
      },
      onSaveCommand: { context in
        interaction.text = context.text
        store.noteSourceEditorLocalTextChanged(context.text)
        Task { await store.saveEditedEntry() }
        return true
      },
      completionKeyHandler: codeLanguage == nil ? dateMentionKeyHandler : nil,
      proseController: activeProse,
      codeLanguage: codeLanguage,
      vimMode: store.sourceEditorVimModeEnabled
    )
  }

  private func dateMentionOptions(for match: WorkspaceDateMentionMatch) -> [WorkspaceDateMentionOption] {
    store.dateMentionEditorOptions(for: match, sourceFile: store.selectedEntrySource?.file)
  }

  private func handleDateMentionKey(
    _ key: OrgSyntaxTextEditorCompletionKey,
    snapshot: OrgSyntaxTextEditorSelectionSnapshot
  ) -> OrgSyntaxTextEditorCompletionKeyResult {
    guard ParagraphWikiLinkCompletion.match(in: snapshot) == nil,
          let match = WorkspaceDateMentions.match(in: snapshot)
    else { return .ignored }
    let result = dateMentionState.handle(key, match: match, options: dateMentionOptions(for: match))
    if case .replace = result {
      sourceSelectionSnapshot = nil
    }
    return result
  }

  private func handleSlashCommandKey(
    _ key: OrgSyntaxTextEditorCompletionKey,
    snapshot: OrgSyntaxTextEditorSelectionSnapshot
  ) -> OrgSyntaxTextEditorCompletionKeyResult {
    guard ParagraphWikiLinkCompletion.match(in: snapshot) == nil,
          let match = WorkspaceSlashCommands.match(in: snapshot)
    else { return .ignored }
    var accepted: WorkspaceSlashCommand?
    let result = slashCommandState.handle(
      key,
      match: match,
      options: WorkspaceSlashCommands.options(for: match),
      accepted: &accepted
    )
    if case .replace = result {
      sourceSelectionSnapshot = nil
    }
    if let accepted {
      // Let the editor remove the typed command before the picker opens.
      Task { @MainActor in runSlashCommand(accepted) }
    }
    return result
  }

  private func runSlashCommand(_ command: WorkspaceSlashCommand) {
    switch command {
    case .image:
      // Capture the editor before the picker takes focus from it.
      let target = OrgSyntaxTextEditorInsertionTarget.focused()
      guard let imageURL = WorkspaceSlashCommands.chooseImage() else { return }
      Task { @MainActor in
        guard let link = await store.importSourceEditorImage(from: imageURL) else { return }
        if let target {
          if target.replace(with: link) { return }
          // The editor closed or switched documents while the image was
          // chosen. Never drop the link silently.
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(link, forType: .string)
          store.statusText = "The editor changed before the image was inserted. Its link is on the clipboard."
          return
        }
        OrgSyntaxTextEditor.publishPendingTextChanges()
        let text = interaction.text as NSString
        let selection = interaction.selection
        let location = min(max(0, selection.location), text.length)
        let length = min(max(0, selection.length), text.length - location)
        applyInlineEdit(InlineSelectionReplacement(
          text: text.replacingCharacters(in: NSRange(location: location, length: length), with: link),
          selectedRange: NSRange(location: location + (link as NSString).length, length: 0)
        ))
      }
    }
  }

  private func completeDateMention(_ match: WorkspaceDateMentionMatch, with option: WorkspaceDateMentionOption) {
    OrgSyntaxTextEditor.publishPendingTextChanges()
    guard let edit = option.replacement(in: interaction.text, match: match) else { return }
    applyInlineEdit(edit)
  }

  private var sourcePreview: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Label("Preview", systemImage: store.documentPreviewKind.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        if (store.documentPreviewKind == .slides
          ? store.isRenderingSlidePreview
          : store.isRenderingSourceEditorPreview) {
          WorkspaceActivityIndicator(size: .small)
            .help("Updating preview")
        }

        Menu {
          Picker("Preview kind", selection: documentPreviewPreferenceBinding) {
            Label(
              "Automatic (\(store.inferredDocumentPreviewKind.title))",
              systemImage: OrgDocumentPreviewPreference.automatic.systemImage
            )
              .tag(OrgDocumentPreviewPreference.automatic)
            Label("Document", systemImage: OrgDocumentPreviewPreference.document.systemImage)
              .tag(OrgDocumentPreviewPreference.document)
            Label("Slides", systemImage: OrgDocumentPreviewPreference.slides.systemImage)
              .tag(OrgDocumentPreviewPreference.slides)
              .disabled(!store.canPreviewSlides)
          }
        } label: {
          Image(systemName: store.documentPreviewKind.systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(store.documentPreviewPreferenceLabel) preview")

        Button {
          store.setSourceEditorPreviewPaused(!store.isSourceEditorPreviewPaused)
        } label: {
          Image(systemName: store.isSourceEditorPreviewPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 22)
        .help(store.isSourceEditorPreviewPaused ? "Resume live preview" : "Pause live preview")
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(WorkspaceDesign.panelFill)

      Divider()

      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane()
      } else {
        if let html = store.sourceEditorPreviewHTML,
           let source = store.selectedEntrySource {
          OrgHTMLDocumentView(
            html: html,
            source: source,
            corpusRoot: store.corpusRoot,
            searchQuery: nil,
            searchOccurrenceIndex: nil,
            searchOccurrenceCount: 0,
            scrollRequest: sourcePreviewScrollRequest,
            restorationSourceLine: store.documentViewportSourceLine(for: source),
            layout: store.renderedDocumentLayout,
            activateWorkspacePane: { store.activateWorkspacePane(.detail) },
            askAIAboutHeading: { store.askAIChatAboutSourceHeading(at: $0) },
            performEntryAction: { _, _ in },
            peekEncryptedText: { line in Task { await store.peekOrgCrypt(line: line) } },
            allowsEntryContextMenu: false,
            reportStatus: { store.statusText = $0 },
            reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0, for: source) }
          )
        } else if let error = store.sourceEditorPreviewError {
          OrgHTMLRenderFailureView(message: error)
        } else {
          OrgHTMLLoadingView(label: "Preparing preview")
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(width: 1)
    }
  }

  private var documentPreviewPreferenceBinding: Binding<OrgDocumentPreviewPreference> {
    Binding(
      get: { store.documentPreviewPreference },
      set: { store.setDocumentPreviewPreference($0) }
    )
  }

  private var sourcePreviewScrollRequest: DetailScrollRequest? {
    sourcePreviewLine.map { DetailScrollRequest(id: $0, target: .sourceLine($0)) }
  }

  private func scheduleSourcePreviewScroll() {
    sourcePreviewScrollTask?.cancel()
    guard store.sourceEditorPresentation == .split,
          let source = store.selectedEntrySource,
          let localLine = sourceCaretLocalLine
    else {
      sourcePreviewLine = nil
      return
    }
    let sourceID = source.id
    let sourceStartLine = source.startLine
    sourcePreviewScrollTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 90_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled,
            store.sourceEditorPresentation == .split,
            store.selectedEntrySource?.id == sourceID
      else { return }
      sourcePreviewLine = sourceStartLine + localLine - 1
    }
  }

  private var sourceEditorCommandBar: some View {
    @Bindable var store = store
    return HStack(spacing: 8) {
      if isProse {
        OrgProseToolbar(controller: prose, showsSidebar: $showsProseSidebar)
      } else {
      HStack(spacing: 6) {
        Menu {
          Button("Heading") { store.requestSourceEditorCommand(.insertHeading) }
          Button("List Item") { store.requestSourceEditorCommand(.insertListItem) }
          Divider()
          Button("Link...") { store.requestSourceEditorCommand(.insertLink) }
          LiveEmbedInsertButton()
          Button("Property...") { store.requestSourceEditorCommand(.insertProperty) }
        } label: {
          Label("Insert", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Button {
          store.requestSourceEditorCommand(.cycleTodo)
        } label: {
          Label("Cycle TODO", systemImage: "arrow.triangle.2.circlepath")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 26, height: 24)
        .help("Cycle TODO (Command-Option-T)")

        Menu {
          Button("Schedule Today") { store.requestSourceEditorCommand(.scheduleToday) }
          Button("Deadline Today") { store.requestSourceEditorCommand(.deadlineToday) }
          Button("Clear Planning") { store.requestSourceEditorCommand(.clearPlanning) }
        } label: {
          Label("Planning", systemImage: "calendar.badge.clock")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .frame(width: 26, height: 24)
        .fixedSize()
        .help("Planning")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      ControlGroup {
        Button {
          store.requestSourceEditorCommand(.promote)
        } label: {
          Label("Promote", systemImage: "decrease.indent")
        }
        .labelStyle(.iconOnly)
        .help("Promote (Command-Option-Left Arrow)")

        Button {
          store.requestSourceEditorCommand(.demote)
        } label: {
          Label("Demote", systemImage: "increase.indent")
        }
        .labelStyle(.iconOnly)
        .help("Demote (Command-Option-Right Arrow)")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      Menu {
        Button("Toggle Current Heading") { store.requestSourceEditorCommand(.toggleFold) }
        Button("Expand All") { store.requestSourceEditorCommand(.unfoldAll) }
        Divider()
        Button("Previous Heading") { store.requestSourceEditorCommand(.previousHeading) }
        Button("Next Heading") { store.requestSourceEditorCommand(.nextHeading) }
      } label: {
        Label("Outline", systemImage: "list.bullet.indent")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Outline and folding")
      }

      Spacer(minLength: 8)

      if let diagnostic = store.sourceEditorDiagnostics.first {
        Label(
          store.sourceEditorDiagnostics.count == 1
            ? "Line \(diagnostic.line)"
            : "\(store.sourceEditorDiagnostics.count) issues",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .help(diagnostic.message)
      }

      Divider()
        .frame(height: 18)

      Picker("Editor presentation", selection: $store.sourceEditorPresentation) {
        ForEach(SourceEditorPresentation.allCases) { presentation in
          Image(systemName: presentation.systemImage)
            .tag(presentation)
            .help(presentation.title)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 102)
      .help("Source, live source and HTML preview, or distraction-free Prose")
    }
    .controlSize(.small)
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var hasSelection: Bool {
    interaction.selection.length > 0
  }

  private var wikiLinkCompletionMatch: ParagraphWikiLinkCompletionMatch? {
    sourceSelectionSnapshot.flatMap(ParagraphWikiLinkCompletion.match(in:))
  }

  private func insertBacklinkForSelection() {
    guard let edit = WorkspaceStore.backlinkReplacementForSelectedText(
      in: interaction.text,
      range: interaction.selection
    ) else {
      store.statusText = "Select text first"
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromSelection() {
    let text = interaction.text
    let range = interaction.selection
    Task {
      guard let edit = await store.createKnowledgeNodeFromSelection(text: text, range: range) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func resolveWikiLinkCompletion(
    _ match: ParagraphWikiLinkCompletionMatch,
    to node: OrgRoamNodeReference
  ) {
    guard let edit = ParagraphWikiLinkCompletion.replacement(
      in: interaction.text,
      match: match,
      node: node
    ) else {
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromWikiLinkCompletion(_ match: ParagraphWikiLinkCompletionMatch) {
    let text = interaction.text
    Task {
      guard let edit = await store.createKnowledgeNodeFromWikiLinkCompletion(text: text, match: match) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func applyInlineEdit(_ edit: InlineSelectionReplacement) {
    sourceSelectionSnapshot = nil
    interaction.text = edit.text
    interaction.selection = edit.selectedRange
    store.noteSourceEditorLocalTextChanged(edit.text)
  }
}

struct EntryBodyView: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.isEditingEntry {
          OrgSourceEditorWithLinkTools(interaction: store.sourceEditorInteraction)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering preview",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        fallbackBody(location)
          .padding(16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contextMenu {
      Button {
        store.askAIChatAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskAIChatAboutCurrentSelection || store.isLoadingEntrySource)
    }
  }

  @ViewBuilder
  private func fallbackBody(_ location: WorkspaceLocation) -> some View {
    switch location {
    case .agenda(let item):
      Text(Org2Display.cleanBlock(item.body ?? ""))
        .font(.body)
        .textSelection(.enabled)
    case .assigned(let item):
      Text(Org2Display.cleanInline(item.headline))
        .font(.body)
        .textSelection(.enabled)
    case .search(let result):
      Text(Org2Display.cleanInline(result.snippet))
        .font(.body)
        .textSelection(.enabled)
    case .backlink(let backlink):
      Text(Org2Display.cleanInline(backlink.context))
        .font(.body)
        .textSelection(.enabled)
    case .aiChatThreadRecord:
      Text("Source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .meeting:
      Text("Meeting source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

}

private enum DetailMetadata {
  static func rows(for location: WorkspaceLocation) -> [(String, String)] {
    switch location {
    case .agenda(let item):
      let planning = [item.kind, item.time].compactMap { $0 }.joined(separator: " ")
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Planning", planning),
        ("Priority", item.priority.map { "[#\($0)]" } ?? ""),
        ("Tags", item.tags.joined(separator: ", ")),
        ("ID", item.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .assigned(let item):
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Assignee", item.assignee),
        ("Status", item.status),
        ("Assigned", item.assignedAt ?? ""),
        ("Last Update", item.lastAgentUpdate ?? ""),
        ("Tags", item.tags.joined(separator: ", "))
      ]
      return nonEmptyRows(rows)
    case .search(let result):
      let rows: [(String, String)] = [
        ("TODO", result.todo ?? ""),
        ("Heading", result.heading.map(Org2Display.cleanInline) ?? ""),
        ("Date", result.date ?? ""),
        ("Tags", result.tags.joined(separator: ", ")),
        ("ID", result.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .backlink(let backlink):
      return [
        ("Source", Org2Display.cleanInline(backlink.srcTitle)),
        ("Line", "\(backlink.lineForEditor)")
      ]
    case .aiChatThreadRecord(let thread):
      let rows: [(String, String)] = [
        ("Zone", thread.zone),
        ("Modified", thread.modifiedAt.map(dateLabel) ?? ""),
        ("ID", thread.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .meeting(let meeting):
      let rows: [(String, String)] = [
        ("Recorded", meeting.recordedAt ?? ""),
        ("Audio", meeting.audioArtifact ?? ""),
        ("System Audio", meeting.systemAudioArtifact ?? ""),
        ("Transcript", meeting.transcriptArtifact ?? ""),
        ("Transcription", meeting.transcriptionStatus ?? ""),
        ("ID", meeting.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    }
  }

  private static func nonEmptyRows(_ rows: [(String, String)]) -> [(String, String)] {
    rows.filter { !$0.1.isEmpty }
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

private struct DetailMetadataGrid: View {
  let rows: [(String, String)]

  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(rows, id: \.0) { row in
          GridRow {
            Text(row.0)
              .font(.caption2.weight(.medium))
              .foregroundStyle(WorkspaceDesign.tertiaryText)
            Text(row.1)
              .font(.caption)
              .foregroundStyle(WorkspaceDesign.secondaryText)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}

struct NodeContextPane: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Context", systemImage: "sidebar.right")
          .font(.headline)
        Spacer()
        if store.isLoadingBacklinks {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          store.toggleNodeContextPane()
        } label: {
          Label("Hide Context", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Hide context")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 8)

      Picker("Context view", selection: $store.nodeContextTab) {
        ForEach(NodeContextTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Context view")
      .frame(maxWidth: .infinity)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)

      Divider()

      ScrollView {
        switch store.nodeContextTab {
        case .overview:
          NodeContextOverview()
        case .references:
          NodeContextReferences()
        case .related:
          NodeContextRelated()
        case .connections:
          NodeConnectionsView()
        case .brief:
          NodeContextBrief()
        }
      }
    }
    .background(WorkspaceDesign.barBackground)
  }
}

private struct NodeContextOverview: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      NodeContextStats()

      Button {
        Task { await store.briefCurrentNode() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Building Brief", systemImage: "hourglass")
        } else {
          Label("Brief This Node", systemImage: "text.bubble")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(!store.canBriefCurrentNode)
      .help(store.nodeBriefStartsNewThread
        ? "Generate the brief in a new \(store.nodeBriefDestination.title) chat thread."
        : "Generate the brief in the current AI chat thread.")

      NodeBriefOptionsButton()

      if store.backlinkFileGroups.isEmpty {
        NodeContextEmptyText()
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Top Referencing Files")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(store.backlinkFileGroups.prefix(8)) { group in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(group.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Spacer(minLength: 0)
              CountPill(count: group.count)
            }
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeContextReferences: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    if store.backlinkFileGroups.isEmpty {
      NodeContextEmptyText()
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(store.backlinkFileGroups) { group in
          BacklinkFileGroupRow(group: group)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
      .padding(.bottom, 8)
    }
  }
}

private struct NodeContextRelated: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    let items = store.relatedBacklinkNodes
    if items.isEmpty {
      Text("No high-signal related nodes yet. Generic sections like Summary, Details, and Raw transcript are hidden from this list.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
              WorkspaceIconBadge(systemImage: "link")
              VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                  .font(.callout.weight(.medium))
                  .lineLimit(2)
                Text(item.primaryPath)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                ForEach(item.examples, id: \.self) { example in
                  Text(example)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              Spacer(minLength: 0)
              VStack(alignment: .trailing, spacing: 4) {
                CountPill(count: item.referenceCount)
                Text(item.fileCount == 1 ? "1 file" : "\(item.fileCount) files")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .monospacedDigit()
              }
            }
            if let idValue = item.idValue {
              Text(Org2Display.shortID(idValue))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.horizontal, WorkspaceDesign.contentInset)
          .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
    }
  }
}

private struct NodeContextBrief: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let artifact = store.currentNodeBriefArtifact {
        HStack(alignment: .top, spacing: 8) {
          WorkspaceIconBadge(systemImage: "doc.text")
          VStack(alignment: .leading, spacing: 3) {
            Text(artifact.title)
              .font(.headline)
            Text(artifact.relativePath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Spacer(minLength: 0)
        }

        Button {
          store.openCurrentNodeBriefArtifact()
        } label: {
          Label("Open Full Brief", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        Divider()

        NodeBriefRenderedPreview(
          artifact: artifact,
          corpusRoot: store.corpusRoot
        )
      } else {
        Text("Generate a source-cited brief for this node, save it as an agent-neutral view artifact, and show it here.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await store.briefCurrentNode() }
        } label: {
          if store.isBuildingNodeBrief {
            Label("Building Brief", systemImage: "hourglass")
          } else {
            Label("Brief This Node", systemImage: "text.bubble")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.canBriefCurrentNode)
        .help(store.nodeBriefStartsNewThread
          ? "Generate the brief in a new \(store.nodeBriefDestination.title) chat thread."
          : "Generate the brief in the current AI chat thread.")

        NodeBriefOptionsButton()

        Text("Generated briefs live in views/node-briefs and work with any AI runtime.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeBriefRenderedPreview: View {
  let artifact: NodeBriefArtifact
  let corpusRoot: URL?
  @State private var preparation: NodeBriefPreviewPreparation?

  private var revision: NodeBriefPreviewRevision {
    NodeBriefPreviewRevision(artifact)
  }

  var body: some View {
    if artifact.body.isEmpty {
      Text("Brief artifact is present but has no body after metadata.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if preparation?.revision != revision {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing brief preview…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task(id: revision) {
        let prepared = await NodeBriefPreviewBuilder.prepare(
          body: artifact.body,
          revision: revision
        )
        guard !Task.isCancelled, prepared.revision == revision else { return }
        preparation = prepared
      }
    } else if preparation?.blocks.isEmpty != false {
      OrgInlineText(artifact.body, font: .callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      LazyVStack(alignment: .leading, spacing: 5) {
        ForEach(preparation?.blocks ?? []) { block in
          NodeBriefCompactBlockView(
            block: block,
            sourceFile: artifact.file,
            corpusRoot: corpusRoot
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct NodeBriefPreviewRevision: Hashable, Sendable {
  let relativePath: String
  let modifiedAt: Date?
  let utf8Count: Int

  init(_ artifact: NodeBriefArtifact) {
    relativePath = artifact.relativePath
    modifiedAt = artifact.modifiedAt
    utf8Count = artifact.body.utf8.count
  }
}

struct NodeBriefPreviewPreparation: Sendable {
  let revision: NodeBriefPreviewRevision
  let blocks: [OrgEditableBlock]
}

enum NodeBriefPreviewBuilder {
  nonisolated static func prepare(
    body: String,
    revision: NodeBriefPreviewRevision,
    workThreadObserver: (@Sendable (Bool) -> Void)? = nil
  ) async -> NodeBriefPreviewPreparation {
    await Task.detached(priority: .userInitiated) {
      workThreadObserver?(currentThreadIsMainThread())
      let blocks = OrgEntryRenderer
        .parseEditable(body)
        .filter(OrgRenderedBlockDisplayPolicy.isVisible)
      return NodeBriefPreviewPreparation(revision: revision, blocks: blocks)
    }.value
  }


  private nonisolated static func currentThreadIsMainThread() -> Bool {
    Thread.isMainThread
  }
}

private struct NodeBriefCompactBlockView: View {
  let block: OrgEditableBlock
  let sourceFile: String
  let corpusRoot: URL?

  var body: some View {
    switch block.rendered {
    case .heading(let heading):
      Text(Org2Display.cleanInline(heading.title))
        .font(headingFont(level: heading.level))
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, heading.level <= 1 ? 8 : 5)
    case .paragraph(let text):
      compactInlineText(block.rawText.isEmpty ? text : block.rawText)
        .font(.callout)
        .padding(.vertical, 1)
    case .listItem(let indent, let marker, let checkbox, let text):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(listMarker(marker: marker, checkbox: checkbox))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 20, alignment: .trailing)
        compactInlineText(text)
          .font(.callout)
      }
      .padding(.leading, CGFloat(max(0, indent)) * 12)
      .padding(.vertical, 2)
    case .quote(let lines):
      compactInlineText(lines.joined(separator: "\n"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 2)
        }
        .padding(.vertical, 4)
    case .planning(let planning):
      HStack(spacing: 6) {
        Text(planning.kind.capitalized)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(planning.value)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 1)
    case .keyword(let key, let value):
      if key.uppercased() != "TITLE" {
        HStack(spacing: 6) {
          Text(key.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
          Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    case .properties:
      EmptyView()
    case .horizontalRule:
      Divider()
        .padding(.vertical, 8)
    case .blank:
      Spacer()
        .frame(height: 3)
    case .source, .table:
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: nil,
        sourceFile: sourceFile,
        corpusRoot: corpusRoot,
        inlineActions: .readOnly
      )
      .font(.callout)
      .padding(.vertical, 4)
    }
  }

  private func compactInlineText(_ raw: String) -> some View {
    OrgInlineText(raw, font: .callout)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case ...1:
      return .headline
    case 2:
      return .callout
    default:
      return .caption.weight(.semibold)
    }
  }

  private func listMarker(marker: String, checkbox: OrgListCheckbox?) -> String {
    if let checkbox {
      return checkbox.rawMarker
    }
    if marker.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil {
      return marker
    }
    return "-"
  }
}

private struct NodeContextStats: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    HStack(spacing: 8) {
      StatTile(label: "Files", value: "\(store.backlinkFileCount)")
      StatTile(label: "Refs", value: "\(store.backlinkReferenceCount)")
      StatTile(label: "Related", value: "\(relatedCount)")
    }
  }

  private var relatedCount: Int {
    store.relatedBacklinkNodes.count
  }
}

private struct StatTile: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.headline.monospacedDigit())
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
  }
}

private struct CountPill: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(WorkspaceDesign.controlFill, in: Capsule())
  }
}

private struct NodeContextEmptyText: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Text(emptyText)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyText: String {
    if store.isLoadingBacklinks { return "Loading backlinks..." }
    if store.backlinks == nil { return "No ID is available for this selection yet." }
    return "No backlinks found for this node."
  }
}

private struct BacklinkFileGroupRow: View {
  @Environment(WorkspaceStore.self) private var store
  let group: BacklinkFileGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        store.toggleBacklinkFileGroup(group)
      } label: {
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 3) {
            Text(group.displayTitle)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          CountPill(count: group.count)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, WorkspaceDesign.rowVerticalPadding)

      if isExpanded {
        ForEach(group.backlinks) { backlink in
          BacklinkRow(backlink: backlink, compact: true)
            .contentShape(Rectangle())
            .onTapGesture {
              store.selectBacklink(backlink)
            }
            .contextMenu {
              WorkspaceLocationContextMenu(
                location: .backlink(backlink),
                select: { store.selectBacklink(backlink) }
              ) {
                Label("Open", systemImage: "link")
              }
            }
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset * 2)
        }
      } else if let first = group.backlinks.first {
        Text(Org2Display.cleanInline(first.context))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .padding(.horizontal, WorkspaceDesign.contentInset + 22)
          .padding(.bottom, 8)
      }
    }
  }

  private var isExpanded: Bool {
    store.expandedBacklinkFileIDs.contains(group.id)
  }
}

private struct BacklinkRow: View {
  @Environment(WorkspaceStore.self) private var store
  let backlink: BacklinkItem
  var compact = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "link")
      VStack(alignment: .leading, spacing: 5) {
        Text(Org2Display.cleanInline(backlink.srcTitle))
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(Org2Display.cleanInline(backlink.context))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(store.relativePath(backlink.file) + ":\(backlink.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, compact ? WorkspaceDesign.contentInset + 22 : WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

struct HeaderBar<Trailing: View>: View {
  let title: String
  let subtitle: String
  let surface: WorkspaceSurface?
  @ViewBuilder let trailing: Trailing

  init(
    title: String,
    subtitle: String,
    surface: WorkspaceSurface? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.surface = surface
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      headerContent(compact: false)
      headerContent(compact: true)
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .background(WorkspaceDesign.surfaceBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)
    }
  }

  private func headerContent(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: compact ? 8 : 12) {
      HStack(spacing: 9) {
        if let surface {
          WorkspaceAsteriskMarker(
            color: surface == .approvals ? WorkspaceDesign.signalAccent : WorkspaceDesign.structuralAccent,
            size: 11
          )
          .frame(width: 16, height: 24)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .layoutPriority(1)
          if !compact {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .frame(minWidth: compact ? 56 : 92, alignment: .leading)

      Spacer(minLength: compact ? 4 : 0)

      if compact {
        trailing
          .labelStyle(.iconOnly)
          .environment(\.workspaceHeaderIsCompact, true)
      } else {
        trailing
          .labelStyle(.titleAndIcon)
      }

    }
    .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)
  }
}

struct DetailPaneControlGroup: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.toggleDetailPaneExpansion()
      } label: {
        Label(
          store.isWorkspaceSurfacePaneClosed ? "Restore Document" : "Expand Document",
          systemImage: store.isWorkspaceSurfacePaneClosed
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
      }
      .labelStyle(.iconOnly)
      .help(store.isWorkspaceSurfacePaneClosed ? "Restore document pane" : "Expand document pane")

      Button {
        store.closeDetailPane()
      } label: {
        Label("Close Document", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .help("Close document pane")
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }
}

struct StatusPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(statusForeground)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .frame(minWidth: 38)
      .background(statusColor, in: Capsule())
  }

  private var statusColor: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": WorkspaceDesign.themed(.todo, opacity: 0.13)
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo.opacity(0.14)
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange.opacity(0.14)
    case "DONE", "COMPLETED": WorkspaceDesign.themed(.done, opacity: 0.14)
    case "FAILED": .red.opacity(0.13)
    case "CANCELLED", "CANCELED": Color.secondary.opacity(0.11)
    default: WorkspaceDesign.subtleFill
    }
  }

  private var statusForeground: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": WorkspaceDesign.themed(.todo)
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange
    case "DONE", "COMPLETED": WorkspaceDesign.themed(.done)
    case "FAILED": .red
    case "CANCELLED", "CANCELED": .secondary
    default: .secondary
    }
  }
}

struct EmptyStateView: View {
  let title: String
  let detail: String
  let action: String?
  let perform: (() -> Void)?

  init(
    title: String,
    detail: String,
    action: String? = nil,
    perform: (() -> Void)? = nil
  ) {
    self.title = title
    self.detail = detail
    self.action = action
    self.perform = perform
  }

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      WorkspaceIconBadge(systemImage: emptyStateIcon, tint: .secondary, fill: WorkspaceDesign.subtleFill)
        .scaleEffect(1.25)
      Text(title)
        .font(.headline)
      if !detail.isEmpty {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, 24)
      }
      if let action, let perform {
        Button(action) {
          perform()
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateIcon: String {
    if title.localizedCaseInsensitiveContains("agenda") { return "calendar" }
    if title.localizedCaseInsensitiveContains("meeting") { return "waveform.and.mic" }
    if title.localizedCaseInsensitiveContains("result") { return "magnifyingglass" }
    if title.localizedCaseInsensitiveContains("agent") { return "tray" }
    if title.localizedCaseInsensitiveContains("selection") { return "cursorarrow" }
    return "doc.text"
  }
}

enum CommandShortcutReveal {
  static func isActive(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
  }
}

private struct CommandShortcutRevealMonitor: ViewModifier {
  @Binding var isCommandPressed: Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        let commandPressed = $isCommandPressed
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
          commandPressed.wrappedValue = CommandShortcutReveal.isActive(for: event.modifierFlags)
          return event
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        isCommandPressed = false
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCommandPressed = false
      }
  }
}

private struct KeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
            event,
            sourceEditorActive: Self.isSourceEditorActive
          ) {
            return event
          }
          let scope = WorkspaceKeyboardEventRouting.scope(
            for: event,
            textInputActive: Self.isTextInputActive
          )
          guard let scope else {
            return event
          }
          return handler(event, scope) ? nil : event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }

  private static var isTextInputActive: Bool {
    guard let responder = NSApplication.shared.keyWindow?.firstResponder else {
      return false
    }
    return responder is NSTextView || responder is NSTextField
  }

  private static var isSourceEditorActive: Bool {
    NSApplication.shared.keyWindow?.firstResponder is OrgSyntaxTextView
  }
}

enum WorkspaceKeyboardEventRouting {
  static func defersToNativeSourceEditor(_ event: NSEvent, sourceEditorActive: Bool) -> Bool {
    guard sourceEditorActive else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    // Let the focused source editor handle find and link insertion before workspace shortcuts.
    return modifiers == [.command] && (key == "f" || key == "k")
  }

  static func scope(for event: NSEvent, textInputActive: Bool) -> WorkspaceKeyboardShortcutScope? {
    guard textInputActive else { return .all }
    return isCommandShortcut(event) ? .globalOnly : nil
  }

  static func isCommandShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    return modifiers == [.command] || modifiers == [.command, .shift] || modifiers == [.command, .option]
  }
}

extension View {
  func commandShortcutRevealMonitor(_ isCommandPressed: Binding<Bool>) -> some View {
    modifier(CommandShortcutRevealMonitor(isCommandPressed: isCommandPressed))
  }

  func keyboardEventMonitor(_ handler: @escaping (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool) -> some View {
    modifier(KeyboardEventMonitor(handler: handler))
  }
}
