import Foundation

/// A person or company from People & Companies, as Quick Open and workspace
/// Search match and show it.
public struct WorkspaceCRMSearchEntity: Identifiable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case person
    case company
  }

  /// The `celorga crm` entity key.
  public let key: String
  public let kind: Kind
  public let title: String
  public let aliases: [String]
  /// One line under the title: company and role, or stage and domain.
  public let subtitle: String
  /// Absolute path of the person or company note, if it has one.
  public let notePath: String?
  /// Exists only in an outreach ledger.
  public let isOutreachOnly: Bool
  let normalizedNames: [String]
  let normalizedContacts: [String]

  public var id: String { key }
  public var systemImage: String { kind == .person ? "person.crop.circle" : "building.2" }
  public var kindLabel: String {
    kind == .person ? "Person" : (isOutreachOnly ? "Company (outreach only)" : "Company")
  }

  init(_ entity: CRMEntity, corpusRoot: String) {
    key = entity.key
    kind = entity.kind == "person" ? .person : .company
    title = Org2Display.cleanInline(entity.title)
    aliases = entity.aliases
    isOutreachOnly = entity.isLedgerOnly
    notePath = entity.isLedgerOnly ? nil : entity.file.map { URL(fileURLWithPath: corpusRoot).appendingPathComponent($0).standardizedFileURL.path }
    var parts: [String] = []
    if kind == .person {
      if let company = entity.company?.title { parts.append(company) }
      if !entity.role.isEmpty { parts.append(entity.role) }
      if let email = entity.emails.first { parts.append(email) }
    } else {
      if !entity.stage.isEmpty { parts.append(entity.stage.capitalized) }
      if let domain = entity.domains.first { parts.append(domain) }
      if !entity.people.isEmpty { parts.append("\(entity.people.count) \(entity.people.count == 1 ? "person" : "people")") }
    }
    subtitle = parts.joined(separator: " · ")
    normalizedNames = ([title] + entity.aliases).map { WorkspaceStore.normalizedQuickOpenCandidate($0) }
    normalizedContacts = (entity.emails + entity.domains).map { $0.lowercased() }
  }

  /// Quick Open: a contiguous match in a name, email, or domain. Fuzzy
  /// subsequence matches would list hundreds of unrelated accounts.
  func quickOpenScore(normalizedQuery query: String) -> Int? {
    guard !query.isEmpty else { return nil }
    let nameScore = normalizedNames.enumerated().compactMap { index, name -> Int? in
      let compact = name.filter { !$0.isWhitespace }
      guard compact.contains(query),
            let score = WorkspaceStore.fuzzyScore(normalizedQuery: query, normalizedCandidate: name)
      else { return nil }
      return index == 0 ? score : score - 5
    }.max()
    let contactScore = normalizedContacts.contains { $0.contains(query) } ? 40 : nil
    guard let best = [nameScore, contactScore].compactMap({ $0 }).max() else { return nil }
    // A named person or company outranks the path of its own note.
    return best + 15 - (isOutreachOnly ? 12 : 0)
  }

  /// Workspace Search: title quality, like a page title.
  func searchQuality(_ query: WorkspaceSearchQuery) -> Double? {
    if let quality = query.titleQuality(title) { return quality }
    if let alias = aliases.compactMap(query.titleQuality).max() { return alias - WorkspaceSearchRanking.aliasPenalty }
    if normalizedContacts.contains(where: { query.match($0) != nil }) { return WorkspaceSearchRanking.substringTitleQuality }
    return nil
  }
}

extension WorkspaceStore {
  /// People and companies Quick Open and Search can return; empty while the
  /// People & Companies app is off or still loading.
  var crmSearchEntities: [WorkspaceCRMSearchEntity] {
    isWorkspaceAppEnabled("crm") ? crm.searchEntities : []
  }

  /// Opens a person or company on its People or Companies page.
  public func openCRMEntity(_ entity: WorkspaceCRMSearchEntity) {
    switch entity.kind {
    case .person:
      crm.selectedPersonKey = entity.key
      makeSurfacePrimary(.people)
    case .company:
      crm.selectedCompanyKey = entity.key
      makeSurfacePrimary(.companies)
    }
    statusText = "Opened \(entity.title)"
  }

  nonisolated static func searchCRMEntitiesForWorkspace(
    _ entities: [WorkspaceCRMSearchEntity],
    query rawQuery: String,
    limit: Int
  ) -> [WorkspaceCRMSearchEntity] {
    guard let query = WorkspaceSearchQuery(rawQuery), limit > 0 else { return [] }
    return entities
      .compactMap { entity in entity.searchQuality(query).map { (entity, $0 - (entity.isOutreachOnly ? 1 : 0)) } }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
      }
      .prefix(limit)
      .map(\.0)
  }
}

extension WorkspaceStore {
  /// Quick Open match IDs, for tests.
  nonisolated static func filterQuickOpenItemsForTesting(
    files: [QuickOpenIndexedFile],
    crmEntities: [WorkspaceCRMSearchEntity],
    query: String
  ) -> [String] {
    filterQuickOpenItems(files: files, chatThreads: [], crmEntities: crmEntities, query: query, limit: 80).map { match in
      switch match {
      case .file(let file): "file:\(file.id)"
      case .chatThread(let id): "chat:\(id.uuidString)"
      case .approval(let approval): "approval:\(approval.id)"
      case .crmEntity(let entity): "crm:\(entity.key)"
      }
    }
  }
}
