import Foundation
import SwiftUI

// People & Companies: the native face of `celorga crm`. All data comes from
// the shared TypeScript runtime as JSON; every write goes through a
// preview-by-default CLI command with --apply.

// MARK: - Payloads

struct CRMTask: Decodable, Identifiable, Hashable, Sendable {
  let key: String
  let title: String
  let todo: String
  let open: Bool
  let priority: String?
  let scheduled: String?
  let deadline: String?
  let closed: String?
  let file: String
  let line: Int
  let via: String?
  var id: String { key }
  var due: String? { [scheduled, deadline].compactMap { $0 }.sorted().first }
}

struct CRMLedgerRef: Decodable, Hashable, Sendable {
  let ledger: String
  let id: String
  let title: String
  let state: String
  let workStatus: String?
  let lastContactAt: String?
  let lastEventAt: String?
  let nextFollowUpAt: String?
  let eventCount: Int
  let file: String
  let match: String
}

struct CRMEntityRef: Decodable, Hashable, Sendable {
  let key: String
  let title: String
}

struct CRMCompanyRef: Decodable, Hashable, Sendable {
  let key: String
  let title: String
  let match: String
}

struct CRMEntity: Decodable, Identifiable, Hashable, Sendable {
  let key: String
  let kind: String
  let source: String
  let noteID: String?
  let title: String
  let aliases: [String]
  let file: String?
  let line: Int?
  let stage: String
  let stageSource: String
  let emails: [String]
  let domains: [String]
  let role: String
  let owner: String
  let company: CRMCompanyRef?
  let people: [CRMEntityRef]
  let ledgerAccounts: [CRMLedgerRef]
  let openTaskCount: Int
  let nextTask: CRMTask?
  let meetingCount: Int
  let mentionCount: Int?
  let lastInteractionAt: String?
  let lastInteractionType: String?
  /// Direct contact: an attended meeting or calendar event, or outreach.
  let lastTouchAt: String?
  let lastTouchType: String?
  /// Someone else brought them up in a meeting or note.
  let lastMentionAt: String?
  let lastMentionType: String?
  let nextFollowUpAt: String?

  var id: String { key }
  var isLedgerOnly: Bool { source == "ledger" }

  enum CodingKeys: String, CodingKey {
    case key, kind, source, title, aliases, file, line, stage, stageSource, emails, domains, role, owner
    case company, people, ledgerAccounts, openTaskCount, nextTask, meetingCount, mentionCount, lastInteractionAt, lastInteractionType
    case lastTouchAt, lastTouchType, lastMentionAt, lastMentionType, nextFollowUpAt
    case noteID = "id"
  }

  func matches(_ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return true }
    return ([title, role, company?.title ?? ""] + aliases + emails + domains)
      .contains { $0.lowercased().contains(needle) }
  }
}

struct CRMIndexPayload: Decodable, Sendable {
  struct Stats: Decodable, Sendable {
    let people: Int
    let companies: Int
    let ledgerOnlyCompanies: Int
    let ledgerAccounts: Int
    let linkedLedgerAccounts: Int
    let openTasks: Int
  }
  let stages: [String]
  let people: [CRMEntity]
  let companies: [CRMEntity]
  let stats: Stats
  /// Present with `crm list --details`: everything the detail pane shows.
  let details: [String: CRMEntityDetails]?
}

struct CRMEntityDetails: Decodable, Sendable {
  let tasks: [CRMTask]
  let timeline: [CRMTimelineItem]
  let upcoming: [CRMUpcomingMeeting]
}

struct CRMTimelineItem: Decodable, Identifiable, Hashable, Sendable {
  let key: String
  let type: String
  let title: String
  let at: String?
  let file: String?
  let line: Int?
  let detail: String?
  let via: String?
  let url: String?
  /// "attended" or "mentioned" for meetings and mentions.
  let role: String?
  var id: String { key }

  var isMention: Bool { role == "mentioned" }

  var systemImage: String {
    if isMention { return "text.bubble" }
    return switch type {
    case "meeting": "mic"
    case "task": "checkmark.circle"
    case "outreach": "paperplane"
    case "calendar": "calendar"
    default: "doc.text"
    }
  }
}

struct CRMUpcomingMeeting: Decodable, Identifiable, Hashable, Sendable {
  struct Event: Decodable, Hashable, Sendable {
    let eventId: String
    let title: String
    let start: String
    let end: String
    let htmlLink: String?
    let meetingUrl: String?
  }
  struct Person: Decodable, Hashable, Sendable {
    let key: String
    let title: String
    let email: String
  }
  struct Company: Decodable, Hashable, Sendable {
    let key: String
    let title: String
    let stage: String
    let lastInteractionAt: String?
    let lastTouchAt: String?
    let openTaskCount: Int
    let nextTask: CRMTask?
    let lastOutreachAt: String?
  }
  let event: Event
  let people: [Person]
  let companies: [Company]
  let unknownAttendees: [String]
  var id: String { event.eventId + event.start }
}

struct CRMDetailPayload: Decodable, Sendable {
  let entity: CRMEntity
  let revision: String?
  let properties: [String: String]
  let tasks: [CRMTask]
  let timeline: [CRMTimelineItem]
  let upcoming: [CRMUpcomingMeeting]
  let stages: [String]
}

struct CRMLinkProposal: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let type: String
  let title: String
  let reason: String
  let entity: CRMEntityRef
  let target: CRMEntityRef?
  let file: String
  let value: String
}

