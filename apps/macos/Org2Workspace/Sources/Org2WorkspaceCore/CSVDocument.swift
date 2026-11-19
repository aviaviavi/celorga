import AppKit
import Observation
import SwiftUI

enum CSVDocumentError: LocalizedError, Equatable {
  case unterminatedQuotedField

  var errorDescription: String? {
    switch self {
    case .unterminatedQuotedField:
      return "A quoted field is missing its closing quote."
    }
  }
}

struct CSVDocument: Equatable, Sendable {
  private(set) var rows: [[String]]
  var hasTrailingNewline: Bool
  private var recordEnding = "\n"
  private var cachedColumnCount: Int

  init(rows: [[String]] = [], hasTrailingNewline: Bool = false) {
    self.rows = rows
    self.hasTrailingNewline = hasTrailingNewline
    cachedColumnCount = rows.lazy.map(\.count).max() ?? 0
  }

  init(parsing text: String) throws {
    guard !text.isEmpty else {
      self.init()
      return
    }

    var recordEnding: String?
    var parsedRows: [[String]] = []
    var row: [String] = []
    var field = ""
    var isInsideQuotes = false
    var justEndedRow = false
    var index = text.startIndex

    func finishField() {
      row.append(field)
      field = ""
    }

    func finishRow() {
      finishField()
      parsedRows.append(row)
      row = []
      justEndedRow = true
    }

    while index < text.endIndex {
      let character = text[index]
      let nextIndex = text.index(after: index)

      if character == "\"" {
        if isInsideQuotes {
          if nextIndex < text.endIndex, text[nextIndex] == "\"" {
            field.append("\"")
            index = text.index(after: nextIndex)
            justEndedRow = false
            continue
          }
          isInsideQuotes = false
        } else if field.isEmpty {
          isInsideQuotes = true
        } else {
          field.append(character)
        }
        justEndedRow = false
        index = nextIndex
        continue
      }

      if !isInsideQuotes {
        if character == "," {
          finishField()
          justEndedRow = false
          index = nextIndex
          continue
        }
        if character == "\n" || character == "\r\n" || character == "\r" {
          if recordEnding == nil { recordEnding = String(character) }
          finishRow()
          index = nextIndex
          continue
        }
      }

      field.append(character)
      justEndedRow = false
      index = nextIndex
    }

    guard !isInsideQuotes else {
      throw CSVDocumentError.unterminatedQuotedField
    }

    if !justEndedRow {
      finishField()
      parsedRows.append(row)
    }

    self.init(rows: parsedRows, hasTrailingNewline: justEndedRow)
    self.recordEnding = recordEnding ?? "\n"
  }

  var rowCount: Int {
    rows.count
  }

  var columnCount: Int {
    cachedColumnCount
  }

  func value(row: Int, column: Int) -> String {
    guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
    return rows[row][column]
  }

  mutating func setValue(_ value: String, row: Int, column: Int) {
    guard row >= 0, column >= 0 else { return }
    while rows.count <= row {
      rows.append(Array(repeating: "", count: max(1, columnCount)))
    }
    while rows[row].count <= column {
      rows[row].append("")
    }
    rows[row][column] = value
    cachedColumnCount = max(cachedColumnCount, rows[row].count)
  }

  mutating func appendRow() {
    rows.append(Array(repeating: "", count: max(1, columnCount)))
    cachedColumnCount = max(1, cachedColumnCount)
  }

  mutating func appendColumn() {
    if rows.isEmpty {
      rows = [[""]]
      cachedColumnCount = 1
      return
    }
    let existingColumnCount = columnCount
    for index in rows.indices {
      while rows[index].count < existingColumnCount {
        rows[index].append("")
      }
      rows[index].append("")
    }
    cachedColumnCount = existingColumnCount + 1
  }

  mutating func removeRow(at index: Int) {
    guard rows.indices.contains(index) else { return }
    let removedWidestRow = rows[index].count == cachedColumnCount
    rows.remove(at: index)
    if removedWidestRow {
      cachedColumnCount = rows.lazy.map(\.count).max() ?? 0
    }
  }

  mutating func removeColumn(at index: Int) {
    guard index >= 0 else { return }
    for rowIndex in rows.indices where rows[rowIndex].indices.contains(index) {
      rows[rowIndex].remove(at: index)
    }
    if index < cachedColumnCount {
      cachedColumnCount = max(0, cachedColumnCount - 1)
    }
  }

  func serialized() -> String {
    var text = rows
      .map { row in row.map(Self.serializeField).joined(separator: ",") }
      .joined(separator: recordEnding)
    if hasTrailingNewline, !rows.isEmpty {
      text.append(recordEnding)
    }
    return text
  }

  private static func serializeField(_ field: String) -> String {
    guard field.contains(",")
            || field.contains("\"")
            || field.contains("\r\n")
            || field.contains("\n")
            || field.contains("\r")
    else {
      return field
    }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}

enum CSVEditorPresentation: String, CaseIterable, Identifiable {
  case table
  case raw

