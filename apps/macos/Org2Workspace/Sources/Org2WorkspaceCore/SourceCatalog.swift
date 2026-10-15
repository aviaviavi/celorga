import Foundation

/// One option of a choice field. Choosing it can move linked fields that still
/// hold another option's default (for example TLS ↔ STARTTLS ports).
public struct WorkspaceSourceChoice: Identifiable, Equatable, Sendable {
  public var value: String
  public var title: String
  public var linkedDefaults: [String: String]

  public var id: String { value }

  public init(_ value: String, _ title: String, linkedDefaults: [String: String] = [:]) {
    self.value = value
    self.title = title
    self.linkedDefaults = linkedDefaults
  }
}

/// One non-secret configuration field of a source type and where its value
/// lives in the type's `celorga.json` `externalSources` entry.
public struct WorkspaceSourceField: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case text
    case integer
    /// Comma-separated in the form, a JSON string list in celorga.json.
    case list
    case choice([WorkspaceSourceChoice])
  }

  public enum Target: Equatable, Sendable {
    /// A nested key path in the source entry, such as `["email", "host"]`.
    case path([String])
    /// The crawler's `--source MODE` pair inside `syncArgs`.
    case syncSource
  }

  public var id: String
  public var label: String
  public var prompt: String
  public var help: String?
  public var kind: Kind
  public var target: Target
  public var isRequired: Bool
  public var defaultValue: String
  /// The field is written only while this other field has a value.
  public var dependsOn: String?

  public init(
    id: String,
    label: String,
    prompt: String = "",
    help: String? = nil,
    kind: Kind = .text,
    target: Target,
    isRequired: Bool = false,
    defaultValue: String = "",
    dependsOn: String? = nil
  ) {
    self.id = id
    self.label = label
    self.prompt = prompt
    self.help = help
    self.kind = kind
    self.target = target
    self.isRequired = isRequired
    self.defaultValue = defaultValue
    self.dependsOn = dependsOn
  }
}

/// How a source's secret is obtained.
public enum WorkspaceSourceSignIn: Equatable, Sendable {
  /// Google OAuth in the browser with this scope; the stored secret is a
  /// refresh credential (`org2:google-oauth-credential:v1` JSON).
  case google(scope: String)
}

/// The secret a source type authenticates with. It is stored in macOS
/// Keychain (and, when a server is paired, that server's private credential
/// store) and passed to the sync process as an environment variable only.
public struct WorkspaceSourceSecret: Equatable, Sendable {
  public var label: String
  public var environmentVariable: String
  public var help: String
  /// Crawler modes that cannot run without it; `nil` means always required.
  public var requiredForSyncSources: Set<String>?
  /// Set when the secret comes from a browser sign-in instead of being pasted.
  public var signIn: WorkspaceSourceSignIn?

  public init(
    label: String,
    environmentVariable: String,
    help: String,
    requiredForSyncSources: Set<String>? = nil,
    signIn: WorkspaceSourceSignIn? = nil
  ) {
    self.label = label
    self.environmentVariable = environmentVariable
    self.help = help
    self.requiredForSyncSources = requiredForSyncSources
    self.signIn = signIn
  }
}

