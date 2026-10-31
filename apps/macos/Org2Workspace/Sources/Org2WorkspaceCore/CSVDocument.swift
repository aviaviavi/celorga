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
    parseError = nil
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

struct CSVTableEditor: View {
  let document: CSVDocument
  let value: (Int, Int) -> String
  let setValue: (String, Int, Int) -> Void
  let mutate: (CSVTableMutation) -> Void

  private let rowNumberWidth: CGFloat = 48
  private let cellWidth: CGFloat = 180
  private let rowHeight: CGFloat = 34

  var body: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          Section {
            ForEach(0..<max(1, document.rowCount), id: \.self) { row in
              dataRow(row)
            }
          } header: {
            columnHeader
          }
        }
        .frame(
          width: max(geometry.size.width, tableContentWidth),
          alignment: .topLeading
        )
      }
      .defaultScrollAnchor(.topLeading)
      .scrollIndicators(.visible, axes: [.horizontal, .vertical])
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private var tableContentWidth: CGFloat {
    rowNumberWidth + CGFloat(max(1, document.columnCount)) * cellWidth
  }

  private var columnHeader: some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: rowNumberWidth, height: rowHeight)
        .background(WorkspaceDesign.barBackground)
        .overlay(alignment: .trailing) {
          Divider()
        }

      ForEach(0..<max(1, document.columnCount), id: \.self) { column in
        Menu {
          Button("Delete Column", role: .destructive) {
            mutate(.removeColumn(column))
          }
          .disabled(document.columnCount == 0)
        } label: {
          Text(Self.columnName(column))
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(WorkspaceDesign.secondaryText)
            .frame(width: cellWidth, height: rowHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: cellWidth, height: rowHeight)
        .background(WorkspaceDesign.barBackground)
        .overlay(alignment: .trailing) {
          Divider()
        }
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func dataRow(_ row: Int) -> some View {
    HStack(spacing: 0) {
      Menu {
        Button("Delete Row", role: .destructive) {
          mutate(.removeRow(row))
        }
        .disabled(!document.rows.indices.contains(row))
      } label: {
        Text("\(row + 1)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(WorkspaceDesign.tertiaryText)
          .frame(width: rowNumberWidth, height: rowHeight)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .trailing) {
        Divider()
      }

      ForEach(0..<max(1, document.columnCount), id: \.self) { column in
        TextField("", text: cellBinding(row: row, column: column))
          .textFieldStyle(.plain)
          .accessibilityLabel("Row \(row + 1), column \(Self.columnName(column))")
          .font(.system(
            size: 12,
            weight: row == 0 ? .semibold : .regular,
            design: .monospaced
          ))
          .padding(.horizontal, 9)
          .frame(width: cellWidth, height: rowHeight)
          .background(row == 0 ? WorkspaceDesign.subtleFill : Color.clear)
          .overlay(alignment: .trailing) {
            Divider()
          }
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  private func cellBinding(row: Int, column: Int) -> Binding<String> {
    Binding(
      get: { value(row, column) },
      set: { value in
        setValue(value, row, column)
      }
    )
  }

  private static func columnName(_ index: Int) -> String {
    var number = index + 1
    var name = ""
    while number > 0 {
      number -= 1
      name.insert(Character(UnicodeScalar(65 + (number % 26))!), at: name.startIndex)
      number /= 26
    }
    return name
  }
}