  var id: String { rawValue }

  var title: String {
    switch self {
    case .table: "Table"
    case .raw: "Raw"
    }
  }
}

enum CSVDocumentParseOutcome: Equatable, Sendable {
  case success(CSVDocument)
  case failure(CSVDocumentError)
}

private struct CSVEntrySourceRevision: Hashable {
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let isSubtree: Bool
  let isEditable: Bool

  init(_ source: EntrySource) {
    file = source.file
    startLine = source.startLine
    endLineExclusive = source.endLineExclusive
    isSubtree = source.isSubtree
    isEditable = source.isEditable
  }
}

enum CSVDocumentBackgroundParser {
  nonisolated static func parse(_ text: String) async -> CSVDocumentParseOutcome {
    await Task.detached(priority: .userInitiated) {
      do {
        return .success(try CSVDocument(parsing: text))
      } catch let error as CSVDocumentError {
        return .failure(error)
      } catch {
        assertionFailure("CSVDocument produced an unexpected parsing error: \(error)")
        return .failure(.unterminatedQuotedField)
      }
    }.value
  }
}

struct CSVTableCellCoordinate: Hashable, Sendable {
  let row: Int
  let column: Int
}

struct CSVTablePublication: Sendable {
  let document: CSVDocument
  let text: String
}

enum CSVTableMutation: Sendable {
  case appendRow
  case appendColumn
  case removeRow(Int)
  case removeColumn(Int)

  func apply(to document: inout CSVDocument) {
    switch self {
    case .appendRow: document.appendRow()
    case .appendColumn: document.appendColumn()
    case .removeRow(let index): document.removeRow(at: index)
    case .removeColumn(let index): document.removeColumn(at: index)
    }
  }
}

enum CSVDocumentBackgroundSerializer {
  nonisolated static func applying(
    _ edits: [CSVTableCellCoordinate: String],
    to document: CSVDocument
  ) async -> CSVTablePublication {
    await Task.detached(priority: .userInitiated) {
      var updated = document
      for (coordinate, value) in edits {
        updated.setValue(value, row: coordinate.row, column: coordinate.column)
      }
      return CSVTablePublication(document: updated, text: updated.serialized())
    }.value
  }
}

@MainActor
@Observable
final class CSVDocumentEditorModel {
  typealias Parser = @Sendable (String) async -> CSVDocumentParseOutcome
  typealias TableSerializer = @Sendable (
    [CSVTableCellCoordinate: String],
    CSVDocument
  ) async -> CSVTablePublication
  typealias TablePublisher = @MainActor @Sendable (
    _ text: String,
    _ expectedText: String
  ) async -> Bool

  private enum TablePublicationOutcome: Equatable {
    case published
    case superseded
    case failed
  }

  var document = CSVDocument()
  var rawText: String
  var presentation: CSVEditorPresentation = .table
  var parseError: String?
  private(set) var isParsing = true
  private(set) var textRevision: UInt64 = 0
  private(set) var pendingTableCellValues: [CSVTableCellCoordinate: String] = [:]

  @ObservationIgnored private let parser: Parser
  @ObservationIgnored private let tableSerializer: TableSerializer
  @ObservationIgnored private let tablePublicationDelayNanoseconds: UInt64
  @ObservationIgnored private var parseTask: Task<Void, Never>?
  @ObservationIgnored private var tablePublicationTask: Task<TablePublicationOutcome, Never>?
  @ObservationIgnored private var tableEditRevision: UInt64 = 0
  @ObservationIgnored private var publishedTableEditRevision: UInt64 = 0
  @ObservationIgnored private var tablePublicationToken: UInt64 = 0
  @ObservationIgnored private var tableContentGeneration: UInt64 = 0
  @ObservationIgnored private var tablePublicationIsPersisting = false
  @ObservationIgnored private var tablePublicationNeedsImmediateDrain = false
  @ObservationIgnored private var latestTablePublisher: TablePublisher?
  @ObservationIgnored private var startedInitialParse = false
  @ObservationIgnored private var sourceRevision: CSVEntrySourceRevision?

  init(
    rawText: String,
    parser: @escaping Parser = CSVDocumentBackgroundParser.parse,
    tablePublicationDelayNanoseconds: UInt64 = 180_000_000,
    tableSerializer: @escaping TableSerializer = CSVDocumentBackgroundSerializer.applying
  ) {
    self.rawText = rawText
    self.parser = parser
    self.tablePublicationDelayNanoseconds = tablePublicationDelayNanoseconds
    self.tableSerializer = tableSerializer
  }

  func startInitialParse() {
    guard !startedInitialParse else { return }
    startedInitialParse = true
    requestParse(selectTableOnSuccess: true)
  }