/// Everything OpenOrg needs to add, edit, authenticate, and explain one
/// supported `externalSources` type. The Sources view renders only from this.
public struct WorkspaceSourceType: Identifiable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var systemImage: String
  public var summary: String
  public var defaultProfileID: String
  public var fields: [WorkspaceSourceField]
  public var secret: WorkspaceSourceSecret?
  /// `syncArgs` written for a new profile, with `--source MODE` filled from the form.
  public var defaultSyncArgs: [String]

  public var addTitle: String { "Add \(displayName) Source" }

  public func field(_ id: String) -> WorkspaceSourceField? {
    fields.first { $0.id == id }
  }

  /// Whether a profile of this type cannot sync until a secret is available.
  public func requiresSecret(syncArgs: [String]) -> Bool {
    guard let secret else { return false }
    guard let modes = secret.requiredForSyncSources else { return true }
    return !modes.isDisjoint(with: syncArgs)
  }

  public var agentSetupPrompt: String {
    let fieldList = fields.map { field in
      "- \(field.label)\(field.isRequired ? " (required)" : "")\(field.help.map { ": \($0)" } ?? "")"
    }.joined(separator: "\n")
    let secretLine = secret.map {
      $0.signIn != nil
        ? "It authenticates by signing in with Google. Never put it in celorga.json, a file, or a command line, and never ask me for a token; ask me to use the source's “Sign in with Google” button in Celorga's Sources view instead, which also sends the credential to the connected server."
        : "It authenticates with a \($0.label.lowercased()). Never put it in celorga.json, a file, or a command line; ask me to save it with the source's “Add \($0.label)” button in Celorga's Sources view (macOS Keychain) instead."
    } ?? "It needs no stored credential."
    return """
    Help me set up a \(displayName) source for this corpus. \(summary)

    Ask me for anything you need, then preview the entry with `celorga source add PROFILE --source-json '<JSON>'` and apply it with `--apply` after I confirm. Settings:
    \(fieldList)

    \(secretLine) Finish with `celorga source doctor PROFILE` and tell me what, if anything, still needs setup.
    """
  }
}

public enum WorkspaceSourceCatalog {
  public static let googleCalendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"

  /// Every `externalSources` type the Org2 runtime syncs (`EXTERNAL_SOURCE_TYPES` in src/sourceRuntime.ts).
  public static let types: [WorkspaceSourceType] = [slack, notion, email, googleCalendar]

  public static func type(_ id: String) -> WorkspaceSourceType? {
    types.first { $0.id == id.lowercased() }
  }

  static let since = WorkspaceSourceField(
    id: "since",
    label: "Initial window",
    prompt: "14d",
    help: "How far back the first stage reaches, such as 14d or an ISO timestamp.",
    target: .path(["ingestion", "since"]),
    defaultValue: "14d"
  )

  public static let slack = WorkspaceSourceType(
    id: "slack",
    displayName: "Slack",
    systemImage: "number",
    summary: "Slack is mirrored by the local slacrawl crawler and staged as review-required Org packets.",
    defaultProfileID: "slack",
    fields: [
      WorkspaceSourceField(
        id: "workspaceId",
        label: "Workspace ID",
        prompt: "T01ABCDEF",
        help: "Optional Slack team ID to limit the sync to one workspace.",
        target: .path(["workspaceId"])
      ),
      WorkspaceSourceField(
        id: "syncSource",
        label: "Read from",
        help: "Where slacrawl reads messages.",
        kind: .choice([
          WorkspaceSourceChoice("bot", "Bot token"),
          WorkspaceSourceChoice("api", "User token (API)"),
          WorkspaceSourceChoice("desktop", "Slack desktop app"),
          WorkspaceSourceChoice("all", "All available"),
        ]),
        target: .syncSource,
        defaultValue: "bot"
      ),
      WorkspaceSourceField(
        id: "scopes",
        label: "Channels",
        prompt: "engineering, design",
        help: "Optional channel names to stage; leave empty for all synced channels.",
        kind: .list,
        target: .path(["scopes"])
      ),
      since,
    ],
    secret: WorkspaceSourceSecret(
      label: "Bot Token",
      environmentVariable: "SLACK_BOT_TOKEN",
      help: "Paste a Slack bot token (xoxb-…). Celorga stores it in macOS Keychain and passes it only to slacrawl; it is never written to the corpus.",
      requiredForSyncSources: []
    ),
    defaultSyncArgs: ["--source", "bot", "--latest-only"]
  )

  public static let notion = WorkspaceSourceType(
    id: "notion",
    displayName: "Notion",
    systemImage: "doc.text",
    summary: "Notion pages are mirrored by the local notcrawl crawler and staged as review-required Org packets.",
    defaultProfileID: "notion",
    fields: [
      WorkspaceSourceField(
        id: "syncSource",
        label: "Read from",
        help: "Where notcrawl reads pages.",
        kind: .choice([
          WorkspaceSourceChoice("api", "Integration token (API)"),
          WorkspaceSourceChoice("desktop", "Notion desktop app"),
          WorkspaceSourceChoice("all", "All available"),
        ]),
        target: .syncSource,
        defaultValue: "api"
      ),
      WorkspaceSourceField(
        id: "scopes",
        label: "Teamspaces",
        prompt: "Engineering, Product",
        help: "Optional teamspace or workspace names to stage; leave empty for everything synced.",
        kind: .list,
        target: .path(["scopes"])
      ),
      since,
    ],
    secret: WorkspaceSourceSecret(
      label: "Token",
      environmentVariable: "NOTION_TOKEN",
      help: "Paste a Notion internal integration token. Celorga stores it in macOS Keychain and passes it only to notcrawl; it is never written to the corpus.",
      requiredForSyncSources: ["api"]
    ),
    defaultSyncArgs: ["--source", "api"]
  )