struct CRMLinkPayload: Decodable, Sendable {
  struct Result: Decodable, Sendable { let id: String; let applied: Bool; let error: String? }
  let proposals: [CRMLinkProposal]
  let results: [Result]?
}

struct CRMScheduleProposal: Decodable, Identifiable, Hashable, Sendable {
  let task: CRMTask
  let entity: CRMEntityRef
  let start: String
  let end: String
  let timestamp: String
  let reason: String
  var id: String { task.key }
}

struct CRMSchedulePayload: Decodable, Sendable {
  struct Result: Decodable, Sendable { let task: String; let applied: Bool; let error: String? }
  let generatedAt: String
  let proposals: [CRMScheduleProposal]
  let unplaced: Int
  let results: [Result]?
}

struct CRMUpcomingPayload: Decodable, Sendable {
  let meetings: [CRMUpcomingMeeting]
}

struct CRMCreatePayload: Decodable, Sendable {
  let id: String
  let title: String
  let file: String
}

// MARK: - Dates

enum CRMActivityLabel {
  static func touch(_ type: String) -> String {
    switch type {
    case "calendar": "calendar event"
    case "outreach": "outreach"
    default: "meeting"
    }
  }

  static func mention(_ type: String) -> String { type == "note" ? "in a note" : "in a meeting" }
}

enum CRMDate {
  static func parse(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    if value.count == 10 {
      let parts = value.split(separator: "-").compactMap { Int($0) }
      guard parts.count == 3 else { return nil }
      return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  static func hasTime(_ value: String?) -> Bool { (value?.count ?? 0) > 10 }

  /// "Today", "Tomorrow", "3 days ago", or "Mar 3".
  static func label(_ value: String?, now: Date = Date()) -> String? {
    guard let date = parse(value) else { return nil }
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    let time = hasTime(value) ? " " + date.formatted(date: .omitted, time: .shortened) : ""
    switch days {
    case 0: return "Today" + time
    case 1: return "Tomorrow" + time
    case -1: return "Yesterday" + time
    case 2...6: return date.formatted(.dateTime.weekday(.wide)) + time
    case -30 ... -2: return "\(-days) days ago"
    default:
      let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
      return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
  }

  static func isPast(_ value: String?, now: Date = Date()) -> Bool {
    guard let date = parse(value) else { return false }
    return hasTime(value) ? date < now : Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now)
  }
}

// MARK: - Model

/// People & Companies state shared by both surfaces, so switching between
/// People and Companies does not rebuild the index.
@MainActor
@Observable
public final class CRMWorkspaceModel {
  var index: CRMIndexPayload?
  var indexRoot: String?
  public internal(set) var isLoading = false
  var error: String?
  var isStale = true
  var selectedPersonKey: String?
  var selectedCompanyKey: String?
  var details: [String: CRMEntityDetails] = [:]
  var detailErrors: [String: String] = [:]
  var loadingDetailKey: String?
  @ObservationIgnored private var loadGeneration = 0

  public init() {}

  func reset() {
    index = nil
    indexRoot = nil
    error = nil
    isStale = true
    selectedPersonKey = nil
    selectedCompanyKey = nil
    details = [:]
    detailErrors = [:]
    loadGeneration += 1
  }

  /// Keep showing the current data; the next load replaces it in one step.
  func markStale() {
    isStale = true
  }

  /// Loads the index and every entity's activity in one read from the
  /// runtime's snapshot, so selecting a row never waits on the CLI.
  func load(cli: Org2CLI, root: String, force: Bool = false) async {
    if !force, !isStale, indexRoot == root, index != nil { return }
    if let running = currentLoad {
      // A forced load (after a write) must not reuse a read that started earlier.
      await running.value
      if !force, !isStale, indexRoot == root, index != nil { return }
      if let newer = currentLoad, newer != running { await newer.value; return }
    }
    let task = Task<Void, Never> { @MainActor [weak self] in await self?.performLoad(cli: cli, root: root) }
    currentLoad = task
    await task.value
    if currentLoad == task { currentLoad = nil }
  }

  @ObservationIgnored private var currentLoad: Task<Void, Never>?

  private func performLoad(cli: Org2CLI, root: String) async {
    isLoading = true
    loadGeneration += 1
    let generation = loadGeneration
    defer { if generation == loadGeneration { isLoading = false } }
    do {
      let payload: CRMIndexPayload = try await cli.runJSON(["crm", "list", "--details", "--dir", root])
      guard generation == loadGeneration else { return }
      index = payload
      indexRoot = root
      isStale = false
      error = nil
      details = payload.details ?? [:]
      detailErrors = [:]
    } catch {
      guard generation == loadGeneration else { return }
      self.error = error.localizedDescription
    }
  }

  /// Rebuilds the runtime snapshot ahead of time without decoding it here.
  func warm(cli: Org2CLI, root: String) async {
    guard currentLoad == nil else { return }
    _ = try? await cli.run(["crm", "warm", "--dir", root])
  }

  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  /// Debounced refresh after corpus changes: reload now if a page is on
  /// screen, otherwise just rebuild the snapshot so the next open is fast.
  func scheduleRefresh(cli: Org2CLI, root: String, visible: Bool) {
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(visible ? 2 : 20))
      guard !Task.isCancelled, let self else { return }
      if visible { await self.load(cli: cli, root: root, force: true) } else { await self.warm(cli: cli, root: root) }
    }
  }