  fileprivate func loadSource(_ text: String, revision: CSVEntrySourceRevision) {
    if !startedInitialParse {
      startedInitialParse = true
      sourceRevision = revision
      rawText = text
      requestParse(selectTableOnSuccess: true)
      return
    }
    guard sourceRevision != revision else { return }

    discardPendingTableEdits()
    sourceRevision = revision
    rawText = text
    document = CSVDocument()
    parseError = nil
    presentation = .table
    requestParse(selectTableOnSuccess: true)
  }

  func replaceTextFromExternalSource(_ text: String) {
    discardPendingTableEdits()
    let selectTableOnSuccess = presentation == .table
    rawText = text
    requestParse(selectTableOnSuccess: selectTableOnSuccess)
  }

  func noteRawTextChanged(_ text: String) {
    discardPendingTableEdits()
    rawText = text
    invalidatePendingParseForLocalEdit()
  }

  @discardableResult
  func selectRawPresentation(publish: @escaping TablePublisher) async -> Bool {
    guard await flushPendingTableEdits(publish: publish) else { return false }
    presentation = .raw
    guard isParsing else { return true }
    invalidatePendingParseForLocalEdit()
    return true
  }

  func selectTablePresentation() {
    requestParse(selectTableOnSuccess: true)
  }

  func cancelParsing() {
    parseTask?.cancel()
    parseTask = nil
    textRevision &+= 1
    isParsing = false
  }

  func tableValue(row: Int, column: Int) -> String {
    pendingTableCellValues[CSVTableCellCoordinate(row: row, column: column)]
      ?? document.value(row: row, column: column)
  }

  func noteTableCellChanged(
    _ value: String,
    row: Int,
    column: Int,
    publish: @escaping TablePublisher
  ) {
    let coordinate = CSVTableCellCoordinate(row: row, column: column)
    guard tableValue(row: row, column: column) != value else { return }
    pendingTableCellValues[coordinate] = value
    textRevision &+= 1
    tableEditRevision &+= 1
    // Assigning an observed property notifies even when the value is
    // unchanged; that would re-evaluate the editor on every keystroke.
    if parseError != nil { parseError = nil }
    requestTablePublication(after: tablePublicationDelayNanoseconds, publish: publish)
  }

  @discardableResult
  func applyTableMutation(
    _ mutation: CSVTableMutation,
    publish: @escaping TablePublisher
  ) async -> Bool {
    guard await flushPendingTableEdits(publish: publish) else { return false }
    var updated = document
    mutation.apply(to: &updated)
    document = updated
    textRevision &+= 1
    tableEditRevision &+= 1
    requestTablePublication(after: 0, publish: publish)
    return await flushPendingTableEdits(publish: publish)
  }

  @discardableResult
  func flushPendingTableEdits(publish: @escaping TablePublisher) async -> Bool {
    latestTablePublisher = publish
    tablePublicationNeedsImmediateDrain = true
    defer { tablePublicationNeedsImmediateDrain = false }

    while hasUnpublishedTableChanges || tablePublicationTask != nil {
      if hasUnpublishedTableChanges, !tablePublicationIsPersisting {
        requestTablePublication(after: 0, publish: publish)
      }
      guard let task = tablePublicationTask else { return false }
      if await task.value == .failed {
        return false
      }
    }
    return true
  }

  private func requestParse(selectTableOnSuccess: Bool) {
    parseTask?.cancel()
    textRevision &+= 1
    let requestedRevision = textRevision
    let requestedText = rawText
    let parser = parser
    isParsing = true
    if selectTableOnSuccess {
      presentation = .table
    }

    parseTask = Task { @MainActor [weak self] in
      let outcome = await parser(requestedText)
      guard !Task.isCancelled,
            let self,
            self.textRevision == requestedRevision
      else {
        return
      }

      self.parseTask = nil
      self.isParsing = false
      switch outcome {
      case .success(let parsed):
        self.pendingTableCellValues.removeAll(keepingCapacity: true)
        self.document = parsed
        self.parseError = nil
        if selectTableOnSuccess {
          self.presentation = .table
        }
      case .failure(let error):
        self.parseError = error.localizedDescription
        self.presentation = .raw
      }
    }
  }

  private func invalidatePendingParseForLocalEdit() {
    let wasParsing = isParsing
    parseTask?.cancel()
    parseTask = nil
    textRevision &+= 1
    isParsing = false
    if wasParsing, presentation == .table {
      presentation = .raw
    }
  }