  public static let email = WorkspaceSourceType(
    id: "email",
    displayName: "Email",
    systemImage: "envelope",
    summary: "Celorga reads new mail over IMAP without marking it read and stages it as review-required Org packets. Many providers require an app password.",
    defaultProfileID: "mail",
    fields: [
      WorkspaceSourceField(id: "host", label: "IMAP server", prompt: "imap.example.com", target: .path(["email", "host"]), isRequired: true),
      WorkspaceSourceField(
        id: "security",
        label: "Security",
        kind: .choice([
          WorkspaceSourceChoice("tls", "TLS", linkedDefaults: ["port": "993"]),
          WorkspaceSourceChoice("starttls", "STARTTLS", linkedDefaults: ["port": "143"]),
        ]),
        target: .path(["email", "security"]),
        defaultValue: "tls"
      ),
      WorkspaceSourceField(id: "port", label: "Port", prompt: "993", kind: .integer, target: .path(["email", "port"]), isRequired: true, defaultValue: "993"),
      WorkspaceSourceField(id: "username", label: "User name", prompt: "you@example.com", target: .path(["email", "username"]), isRequired: true),
      WorkspaceSourceField(
        id: "mailboxes",
        label: "Mailboxes",
        prompt: "INBOX, Archive",
        kind: .list,
        target: .path(["email", "mailboxes"]),
        defaultValue: "INBOX"
      ),
      WorkspaceSourceField(
        id: "smtpHost",
        label: "SMTP server",
        prompt: "smtp.example.com",
        help: "Optional; recorded for reference.",
        target: .path(["email", "smtp", "host"])
      ),
      WorkspaceSourceField(
        id: "smtpPort",
        label: "SMTP port",
        prompt: "587",
        kind: .integer,
        target: .path(["email", "smtp", "port"]),
        defaultValue: "587",
        dependsOn: "smtpHost"
      ),
      since,
    ],
    secret: WorkspaceSourceSecret(
      label: "Password",
      environmentVariable: "ORG2_EMAIL_PASSWORD",
      help: "Enter the IMAP password or app password. Celorga stores it in macOS Keychain and passes it only to the email sync; it is never written to the corpus."
    ),
    defaultSyncArgs: []
  )
}

extension WorkspaceSourceCatalog {
  public static let googleCalendar = WorkspaceSourceType(
    id: "google-calendar",
    displayName: "Google Calendar",
    systemImage: "calendar",
    summary: "Celorga reads your upcoming Google Calendar events (read-only) so it can offer to record meetings as they start and fill in their attendees. Sign in on this Mac; the connected server keeps the calendar synced.",
    defaultProfileID: "calendar",
    fields: [
      WorkspaceSourceField(
        id: "calendars",
        label: "Calendars",
        prompt: "primary, team@example.com",
        help: "Calendar IDs to read; primary is your main calendar.",
        kind: .list,
        target: .path(["googleCalendar", "calendars"]),
        defaultValue: "primary"
      ),
      WorkspaceSourceField(
        id: "lookaheadDays",
        label: "Days ahead",
        prompt: "14",
        help: "How many days of upcoming events to keep synced (1–90).",
        kind: .integer,
        target: .path(["googleCalendar", "lookaheadDays"]),
        defaultValue: "14"
      ),
      WorkspaceSourceField(
        id: "since",
        label: "Look back",
        prompt: "1d",
        help: "How far back to keep events, such as 1d.",
        target: .path(["ingestion", "since"]),
        defaultValue: "1d"
      ),
    ],
    secret: WorkspaceSourceSecret(
      label: "Google Sign-In",
      environmentVariable: "ORG2_GOOGLE_CALENDAR_CREDENTIAL",
      help: "Sign in with Google to grant read-only calendar access. Celorga keeps the sign-in in macOS Keychain, sends it to your connected server so the server can sync, and never writes it to the corpus.",
      signIn: .google(scope: googleCalendarScope)
    ),
    defaultSyncArgs: []
  )
}