  func loadDetail(cli: Org2CLI, root: String, key: String, force: Bool = false) async {
    if !force, details[key] != nil { return }
    loadingDetailKey = key
    defer { if loadingDetailKey == key { loadingDetailKey = nil } }
    do {
      let payload: CRMDetailPayload = try await cli.runJSON(["crm", "show", key, "--dir", root, "--days", "30"])
      guard indexRoot == nil || indexRoot == root else { return }
      details[key] = CRMEntityDetails(tasks: payload.tasks, timeline: payload.timeline, upcoming: payload.upcoming)
      detailErrors[key] = nil
    } catch {
      detailErrors[key] = error.localizedDescription
    }
  }
}

enum CRMHistoryFilter: String, CaseIterable, Identifiable {
  case all, contact, mentions
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "All"
    case .contact: "Contact"
    case .mentions: "Mentions"
    }
  }
}

enum CRMKind {
  case people
  case companies

  var title: String { self == .people ? "People" : "Companies" }
  var singular: String { self == .people ? "person" : "company" }
  var systemImage: String { self == .people ? "person.crop.circle" : "building.2" }
}

enum CRMCompanySourceFilter: String, CaseIterable, Identifiable {
  case notes, all, outreach
  var id: String { rawValue }
  var title: String {
    switch self {
    case .notes: "With Notes"
    case .all: "All"
    case .outreach: "Outreach Only"
    }
  }
}

// MARK: - Surface

struct PeopleCompaniesView: View {
  @Environment(WorkspaceStore.self) private var store
  let kind: CRMKind
  @State private var query = ""
  @State private var stageFilter: String?
  @AppStorage("Org2Workspace.crm.companySourceFilter.v1") private var sourceFilter = CRMCompanySourceFilter.notes.rawValue
  @State private var sheet: CRMSheet?

  private var model: CRMWorkspaceModel { store.crm }
  private var root: String? { store.corpusRoot?.standardizedFileURL.path }

  private var allEntities: [CRMEntity] {
    guard let index = model.index else { return [] }
    return kind == .people ? index.people : index.companies
  }

  private var entities: [CRMEntity] {
    allEntities.filter { entity in
      if kind == .companies {
        switch CRMCompanySourceFilter(rawValue: sourceFilter) ?? .notes {
        case .notes: if entity.isLedgerOnly { return false }
        case .outreach: if !entity.isLedgerOnly { return false }
        case .all: break
        }
      }
      if let stageFilter, entity.stage != stageFilter { return false }
      return entity.matches(query)
    }
  }

  private var selectedKey: String? {
    get { kind == .people ? model.selectedPersonKey : model.selectedCompanyKey }
  }