  private func requestTablePublication(
    after delayNanoseconds: UInt64,
    publish: @escaping TablePublisher
  ) {
    latestTablePublisher = publish
    guard hasUnpublishedTableChanges else { return }
    // A publication that has entered WorkspaceStore owns its expected-text
    // baseline. Let it finish before serializing a newer edit against the
    // resulting text; cancelling here could reorder the two durable writes.
    guard !tablePublicationIsPersisting else { return }

    tablePublicationTask?.cancel()
    tablePublicationToken &+= 1
    let requestedToken = tablePublicationToken
    let serializer = tableSerializer
    // The debounce only schedules work. The document copy and full CSV
    // serialization both happen in the injected background serializer.
    tablePublicationTask = Task { @MainActor [self] in
      if delayNanoseconds > 0 {
        do {
          try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
          return .superseded
        }
      }
      guard !Task.isCancelled, requestedToken == tablePublicationToken else {
        return .superseded
      }

      let requestedRevision = tableEditRevision
      let requestedContentGeneration = tableContentGeneration
      let baseDocument = document
      let edits = pendingTableCellValues
      let expectedText = rawText
      let publication = await serializer(edits, baseDocument)
      guard !Task.isCancelled,
            requestedToken == tablePublicationToken,
            requestedRevision == tableEditRevision
      else {
        return .superseded
      }

      tablePublicationIsPersisting = true
      let persisted = await publish(publication.text, expectedText)
      tablePublicationIsPersisting = false
      guard requestedToken == tablePublicationToken else {
        return .superseded
      }
      tablePublicationTask = nil

      guard persisted else { return .failed }
      if requestedContentGeneration == tableContentGeneration {
        document = publication.document
        for (coordinate, value) in edits
        where pendingTableCellValues[coordinate] == value {
          pendingTableCellValues.removeValue(forKey: coordinate)
        }
        rawText = publication.text
        publishedTableEditRevision = requestedRevision
        parseError = nil
      }

      if hasUnpublishedTableChanges, let latestTablePublisher {
        requestTablePublication(
          after: tablePublicationNeedsImmediateDrain ? 0 : tablePublicationDelayNanoseconds,
          publish: latestTablePublisher
        )
      }
      return .published
    }
  }

  private func discardPendingTableEdits() {
    guard hasUnpublishedTableChanges || tablePublicationTask != nil else { return }
    tableContentGeneration &+= 1
    tableEditRevision &+= 1
    publishedTableEditRevision = tableEditRevision
    pendingTableCellValues.removeAll(keepingCapacity: true)
    // Once persistence starts it must remain awaited even when a reload or raw
    // edit invalidates its result for this model. The source-bound publisher
    // still finishes safely; its stale result is not installed back here.
    guard !tablePublicationIsPersisting else { return }
    tablePublicationTask?.cancel()
    tablePublicationTask = nil
    tablePublicationToken &+= 1
  }

  private var hasUnpublishedTableChanges: Bool {
    tableEditRevision != publishedTableEditRevision
  }
}

/// Lifecycle bridge for debounced table editors. A weak registry lets app
/// termination await serialization and source-bound publication without
/// forcing table typing through WorkspaceStore on every keystroke.
@MainActor
enum CSVDocumentEditorLifecycle {
  private final class Registration {
    weak var model: CSVDocumentEditorModel?
    var publish: CSVDocumentEditorModel.TablePublisher

    init(
      model: CSVDocumentEditorModel,
      publish: @escaping CSVDocumentEditorModel.TablePublisher
    ) {
      self.model = model
      self.publish = publish
    }
  }

  private static var registrations: [ObjectIdentifier: Registration] = [:]

  static func register(
    _ model: CSVDocumentEditorModel,
    publish: @escaping CSVDocumentEditorModel.TablePublisher
  ) {
    pruneRegistrations()
    registrations[ObjectIdentifier(model)] = Registration(model: model, publish: publish)
  }

  static func unregister(_ model: CSVDocumentEditorModel) {
    registrations.removeValue(forKey: ObjectIdentifier(model))
  }

  static func checkpointPendingTableEdits() async -> Bool {
    pruneRegistrations()
    var succeeded = true
    for registration in Array(registrations.values) {
      guard let model = registration.model else { continue }
      if !(await model.flushPendingTableEdits(publish: registration.publish)) {
        succeeded = false
      }
    }
    pruneRegistrations()
    return succeeded
  }

  private static func pruneRegistrations() {
    registrations = registrations.filter { $0.value.model != nil }
  }
}

struct CSVDocumentEditorView: View {
  @Environment(WorkspaceStore.self) private var store
  let source: EntrySource

  @State private var model: CSVDocumentEditorModel

  init(source: EntrySource) {
    self.source = source
    _model = State(initialValue: CSVDocumentEditorModel(rawText: source.text))
  }

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      toolbar
      Divider()

      if let parseError = model.parseError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(parseError)
            .font(.callout)
          Spacer()
          Button("Try Table Again") {
            switchToTable()
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        Divider()
      }