extension WorkspaceSourceProfileStatus {
  public var sourceType: WorkspaceSourceType? { WorkspaceSourceCatalog.type(type) }

  /// The profile as the `externalSources` entry fields the form edits.
  var editableConfig: JSONValue {
    var config: [String: JSONValue] = ["type": .string(type)]
    if let workspaceId { config["workspaceId"] = .string(workspaceId) }
    if !scopes.isEmpty { config["scopes"] = .array(scopes.map(JSONValue.string)) }
    if !syncArgs.isEmpty { config["syncArgs"] = .array(syncArgs.map(JSONValue.string)) }
    if let ingestionSince { config["ingestion"] = .object(["since": .string(ingestionSince)]) }
    if let email {
      var account: [String: JSONValue] = [
        "host": .string(email.host),
        "port": .integer(Int64(email.port)),
        "security": .string(email.security),
        "username": .string(email.username),
        "mailboxes": .array(email.mailboxes.map(JSONValue.string)),
      ]
      if let smtp = email.smtp {
        account["smtp"] = .object(["host": .string(smtp.host), "port": .integer(Int64(smtp.port))])
      }
      config["email"] = .object(account)
    }
    if let googleCalendar {
      config["googleCalendar"] = .object([
        "calendars": .array(googleCalendar.calendars.map(JSONValue.string)),
        "lookaheadDays": .integer(Int64(googleCalendar.lookaheadDays)),
      ])
    }
    return .object(config)
  }
}

/// Form state for adding or editing any catalog source type.
public struct WorkspaceSourceDraft: Identifiable, Equatable, Sendable {
  public var typeID: String
  public var profileID: String
  public var values: [String: String]
  /// Entered secret; saved to Keychain, never encoded into the source entry.
  public var secret = ""
  /// Set when editing; the profile ID and type are then fixed.
  public private(set) var existingProfileID: String?
  private var existingSyncArgs: [String]?

  public var id: String { "\(existingProfileID ?? "new"):\(typeID)" }
  public var isEditing: Bool { existingProfileID != nil }
  public var sourceType: WorkspaceSourceType? { WorkspaceSourceCatalog.type(typeID) }