  private func select(_ key: String?) {
    if kind == .people { model.selectedPersonKey = key } else { model.selectedCompanyKey = key }
  }

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        header
        Divider()
        if let error = model.error, model.index == nil {
          ContentUnavailableView {
            Label("People & Companies could not load", systemImage: "exclamationmark.triangle")
          } description: {
            Text(error).textSelection(.enabled)
          } actions: {
            Button("Try Again") { Task { await reload(force: true) } }
          }
        } else if model.index == nil {
          VStack(spacing: 10) {
            ProgressView()
            Text("Reading people, companies, meetings, and outreach…").foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if proxy.size.width >= 760 {
          HStack(spacing: 0) {
            list.frame(width: min(380, max(280, proxy.size.width * 0.34)))
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else if selectedKey != nil {
          VStack(spacing: 0) {
            HStack {
              Button { select(nil) } label: { Label(kind.title, systemImage: "chevron.left") }
                .buttonStyle(.borderless)
              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            detail
          }
        } else {
          list
        }
      }
    }
    .task(id: root) { await reload(force: false) }
    .onAppear { Task { await reload(force: false) } }
    .sheet(item: $sheet) { sheet in
      CRMSheetView(sheet: sheet, kind: kind) { changed in
        if changed { await afterWrite() }
      }
      .environment(store)
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title).font(.title2.weight(.semibold))
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      TextField("Filter \(kind.title.lowercased())", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 220)
        .accessibilityIdentifier("crm-filter")
      if kind == .companies {
        Picker("Show", selection: $sourceFilter) {
          ForEach(CRMCompanySourceFilter.allCases) { filter in Text(filter.title).tag(filter.rawValue) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Companies with notes, outreach-only accounts, or both")
      }
      Menu {
        Button("All stages") { stageFilter = nil }
        Divider()
        ForEach(model.index?.stages ?? [], id: \.self) { stage in
          Button(stage.capitalized) { stageFilter = stage }
        }
      } label: {
        Label(stageFilter?.capitalized ?? "Stage", systemImage: "line.3.horizontal.decrease.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Menu {
        Button("Upcoming Meetings…", systemImage: "calendar") { sheet = .upcoming }
        Button("Plan Follow-ups…", systemImage: "calendar.badge.clock") { sheet = .schedule }
        Button("Review Suggested Links…", systemImage: "link") { sheet = .links }
      } label: {
        Label("Assist", systemImage: "sparkles")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Meeting briefs, follow-up scheduling, and link suggestions")
      if model.isLoading { ProgressView().controlSize(.small) }
      Button { Task { await reload(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        .labelStyle(.iconOnly)
        .disabled(model.isLoading || root == nil)
        .help("Reload from the corpus")
      Button { sheet = .create } label: { Label("New", systemImage: "plus") }
        .buttonStyle(.borderedProminent)
        .disabled(root == nil)
        .help("Create a \(kind.singular) note")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var subtitle: String {
    guard let index = model.index else { return "Your contacts, accounts, and follow-ups" }
    if kind == .people {
      return "\(index.stats.people) people · \(index.people.filter { $0.company != nil }.count) with a company"
    }
    return "\(index.stats.companies) companies · \(index.stats.ledgerOnlyCompanies) outreach-only · \(index.stats.openTasks) open follow-ups"
  }

  private var list: some View {
    Group {
      if entities.isEmpty {
        ContentUnavailableView {
          Label(allEntities.isEmpty ? "No \(kind.title.lowercased()) yet" : "Nothing matches", systemImage: kind.systemImage)
        } description: {
          Text(allEntities.isEmpty
            ? "Add :ORG2_ENTITY_TYPE: \(kind.singular) to a note's properties, or create one with New."
            : "Try another filter.")
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(entities) { entity in
              Button { select(entity.key) } label: {
                CRMEntityRow(entity: entity, kind: kind)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(selectedKey == entity.key ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("crm-row-\(entity.key)")
            }
          }
          .padding(6)
        }
      }
    }
    .background(Color.primary.opacity(0.018))
  }

  @ViewBuilder private var detail: some View {
    if let key = selectedKey, let entity = allEntities.first(where: { $0.key == key }) {
      CRMEntityDetailView(entity: entity, kind: kind, openSheet: { sheet = $0 }, afterWrite: { await afterWrite() })
        .id(key)
    } else {
      ContentUnavailableView {
        Label("Choose a \(kind.singular)", systemImage: kind.systemImage)
      } description: {
        Text(kind == .people
          ? "See their company, meetings, open follow-ups, and upcoming calendar events."
          : "See its people, stage, meetings, follow-ups, and outreach history.")
      }
    }
  }

  private func reload(force: Bool) async {
    guard let root else { return }
    await model.load(cli: store.cli, root: root, force: force)
  }

  private func afterWrite() async {
    model.markStale()
    await reload(force: true)
  }
}

private struct CRMEntityRow: View {
  let entity: CRMEntity
  let kind: CRMKind

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: entity.isLedgerOnly ? "paperplane.circle" : kind.systemImage)
        .foregroundStyle(entity.isLedgerOnly ? Color.secondary : Color.accentColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entity.title).font(.callout.weight(.medium)).lineLimit(1)
          if !entity.stage.isEmpty { CRMStageBadge(stage: entity.stage, inferred: entity.stageSource == "ledger") }
        }
        if !secondary.isEmpty {
          Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 2) {
        if let next = entity.nextFollowUpAt, let label = CRMDate.label(next) {
          Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(CRMDate.isPast(next) ? Color.red : Color.accentColor)
            .help("Next follow-up")
        }
        if let touch = CRMDate.label(entity.lastTouchAt) {
          Text(touch).font(.caption2).foregroundStyle(.tertiary).help("Last touch: direct contact")
        } else if let mention = CRMDate.label(entity.lastMentionAt) {
          Label(mention, systemImage: "text.bubble")
            .labelStyle(.titleAndIcon)
            .font(.caption2).foregroundStyle(.quaternary)
            .help("Mentioned, no direct contact yet")
        }
      }
    }
  }

  private var secondary: String {
    if kind == .people {
      return [entity.company?.title, entity.role.isEmpty ? nil : entity.role, entity.emails.first].compactMap { $0 }.joined(separator: " · ")
    }
    var parts: [String] = []
    if let domain = entity.domains.first { parts.append(domain) }
    if !entity.people.isEmpty { parts.append("\(entity.people.count) \(entity.people.count == 1 ? "person" : "people")") }
    if entity.openTaskCount > 0 { parts.append("\(entity.openTaskCount) open") }
    if let ledger = entity.ledgerAccounts.first, let status = ledger.workStatus { parts.append(status.replacingOccurrences(of: "-", with: " ")) }
    return parts.joined(separator: " · ")
  }
}

struct CRMStageBadge: View {
  let stage: String
  var inferred = false

  var body: some View {
    Text(stage.capitalized)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(inferred ? 0.06 : 0.13), in: Capsule())
      .help(inferred ? "Stage inferred from outreach; set one to replace it" : "Relationship stage")
  }

  private var color: Color {
    switch stage {
    case "customer": .green
    case "opportunity": .orange
    case "prospect": .blue
    case "partner": .purple
    case "former": .gray
    default: .teal
    }
  }
}

// MARK: - Detail

private struct CRMEntityDetailView: View {
  @Environment(WorkspaceStore.self) private var store
  let entity: CRMEntity
  let kind: CRMKind
  let openSheet: (CRMSheet) -> Void
  let afterWrite: () async -> Void
  @State private var actionError: String?
  @State private var isWorking = false
  @State private var historyFilter = CRMHistoryFilter.all

  private var model: CRMWorkspaceModel { store.crm }
  private var root: String? { store.corpusRoot?.standardizedFileURL.path }
  private var detail: CRMEntityDetails? { model.details[entity.key] }
  private var canWrite: Bool { !store.hasActiveEdit && !store.liveFileEditorHasUnsavedChanges && !isWorking }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        titleBlock
        if let actionError {
          Text(actionError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
        }
        if entity.isLedgerOnly { ledgerOnlyCallout }
        facts
        if let detail {
          if !detail.upcoming.isEmpty { upcoming(detail.upcoming) }
          tasks(detail.tasks)
          if kind == .companies, !entity.people.isEmpty { people }
          if !entity.ledgerAccounts.isEmpty { outreach }
          timeline(detail.timeline)
        } else if let error = model.detailErrors[entity.key] {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        } else {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading history…").foregroundStyle(.secondary) }
        }
      }
      .padding(20)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .task(id: entity.key) {
      guard let root else { return }
      await model.loadDetail(cli: store.cli, root: root, key: entity.key)
    }
  }

  private var titleBlock: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: entity.isLedgerOnly ? "paperplane.circle.fill" : kind.systemImage)
        .font(.system(size: 30))
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 4) {
        Text(entity.title).font(.title.weight(.semibold)).textSelection(.enabled)
        HStack(spacing: 8) {
          stageMenu
          if let company = entity.company {
            Button {
              store.crm.selectedCompanyKey = company.key
              store.makeSurfacePrimary(.companies)
            } label: { Label(company.title, systemImage: "building.2") }
              .buttonStyle(.link)
              .help(company.match == "explicit" || company.match == "property" ? "Company" : "Company (inferred from \(company.match.replacingOccurrences(of: "-", with: " ")))")
          }
        }
      }
      Spacer()
      if !entity.isLedgerOnly {
        Button { openSheet(.followUp(entity)) } label: { Label("Follow-up", systemImage: "plus.circle") }
          .disabled(!canWrite)
          .help("Add a TODO to this note")
        Button { openSource(file: entity.file, line: entity.line) } label: { Label("Open Note", systemImage: "doc.text") }
          .help("Open the note")
      }
    }
  }

  @ViewBuilder private var stageMenu: some View {
    if entity.isLedgerOnly {
      CRMStageBadge(stage: entity.stage, inferred: true)
    } else {
      Menu {
        ForEach(model.index?.stages ?? [], id: \.self) { stage in
          Button(stage.capitalized) { Task { await set(field: "stage", value: stage) } }
        }
        Divider()
        Button("Clear Stage") { Task { await set(field: "stage", value: "") } }
      } label: {
        if entity.stage.isEmpty { Text("Set stage") } else { CRMStageBadge(stage: entity.stage, inferred: entity.stageSource == "ledger") }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(!canWrite)
    }
  }

  private var ledgerOnlyCallout: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "info.circle").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("This company exists only in an outreach ledger.").font(.callout.weight(.medium))
        Text("Create a company note to keep context, people, and follow-ups with it. The ledger account is linked to the new note.")
          .font(.callout).foregroundStyle(.secondary)
        Button("Create Company Note") { Task { await createFromLedger() } }
          .buttonStyle(.borderedProminent)
          .disabled(!canWrite)
      }
    }
    .padding(12)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }

  private var facts: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
      if kind == .people {
        fact("Email", entity.emails.joined(separator: ", "), field: "email")
        fact("Role", entity.role, field: "role")
        fact("Company", entity.company?.title ?? "", field: "company")
      } else {
        fact("Domain", entity.domains.joined(separator: ", "), field: "domain")
      }
      fact("Owner", entity.owner, field: "owner")
      GridRow {
        Text("Last touch").foregroundStyle(.secondary)
        Text([CRMDate.label(entity.lastTouchAt), entity.lastTouchType.map(CRMActivityLabel.touch)].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "No direct contact yet")
          .help("The last meeting or calendar event they took part in, or outreach sent or received")
      }
      GridRow {
        Text("Last mentioned").foregroundStyle(.secondary)
        Text([CRMDate.label(entity.lastMentionAt), entity.lastMentionType.map(CRMActivityLabel.mention)].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—")
          .help("The last time someone brought them up in a meeting or note they were not part of")
      }
      GridRow {
        Text("Next").foregroundStyle(.secondary)
        Text(CRMDate.label(entity.nextFollowUpAt) ?? "No follow-up scheduled")
          .foregroundStyle(CRMDate.isPast(entity.nextFollowUpAt) ? Color.red : Color.primary)
      }
    }
    .font(.callout)
  }

  private func fact(_ label: String, _ value: String, field: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        if !entity.isLedgerOnly {
          Button { openSheet(.editField(entity, field: field, current: value)) } label: {
            Image(systemName: "pencil")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(!canWrite)
          .help("Edit \(label.lowercased())")
        }
      }
    }
  }

  private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage).font(.headline)
      content()
    }
  }

  private func upcoming(_ meetings: [CRMUpcomingMeeting]) -> some View {
    section("Upcoming", systemImage: "calendar") {
      ForEach(meetings) { meeting in
        HStack {
          Text(CRMDate.label(meeting.event.start) ?? meeting.event.start).font(.callout.weight(.medium)).frame(width: 150, alignment: .leading)
          Text(meeting.event.title).lineLimit(1)
          Spacer()
          if let link = meeting.event.meetingUrl ?? meeting.event.htmlLink, let url = URL(string: link) {
            Link("Open", destination: url).font(.caption)
          }
        }
      }
    }
  }

  private func tasks(_ tasks: [CRMTask]) -> some View {
    let open = tasks.filter(\.open)
    return section("Follow-ups", systemImage: "checklist") {
      if open.isEmpty {
        Text(entity.isLedgerOnly ? "Create a company note to add follow-ups." : "No open follow-ups.").foregroundStyle(.secondary).font(.callout)
      }
      ForEach(open) { task in
        HStack(spacing: 8) {
          Button { Task { await complete(task) } } label: { Image(systemName: "circle") }
            .buttonStyle(.borderless)
            .disabled(!canWrite)
            .help("Mark done")
          Button { openSource(file: task.file, line: task.line) } label: {
            VStack(alignment: .leading, spacing: 1) {
              OrgInlineText(task.title, font: .callout, managesTextSelection: false).lineLimit(2)
              Text([task.todo, task.via.map { "via \($0)" }, task.file].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          if let due = task.due, let label = CRMDate.label(due) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(CRMDate.isPast(due) ? Color.red : Color.secondary)
          }
        }
      }
    }
  }

  private var people: some View {
    section("People", systemImage: "person.2") {
      FlowLayout(spacing: 6) {
        ForEach(entity.people, id: \.key) { person in
          Button(person.title) {
            store.crm.selectedPersonKey = person.key
            store.makeSurfacePrimary(.people)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
  }

  private var outreach: some View {
    section("Outreach", systemImage: "paperplane") {
      ForEach(entity.ledgerAccounts, id: \.self) { ref in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 1) {
            Text("\(ref.ledger) · \(ref.state)").font(.callout.weight(.medium))
            Text([ref.workStatus?.replacingOccurrences(of: "-", with: " "), "\(ref.eventCount) events", ref.match == "explicit" ? nil : "matched by \(ref.match)"].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if let last = CRMDate.label(ref.lastContactAt) { Text("Last contact \(last)").font(.caption).foregroundStyle(.secondary) }
          Button { openSource(file: ref.file, line: 1) } label: { Image(systemName: "doc.text") }
            .buttonStyle(.borderless)
            .help("Open the ledger account")
        }
      }
    }
  }

  private func timeline(_ allItems: [CRMTimelineItem]) -> some View {
    let items = allItems.filter { item in
      switch historyFilter {
      case .all: true
      case .contact: !item.isMention && item.type != "task"
      case .mentions: item.isMention
      }
    }
    return section("History", systemImage: "clock") {
      Picker("Show", selection: $historyFilter) {
        ForEach(CRMHistoryFilter.allCases) { filter in Text(filter.title).tag(filter) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 320)
      if items.isEmpty { Text(historyFilter == .mentions ? "No mentions yet." : "No meetings, mentions, or outreach yet.").foregroundStyle(.secondary).font(.callout) }
      ForEach(items.prefix(120)) { item in
        Button {
          if let urlString = item.url, let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
          else { openSource(file: item.file, line: item.line) }
        } label: {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.systemImage).foregroundStyle(Color.accentColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
              OrgInlineText(item.title, font: .callout, managesTextSelection: false).lineLimit(2)
              if let detail = [item.isMention ? (item.type == "meeting" ? "Mentioned in a meeting" : "Mentioned") : nil, item.detail ?? item.via.map({ "via \($0)" })].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }
            }
            Spacer(minLength: 6)
            Text(CRMDate.label(item.at) ?? "").font(.caption).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.file == nil && item.url == nil)
      }
    }
  }

  private func openSource(file: String?, line: Int?) {
    guard let root, let file else { return }
    store.openChatFileReference(.init(path: URL(fileURLWithPath: root).appendingPathComponent(file).path, line: line ?? 1))
  }

  private func set(field: String, value: String) async {
    guard let root else { return }
    await perform { _ = try await store.cli.run(["crm", "set", entity.key, "--field", field, "--value", value, "--dir", root, "--apply"]) }
  }

  private func complete(_ task: CRMTask) async {
    guard let root else { return }
    await perform {
      let path = URL(fileURLWithPath: root).appendingPathComponent(task.file).path
      try await store.setTodoStatus(.done, for: HeadlineMutationTarget(file: path, line: task.line, title: task.title))
    }
  }

  private func createFromLedger() async {
    guard let root, let ref = entity.ledgerAccounts.first else { return }
    await perform {
      let created: CRMCreatePayload = try await store.cli.runJSON(["crm", "create", "company", "--from-ledger", "\(ref.ledger)/\(ref.id)", "--dir", root, "--apply"])
      store.crm.selectedCompanyKey = "id:\(created.id)"
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await operation()
      actionError = nil
      await afterWrite()
    } catch {
      actionError = error.localizedDescription
    }
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
      x += size.width + spacing
      row = max(row, size.height)
    }
    return CGSize(width: width, height: y + row)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}

// MARK: - Sheets

enum CRMSheet: Identifiable {
  case create
  case followUp(CRMEntity)
  case editField(CRMEntity, field: String, current: String)
  case links
  case schedule
  case upcoming

  var id: String {
    switch self {
    case .create: "create"
    case .followUp(let entity): "follow-up:\(entity.key)"
    case .editField(let entity, let field, _): "edit:\(entity.key):\(field)"
    case .links: "links"
    case .schedule: "schedule"
    case .upcoming: "upcoming"
    }
  }
}

private struct CRMSheetView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let sheet: CRMSheet
  let kind: CRMKind
  let completion: (Bool) async -> Void

  @State private var title = ""
  @State private var value = ""
  @State private var email = ""
  @State private var domain = ""
  @State private var role = ""
  @State private var company = ""
  @State private var stage = ""
  @State private var schedules = true
  @State private var date = Date()
  @State private var includesTime = false
  @State private var priority = ""
  @State private var error: String?
  @State private var busy = false
  @State private var links: [CRMLinkProposal]?
  @State private var plan: CRMSchedulePayload?
  @State private var meetings: [CRMUpcomingMeeting]?
  @State private var selected: Set<String> = []

  private var root: String? { store.corpusRoot?.standardizedFileURL.path }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
      if let error {
        Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button(primaryAction == nil ? "Done" : "Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        if let primaryAction {
          Button(primaryAction) { Task { await submit() } }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || !canSubmit)
        }
      }
    }
    .padding(20)
    .frame(width: wide ? 640 : 440)
    .frame(minHeight: wide ? 420 : 0)
    .task { await prepare() }
  }

  private var wide: Bool {
    switch sheet {
    case .links, .schedule, .upcoming: true
    default: false
    }
  }

  private var primaryAction: String? {
    switch sheet {
    case .create: "Create"
    case .followUp: "Add Follow-up"
    case .editField: "Save"
    case .links: links?.isEmpty == false ? "Apply \(selected.count) Selected" : nil
    case .schedule: plan?.proposals.isEmpty == false ? "Schedule \(selected.count)" : nil
    case .upcoming: nil
    }
  }

  private var canSubmit: Bool {
    switch sheet {
    case .create, .followUp: !title.trimmingCharacters(in: .whitespaces).isEmpty
    case .links, .schedule: !selected.isEmpty
    default: true
    }
  }

  @ViewBuilder private var content: some View {
    switch sheet {
    case .create:
      Text("New \(kind.singular.capitalized)").font(.title2.weight(.semibold))
      Form {
        TextField("Name", text: $title)
        if kind == .people {
          TextField("Email", text: $email)
          TextField("Role", text: $role)
          TextField("Company", text: $company, prompt: Text("Name, domain, or ID"))
        } else {
          TextField("Domain", text: $domain, prompt: Text("example.com"))
        }
        Picker("Stage", selection: $stage) {
          Text("None").tag("")
          ForEach(store.crm.index?.stages ?? [], id: \.self) { Text($0.capitalized).tag($0) }
        }
      }
      Text("Creates an ordinary note in your notes folder with these properties.").font(.caption).foregroundStyle(.secondary)
    case .followUp(let entity):
      Text("Follow-up for \(entity.title)").font(.title2.weight(.semibold))
      Form {
        TextField("What needs to happen?", text: $title)
        Toggle("Schedule", isOn: $schedules)
        if schedules {
          DatePicker("Date", selection: $date, displayedComponents: .date)
          Toggle("At a specific time", isOn: $includesTime)
          if includesTime { DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute) }
        }
        Picker("Priority", selection: $priority) {
          Text("None").tag("")
          Text("A").tag("A")
          Text("B").tag("B")
          Text("C").tag("C")
        }
      }
      Text("Adds a TODO to the end of \(entity.title)'s note. It shows up in Agenda and Calendar.").font(.caption).foregroundStyle(.secondary)
    case .editField(let entity, let field, _):
      Text("\(field.capitalized) for \(entity.title)").font(.title2.weight(.semibold))
      TextField(field == "company" ? "Company name, domain, or ID" : field.capitalized, text: $value)
        .textFieldStyle(.roundedBorder)
      Text(field == "company" ? "Saved as a link to the company's note." : "Saved as a property in the note. Leave empty to clear it.")
        .font(.caption).foregroundStyle(.secondary)
    case .links:
      Text("Suggested Links").font(.title2.weight(.semibold))
      Text("Celorga matched these by domain, email, or name. Accepting writes an explicit link so the match no longer depends on a guess.")
        .font(.callout).foregroundStyle(.secondary)
      proposalList(items: (links ?? []).map { ($0.id, $0.title, $0.reason) }, loading: links == nil, empty: "No suggestions. Everything Celorga could match is already linked.")
    case .schedule:
      Text("Plan Follow-ups").font(.title2.weight(.semibold))
      Text("Free slots in the next five working days for follow-ups that are due, using busy times from your synced calendar. Only each TODO's SCHEDULED line changes; nothing is added to your calendar.")
        .font(.callout).foregroundStyle(.secondary)
      proposalList(
        items: (plan?.proposals ?? []).map { ($0.id, "\($0.task.title) — \($0.entity.title)", "\(slotLabel($0)) · \($0.reason)") },
        loading: plan == nil,
        empty: "No due follow-ups need a time."
      )
      if let unplaced = plan?.unplaced, unplaced > 0 {
        Text("\(unplaced) follow-up\(unplaced == 1 ? "" : "s") did not fit in the window.").font(.caption).foregroundStyle(.secondary)
      }
    case .upcoming:
      Text("Upcoming Meetings").font(.title2.weight(.semibold))
      Text("The next seven days of synced calendar events with people outside your team, matched to your people and companies.")
        .font(.callout).foregroundStyle(.secondary)
      if let meetings {
        if meetings.isEmpty { Text("No upcoming external meetings.").foregroundStyle(.secondary) }
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(meetings) { meeting in meetingBrief(meeting) }
          }
        }
      } else {
        ProgressView()
      }
    }
  }

  private func proposalList(items: [(id: String, title: String, detail: String)], loading: Bool, empty: String) -> some View {
    Group {
      if loading {
        HStack { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) }
      } else if items.isEmpty {
        Text(empty).foregroundStyle(.secondary)
      } else {
        HStack {
          Button("Select All") { selected = Set(items.map(\.id)) }
          Button("Select None") { selected = [] }
          Spacer()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.id) { item in
              Toggle(isOn: Binding(
                get: { selected.contains(item.id) },
                set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }
              )) {
                VStack(alignment: .leading, spacing: 1) {
                  OrgInlineText(item.title, font: .callout, managesTextSelection: false).lineLimit(2)
                  Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
      }
    }
  }

  private func meetingBrief(_ meeting: CRMUpcomingMeeting) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(CRMDate.label(meeting.event.start) ?? meeting.event.start).font(.callout.weight(.semibold))
        Text(meeting.event.title).font(.callout)
        Spacer()
        if let link = meeting.event.meetingUrl ?? meeting.event.htmlLink, let url = URL(string: link) { Link("Open", destination: url).font(.caption) }
      }
      ForEach(meeting.companies, id: \.key) { company in
        HStack(spacing: 6) {
          Image(systemName: "building.2").foregroundStyle(.secondary)
          Text(company.title).font(.caption.weight(.medium))
          CRMStageBadge(stage: company.stage)
          Text([
            company.lastTouchAt.flatMap { CRMDate.label($0) }.map { "last touch \($0)" },
            company.lastOutreachAt.flatMap { CRMDate.label($0) }.map { "outreach \($0)" },
            company.openTaskCount > 0 ? "\(company.openTaskCount) open" : nil,
            company.nextTask.map { "next: \($0.title)" },
          ].compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      if !meeting.people.isEmpty {
        Text("With " + meeting.people.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
      }
      if !meeting.unknownAttendees.isEmpty {
        Text("Not in your notes: " + meeting.unknownAttendees.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
  }

  private func slotLabel(_ proposal: CRMScheduleProposal) -> String {
    guard let start = CRMDate.parse(proposal.start), let end = CRMDate.parse(proposal.end) else { return proposal.timestamp }
    return "\(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
  }

  private func prepare() async {
    guard let root else { return }
    switch sheet {
    case .editField(_, let field, let current):
      value = field == "email" || field == "domain" ? current.components(separatedBy: ", ").first ?? "" : current
    case .followUp:
      date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    case .links:
      do {
        let payload: CRMLinkPayload = try await store.cli.runJSON(["crm", "link", "--dir", root])
        links = payload.proposals
        selected = Set(payload.proposals.map(\.id))
      } catch { self.error = error.localizedDescription; links = [] }
    case .schedule:
      do {
        let payload: CRMSchedulePayload = try await store.cli.runJSON(["crm", "schedule", "--dir", root])
        plan = payload
        selected = Set(payload.proposals.map(\.id))
      } catch { self.error = error.localizedDescription }
    case .upcoming:
      do {
        let payload: CRMUpcomingPayload = try await store.cli.runJSON(["crm", "upcoming", "--dir", root, "--days", "7"])
        meetings = payload.meetings
      } catch { self.error = error.localizedDescription; meetings = [] }
    case .create:
      break
    }
  }

  private func submit() async {
    guard let root else { return }
    busy = true
    defer { busy = false }
    do {
      switch sheet {
      case .create:
        var arguments = ["crm", "create", kind == .people ? "person" : "company", "--title", title.trimmingCharacters(in: .whitespaces), "--dir", root, "--apply"]
        if !email.isEmpty { arguments += ["--email", email] }
        if !role.isEmpty { arguments += ["--role", role] }
        if !company.isEmpty { arguments += ["--company", company] }
        if !domain.isEmpty { arguments += ["--domain", domain] }
        if !stage.isEmpty { arguments += ["--stage", stage] }
        let created: CRMCreatePayload = try await store.cli.runJSON(arguments)
        if kind == .people { store.crm.selectedPersonKey = "id:\(created.id)" } else { store.crm.selectedCompanyKey = "id:\(created.id)" }
      case .followUp(let entity):
        var arguments = ["crm", "follow-up", entity.key, "--title", title.trimmingCharacters(in: .whitespaces), "--dir", root, "--apply"]
        if schedules {
          let day = date.formatted(.iso8601.year().month().day())
          let time = includesTime ? " " + String(format: "%02d:%02d", Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date)) : ""
          arguments += ["--scheduled", day + time]
        }
        if !priority.isEmpty { arguments += ["--priority", priority] }
        _ = try await store.cli.run(arguments)
      case .editField(let entity, let field, _):
        _ = try await store.cli.run(["crm", "set", entity.key, "--field", field, "--value", value.trimmingCharacters(in: .whitespaces), "--dir", root, "--apply"])
      case .links:
        let payload: CRMLinkPayload = try await store.cli.runJSON(["crm", "link", "--only", selected.sorted().joined(separator: ","), "--dir", root, "--apply"])
        let failures = (payload.results ?? []).filter { !$0.applied }
        if !failures.isEmpty {
          error = failures.compactMap(\.error).joined(separator: "\n")
          await completion(true)
          return
        }
      case .schedule:
        // Reuse the preview's clock so the applied slots are the ones shown.
        let payload: CRMSchedulePayload = try await store.cli.runJSON(["crm", "schedule", "--only", selected.sorted().joined(separator: ","), "--now", plan?.generatedAt ?? "", "--dir", root, "--apply"])
        let failures = (payload.results ?? []).filter { !$0.applied }
        if !failures.isEmpty {
          error = failures.compactMap(\.error).joined(separator: "\n")
          await completion(true)
          return
        }
      case .upcoming:
        break
      }
      await completion(true)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