      if model.presentation == .table, !model.isParsing {
        CSVTableEditor(
          document: model.document,
          value: model.tableValue,
          setValue: { value, row, column in
            model.noteTableCellChanged(
              value,
              row: row,
              column: column,
              publish: publishTableText
            )
          },
          mutate: { mutation in
            Task { @MainActor in
              await model.applyTableMutation(mutation, publish: publishTableText)
            }
          }
        )
      } else {
        OrgSyntaxTextEditor(
          text: rawTextBinding,
          monospaced: true,
          showsScrollers: true,
          textInset: NSSize(width: 14, height: 14),
          focusOnAppear: false,
          // Keep a large CSV draft local to NSTextView during a typing burst.
          // Publishing every key through WorkspaceStore invalidates the whole
          // workspace hierarchy and is especially visible in raw-file mode.
          textPublishing: .deferred(milliseconds: 250),
          liveHighlighting: false,
          incrementalHighlighting: false,
          concealsSyntax: false,
          orgWritingCommands: false,
          textChecking: .disabled,
          onLocalTextChange: { text in
            model.noteRawTextChanged(text)
            store.noteLiveFileEditorTextChanged(text)
          },
          documentIdentity: source.id,
          onCheckpointText: { text in
            store.persistSourceEditorCheckpoint(text, source: source, kind: "live-file")
          },
          documentGeneration: { model.textRevision },
          bindingGeneration: { model.textRevision },
          onTextPublicationConflict: { text in
            store.preserveSourceEditorDraftAfterPublicationConflict(text, source: source)
          },
          onSaveCommand: { context in
            model.noteRawTextChanged(context.text)
            store.noteLiveFileEditorTextChanged(context.text)
            Task { await store.saveLiveFileEditor(explicit: true) }
            return true
          }
        )
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
    .onAppear {
      CSVDocumentEditorLifecycle.register(model, publish: publishTableText)
    }
    .task(id: CSVEntrySourceRevision(source)) {
      CSVDocumentEditorLifecycle.register(model, publish: publishTableText)
      model.loadSource(source.text, revision: CSVEntrySourceRevision(source))
    }
    .onChange(of: store.isLoadingEntrySource) { _, isLoading in
      guard !isLoading,
            let latestSource = store.selectedEntrySource,
            latestSource.file == source.file
      else {
        return
      }
      // Same-file reloads can keep the same range, so the lightweight source
      // revision above intentionally is not the only synchronization signal.
      // WorkspaceStore preserves an unsaved draft in editableEntryText.
      model.replaceTextFromExternalSource(store.editableEntryText)
    }
    .onChange(of: store.liveFileEditorStatusText) { _, status in
      if status == "Reverted"
          || status == "Saved by AI"
          || status.hasPrefix("Undid")
          || status.hasPrefix("Redid") {
        model.replaceTextFromExternalSource(store.editableEntryText)
      }
    }
    .onDisappear {
      model.cancelParsing()
      Task { @MainActor in
        _ = await model.flushPendingTableEdits(publish: publishTableText)
        CSVDocumentEditorLifecycle.unregister(model)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker("CSV View", selection: presentationBinding) {
        ForEach(CSVEditorPresentation.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      if model.isParsing {
        ProgressView()
          .controlSize(.small)
        Text("Parsing CSV…")
          .font(.caption)
          .foregroundStyle(WorkspaceDesign.secondaryText)
      } else {
        Text("\(model.document.rowCount) rows · \(model.document.columnCount) columns")
          .font(.caption.monospacedDigit())
          .foregroundStyle(WorkspaceDesign.secondaryText)
      }

      Spacer()

      if model.presentation == .table, !model.isParsing {
        Button {
          Task { @MainActor in
            await model.applyTableMutation(.appendRow, publish: publishTableText)
          }
        } label: {
          Label("Add Row", systemImage: "plus")
        }
        .help("Add row")

        Button {
          Task { @MainActor in
            await model.applyTableMutation(.appendColumn, publish: publishTableText)
          }
        } label: {
          Label("Add Column", systemImage: "rectangle.split.3x1")
        }
        .help("Add column")
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var presentationBinding: Binding<CSVEditorPresentation> {
    Binding(
      get: { model.presentation },
      set: { next in
        if next == .table {
          switchToTable()
        } else {
          Task { @MainActor in
            await model.selectRawPresentation(publish: publishTableText)
          }
        }
      }
    )
  }

  private var rawTextBinding: Binding<String> {
    Binding(
      get: { model.rawText },
      set: { text in
        model.noteRawTextChanged(text)
        store.noteLiveFileEditorTextChanged(text)
      }
    )
  }

  private func switchToTable() {
    model.selectTablePresentation()
  }

  @MainActor
  private func publishTableText(_ text: String, expectedText: String) async -> Bool {
    await store.persistDeferredLiveFileEditorText(
      text,
      expectedText: expectedText,
      source: source
    )
  }
}

/// Spreadsheet grid for CSV files. The grid draws only the cells inside the
/// visible rect and edits through one overlay text field, so a wide file costs
/// the same as a narrow one. (A SwiftUI grid built every column of each
/// visible row as a TextField and re-evaluated them all on every keystroke;
/// view-based NSTableView also realizes every column of a visible row.)
struct CSVTableEditor: NSViewRepresentable {
  let document: CSVDocument
  let value: (Int, Int) -> String
  let setValue: (String, Int, Int) -> Void
  let mutate: (CSVTableMutation) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let grid = CSVGridView()
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = WorkspaceDesign.documentNSColor
    scrollView.documentView = grid
    context.coordinator.grid = grid
    grid.observeScrolling(in: scrollView.contentView)
    configure(grid, documentChanged: true)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let grid = context.coordinator.grid else { return }
    configure(grid, documentChanged: grid.document != document)
  }

  private func configure(_ grid: CSVGridView, documentChanged: Bool) {
    grid.value = value
    grid.setValue = setValue
    grid.mutate = mutate
    if documentChanged {
      grid.document = document
    }
  }

  static func columnName(_ index: Int) -> String {
    var number = index + 1
    var name = ""
    while number > 0 {
      number -= 1
      name.insert(Character(UnicodeScalar(65 + (number % 26))!), at: name.startIndex)
      number /= 26
    }
    return name
  }

  @MainActor
  final class Coordinator {
    weak var grid: CSVGridView?
  }
}

struct CSVGridCell: Hashable, Sendable {
  let row: Int
  let column: Int
}

@MainActor
final class CSVGridView: NSView, NSTextFieldDelegate {
  static let rowNumberWidth: CGFloat = 48
  static let cellWidth: CGFloat = 180
  static let rowHeight: CGFloat = 34
  private static let cellInset: CGFloat = 9

  var value: (Int, Int) -> String = { _, _ in "" }
  var setValue: (String, Int, Int) -> Void = { _, _, _ in }
  var mutate: (CSVTableMutation) -> Void = { _ in }

  /// Installing an equal or same-shape document only redraws. The active
  /// editor keeps its text and caret, so a debounced publication of what the
  /// user just typed never interrupts typing.
  var document = CSVDocument() {
    didSet {
      if editingCell.map({ $0.row >= rowCount || $0.column >= columnCount }) == true {
        endEditing()
      }
      updateFrameSize()
      needsDisplay = true
    }
  }

  private(set) var editingCell: CSVGridCell?
  private(set) var editorField: NSTextField?

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  // The header row and row-number gutter are pinned to the visible rect, so
  // AppKit must not reuse content drawn outside it while scrolling.
  override class var isCompatibleWithResponsiveScrolling: Bool { false }

  var rowCount: Int { max(1, document.rowCount) }
  var columnCount: Int { max(1, document.columnCount) }

  func observeScrolling(in clipView: NSClipView) {
    clipView.postsBoundsChangedNotifications = true
    // Selector observers are removed automatically when the view deallocates.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
  }

  @objc private func clipViewBoundsDidChange(_ notification: Notification) {
    needsDisplay = true
  }

  private func updateFrameSize() {
    let size = NSSize(
      width: Self.rowNumberWidth + CGFloat(columnCount) * Self.cellWidth,
      height: Self.rowHeight * CGFloat(rowCount + 1)
    )
    if frame.size != size {
      setFrameSize(size)
    }
  }

  func cellRect(row: Int, column: Int) -> NSRect {
    NSRect(
      x: Self.rowNumberWidth + CGFloat(column) * Self.cellWidth,
      y: Self.rowHeight * CGFloat(row + 1),
      width: Self.cellWidth,
      height: Self.rowHeight
    )
  }

  /// Rows and columns that intersect `rect`, clamped to the document.
  func visibleCellRange(in rect: NSRect) -> (rows: Range<Int>, columns: Range<Int>) {
    let firstRow = max(0, Int(floor((rect.minY - Self.rowHeight) / Self.rowHeight)))
    let lastRow = min(rowCount, Int(ceil((rect.maxY - Self.rowHeight) / Self.rowHeight)))
    let firstColumn = max(0, Int(floor((rect.minX - Self.rowNumberWidth) / Self.cellWidth)))
    let lastColumn = min(columnCount, Int(ceil((rect.maxX - Self.rowNumberWidth) / Self.cellWidth)))
    return (firstRow..<max(firstRow, lastRow), firstColumn..<max(firstColumn, lastColumn))
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    let visible = visibleRect
    WorkspaceDesign.documentNSColor.setFill()
    dirtyRect.fill()

    let range = visibleCellRange(in: dirtyRect)
    let text = WorkspaceDesign.stablePrimaryNSColor
    let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let semibold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    let hairline = WorkspaceDesign.hairlineNSColor

    if range.rows.contains(0) {
      WorkspaceDesign.stablePrimaryNSColor.withAlphaComponent(0.045).setFill()
      NSRect(
        x: Self.rowNumberWidth,
        y: Self.rowHeight,
        width: CGFloat(columnCount) * Self.cellWidth,
        height: Self.rowHeight
      ).intersection(dirtyRect).fill()
    }

    for row in range.rows {
      let font = row == 0 ? semibold : regular
      for column in range.columns where CSVGridCell(row: row, column: column) != editingCell {
        let string = value(row, column)
        guard !string.isEmpty else { continue }
        drawText(
          string,
          in: cellRect(row: row, column: column).insetBy(dx: Self.cellInset, dy: 0),
          font: font,
          color: text,
          alignment: .left
        )
      }
    }

    hairline.setFill()
    for row in range.rows {
      NSRect(x: dirtyRect.minX, y: cellRect(row: row, column: 0).maxY - 1, width: dirtyRect.width, height: 1).fill()
    }
    for column in range.columns {
      NSRect(x: cellRect(row: 0, column: column).maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    drawRowNumberGutter(visible: visible, rows: visibleCellRange(in: visible).rows)
    drawColumnHeader(visible: visible, columns: visibleCellRange(in: visible).columns)
  }

  private func drawRowNumberGutter(visible: NSRect, rows: Range<Int>) {
    let gutter = NSRect(x: visible.minX, y: visible.minY, width: Self.rowNumberWidth, height: visible.height)
    WorkspaceDesign.documentNSColor.setFill()
    gutter.fill()
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    for row in rows {
      let rect = NSRect(x: gutter.minX, y: cellRect(row: row, column: 0).minY, width: Self.rowNumberWidth, height: Self.rowHeight)
      drawText(String(row + 1), in: rect.insetBy(dx: 4, dy: 0), font: font, color: WorkspaceDesign.stableTertiaryNSColor, alignment: .center)
      WorkspaceDesign.hairlineNSColor.setFill()
      NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }
    WorkspaceDesign.hairlineNSColor.setFill()
    NSRect(x: gutter.maxX - 1, y: gutter.minY, width: 1, height: gutter.height).fill()
  }

  private func drawColumnHeader(visible: NSRect, columns: Range<Int>) {
    let header = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: Self.rowHeight)
    WorkspaceDesign.documentNSColor.setFill()
    header.fill()
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    for column in columns {
      let cell = cellRect(row: 0, column: column)
      let rect = NSRect(x: cell.minX, y: header.minY, width: cell.width, height: Self.rowHeight)
      drawText(CSVTableEditor.columnName(column), in: rect, font: font, color: WorkspaceDesign.stableSecondaryNSColor, alignment: .center)
      WorkspaceDesign.hairlineNSColor.setFill()
      NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
    // Corner above the gutter.
    WorkspaceDesign.documentNSColor.setFill()
    NSRect(x: visible.minX, y: visible.minY, width: Self.rowNumberWidth, height: Self.rowHeight).fill()
    WorkspaceDesign.hairlineNSColor.setFill()
    NSRect(x: visible.minX + Self.rowNumberWidth - 1, y: header.minY, width: 1, height: header.height).fill()
    NSRect(x: header.minX, y: header.maxY - 1, width: header.width, height: 1).fill()
  }

  private func drawText(
    _ string: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.alignment = alignment
    // Cells are single-line; show the first line of a multi-line field.
    let line = string.firstIndex(where: \.isNewline).map { String(string[..<$0]) + " …" } ?? string
    let attributed = NSAttributedString(string: line, attributes: [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ])
    let height = ceil(font.ascender - font.descender + font.leading)
    attributed.draw(
      with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
    )
  }

  // MARK: Hit testing and menus

  enum HitTarget: Equatable {
    case cell(CSVGridCell)
    case columnHeader(Int)
    case rowNumber(Int)
    case none
  }

  func hitTarget(at point: NSPoint) -> HitTarget {
    let visible = visibleRect
    let column = Int(floor((point.x - Self.rowNumberWidth) / Self.cellWidth))
    let row = Int(floor((point.y - Self.rowHeight) / Self.rowHeight))
    let inHeader = point.y < visible.minY + Self.rowHeight
    let inGutter = point.x < visible.minX + Self.rowNumberWidth
    if inHeader {
      return !inGutter && (0..<columnCount).contains(column) ? .columnHeader(column) : .none
    }
    guard (0..<rowCount).contains(row) else { return .none }
    if inGutter { return .rowNumber(row) }
    guard (0..<columnCount).contains(column) else { return .none }
    return .cell(CSVGridCell(row: row, column: column))
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if case .cell(let cell) = hitTarget(at: point) {
      beginEditing(row: cell.row, column: cell.column, selectAll: false)
    } else {
      endEditing()
      window?.makeFirstResponder(self)
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let menu = NSMenu()
    var row: Int?
    var column: Int?
    switch hitTarget(at: point) {
    case .cell(let cell):
      row = cell.row
      column = cell.column
    case .columnHeader(let index):
      column = index
    case .rowNumber(let index):
      row = index
    case .none:
      return nil
    }
    if let row {
      let item = NSMenuItem(
        title: "Delete Row \(row + 1)",
        action: document.rows.indices.contains(row) ? #selector(deleteRow(_:)) : nil,
        keyEquivalent: ""
      )
      item.target = self
      item.tag = row
      menu.addItem(item)
    }
    if let column {
      let item = NSMenuItem(
        title: "Delete Column \(CSVTableEditor.columnName(column))",
        action: document.columnCount > 0 ? #selector(deleteColumn(_:)) : nil,
        keyEquivalent: ""
      )
      item.target = self
      item.tag = column
      menu.addItem(item)
    }
    return menu
  }

  @objc private func deleteRow(_ sender: NSMenuItem) {
    endEditing()
    mutate(.removeRow(sender.tag))
  }

  @objc private func deleteColumn(_ sender: NSMenuItem) {
    endEditing()
    mutate(.removeColumn(sender.tag))
  }

  // MARK: Editing

  func beginEditing(row: Int, column: Int, selectAll: Bool = true) {
    guard (0..<rowCount).contains(row), (0..<columnCount).contains(column) else { return }
    // A fresh field per cell keeps the previous cell's field editor from
    // carrying text or undo state into the next one.
    endEditing()
    let cell = CSVGridCell(row: row, column: column)
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = true
    field.focusRingType = .exterior
    field.isEditable = true
    field.isSelectable = true
    field.lineBreakMode = .byClipping
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.delegate = self
    addSubview(field)
    editorField = field
    editingCell = cell
    field.backgroundColor = WorkspaceDesign.documentNSColor
    field.textColor = WorkspaceDesign.stablePrimaryNSColor
    field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: row == 0 ? .semibold : .regular)
    field.stringValue = value(row, column)
    field.setAccessibilityLabel("Row \(row + 1), column \(CSVTableEditor.columnName(column))")
    let rect = cellRect(row: row, column: column)
    let height = ceil(field.intrinsicContentSize.height)
    field.frame = NSRect(
      x: rect.minX + Self.cellInset - 2,
      y: rect.midY - height / 2,
      width: rect.width - (Self.cellInset - 2) * 2,
      height: height
    )
    scrollToVisible(rect.insetBy(dx: -Self.rowNumberWidth, dy: -Self.rowHeight))
    setNeedsDisplay(rect)
    window?.makeFirstResponder(field)
    if !selectAll, let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }
  }

  func endEditing() {
    guard let field = editorField else { return }
    let cell = editingCell
    editingCell = nil
    editorField = nil
    let hadFocus = field.currentEditor() != nil
    field.delegate = nil
    field.removeFromSuperview()
    if hadFocus {
      window?.makeFirstResponder(self)
    }
    if let cell {
      setNeedsDisplay(cellRect(row: cell.row, column: cell.column))
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
          field === editorField,
          let cell = editingCell
    else {
      return
    }
    setValue(field.stringValue, cell.row, cell.column)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard (notification.object as? NSTextField) === editorField else { return }
    // Focus moved elsewhere (another pane, the toolbar). Moving between cells
    // detaches the old field's delegate first, so this runs only when editing
    // truly ends.
    DispatchQueue.main.async { [weak self] in
      guard let self, let field = self.editorField, field.currentEditor() == nil else { return }
      self.endEditing()
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard control === editorField, let cell = editingCell else { return false }
    let target: CSVGridCell?
    switch commandSelector {
    case #selector(NSResponder.insertTab(_:)):
      target = cell.column + 1 < columnCount
        ? CSVGridCell(row: cell.row, column: cell.column + 1)
        : (cell.row + 1 < rowCount ? CSVGridCell(row: cell.row + 1, column: 0) : nil)
    case #selector(NSResponder.insertBacktab(_:)):
      target = cell.column > 0
        ? CSVGridCell(row: cell.row, column: cell.column - 1)
        : (cell.row > 0 ? CSVGridCell(row: cell.row - 1, column: columnCount - 1) : nil)
    case #selector(NSResponder.insertNewline(_:)):
      target = cell.row + 1 < rowCount ? CSVGridCell(row: cell.row + 1, column: cell.column) : nil
    case #selector(NSResponder.cancelOperation(_:)):
      target = nil
    default:
      return false
    }
    if let target {
      beginEditing(row: target.row, column: target.column)
    } else {
      endEditing()
    }
    return true
  }

  // MARK: Accessibility

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .grid }
  override func accessibilityLabel() -> String? {
    "CSV table, \(document.rowCount) rows, \(document.columnCount) columns"
  }

  /// Exposes only the visible cells, matching what is drawn.
  override func accessibilityChildren() -> [Any]? {
    let range = visibleCellRange(in: visibleRect)
    var children: [Any] = []
    for row in range.rows {
      for column in range.columns {
        let rect = cellRect(row: row, column: column)
        let element = NSAccessibilityElement.element(
          withRole: .cell,
          frame: window.map { $0.convertToScreen(convert(rect, to: nil)) } ?? rect,
          label: "Row \(row + 1), column \(CSVTableEditor.columnName(column))",
          parent: self
        )
        if let element = element as? NSAccessibilityElement {
          element.setAccessibilityValue(value(row, column))
        }
        children.append(element)
      }
    }
    if let editorField {
      children.append(editorField)
    }
    return children
  }
}