  public init(type: WorkspaceSourceType) {
    typeID = type.id
    profileID = type.defaultProfileID
    values = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.id, $0.defaultValue) })
  }

  public init?(editing profile: WorkspaceSourceProfileStatus) {
    guard let type = profile.sourceType else { return nil }
    self.init(type: type)
    profileID = profile.id
    existingProfileID = profile.id
    existingSyncArgs = profile.syncArgs
    let config = profile.editableConfig
    for field in type.fields {
      values[field.id] = Self.formValue(field, in: config) ?? (field.target == .syncSource ? field.defaultValue : "")
    }
  }

  public func value(_ fieldID: String) -> String { values[fieldID] ?? "" }

  /// Updates a field and applies the chosen option's linked defaults.
  public mutating func setValue(_ value: String, for fieldID: String) {
    let previous = self.value(fieldID)
    values[fieldID] = value
    guard let field = sourceType?.field(fieldID), case .choice(let choices) = field.kind,
          let previousChoice = choices.first(where: { $0.value == previous }),
          let choice = choices.first(where: { $0.value == value })
    else { return }
    for (linked, newDefault) in choice.linkedDefaults where self.value(linked) == previousChoice.linkedDefaults[linked] {
      values[linked] = newDefault
    }
  }

  public func isVisible(_ field: WorkspaceSourceField) -> Bool {
    guard let dependency = field.dependsOn else { return true }
    return !trimmed(dependency).isEmpty
  }

  /// The first problem that prevents saving, or `nil` when the form is valid.
  public var validationMessage: String? {
    guard let type = sourceType else { return "Unsupported source type." }
    let id = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) == nil {
      return "Use letters, digits, dots, dashes, or underscores for the source name."
    }
    for field in type.fields where isVisible(field) {
      let text = trimmed(field.id)
      if field.isRequired, text.isEmpty { return "Enter \(field.label.lowercased())." }
      if case .integer = field.kind, !text.isEmpty {
        guard let number = Int(text), (1...65_535).contains(number) else { return "\(field.label) must be a number from 1 to 65535." }
      }
      if case .choice(let choices) = field.kind, !text.isEmpty, !choices.contains(where: { $0.value == text }) {
        return "Choose a \(field.label.lowercased())."
      }
    }
    return nil
  }

  /// The `externalSources` entry for `org2 source add`. When editing, cleared
  /// optional values become `null` so the runtime removes them.
  public func sourceConfig() throws -> JSONValue {
    guard let type = sourceType else { throw WorkspaceSourceScheduleDraft.ValidationError("Unsupported source type.") }
    if let validationMessage { throw WorkspaceSourceScheduleDraft.ValidationError(validationMessage) }
    var config: [String: JSONValue] = isEditing ? [:] : ["type": .string(type.id), "enabled": .bool(true)]
    var syncArgs = existingSyncArgs ?? type.defaultSyncArgs
    var touchesSyncArgs = !isEditing && !type.defaultSyncArgs.isEmpty
    for field in type.fields {
      let text = trimmed(field.id)
      switch field.target {
      case .syncSource:
        guard !text.isEmpty else { continue }
        if let index = syncArgs.firstIndex(of: "--source"), index + 1 < syncArgs.count {
          if syncArgs[index + 1] != text { syncArgs[index + 1] = text; touchesSyncArgs = true }
        } else {
          syncArgs = ["--source", text] + syncArgs
          touchesSyncArgs = true
        }
      case .path(let path):
        let value: JSONValue?
        if !isVisible(field) || text.isEmpty {
          value = isEditing && !Self.wholeObjectKeys.contains(path[0]) ? .null : nil
        } else {
          switch field.kind {
          case .integer: value = .integer(Int64(text) ?? 0)
          case .list:
            let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            value = items.isEmpty ? (isEditing && !Self.wholeObjectKeys.contains(path[0]) ? .null : nil) : .array(items.map(JSONValue.string))
          case .text, .choice: value = .string(text)
          }
        }
        if let value { Self.set(value, at: path, in: &config) }
      }
    }
    if touchesSyncArgs { config["syncArgs"] = .array(syncArgs.map(JSONValue.string)) }
    return .object(config)
  }

  /// `org2 source add` arguments. The secret is never an argument.
  public func arguments(corpusRoot: String) throws -> [String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(try sourceConfig()), as: UTF8.self)
    var arguments = ["source", "add", profileID.trimmingCharacters(in: .whitespacesAndNewlines), "--source-json", json]
    if isEditing { arguments.append("--update") }
    return arguments + ["--dir", corpusRoot, "--apply", "--json"]
  }

  /// Nested settings the form always sends as a whole object, so a cleared
  /// field is omitted rather than sent as `null`.
  static let wholeObjectKeys: Set<String> = ["email", "googleCalendar"]

  private func trimmed(_ fieldID: String) -> String {
    value(fieldID).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func set(_ value: JSONValue, at path: [String], in object: inout [String: JSONValue]) {
    guard let key = path.first else { return }
    if path.count == 1 {
      object[key] = value
      return
    }
    var child = object[key]?.objectValue ?? [:]
    set(value, at: Array(path.dropFirst()), in: &child)
    object[key] = .object(child)
  }

  private static func formValue(_ field: WorkspaceSourceField, in config: JSONValue) -> String? {
    switch field.target {
    case .syncSource:
      guard let args = config["syncArgs"]?.arrayValue?.compactMap(\.stringValue),
            let index = args.firstIndex(of: "--source"), index + 1 < args.count
      else { return nil }
      return args[index + 1]
    case .path(let path):
      var current: JSONValue? = config
      for key in path { current = current?[key] }
      switch current {
      case .string(let value): return value
      case .integer(let value): return String(value)
      case .array(let items): return items.compactMap(\.stringValue).joined(separator: ", ")
      default: return nil
      }
    }
  }
}
