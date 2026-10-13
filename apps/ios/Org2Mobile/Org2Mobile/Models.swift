import Foundation

enum OrgTodoStatus: String, CaseIterable {
  case next = "NEXT"
  case todo = "TODO"
  case inProgress = "IN_PROGRESS"
  case prog = "PROG"
  case started = "STARTED"
  case doing = "DOING"
  case wait = "WAIT"
  case waiting = "WAITING"
  case hold = "HOLD"
  case paused = "PAUSED"
  case review = "REVIEW"
  case done = "DONE"
  case canceled = "CANCELED"
  case cancelled = "CANCELLED"

  var isTerminal: Bool {
    switch self {
    case .done, .canceled, .cancelled:
      true
    default:
      false
    }
  }

  static var agendaChoices: [OrgTodoStatus] {
    [.todo, .next, .inProgress, .wait, .hold, .review, .done, .canceled]
  }
}

struct OrgDocument: Identifiable, Hashable {
  let id: String
  let url: URL
  let relativePath: String
  let title: String
  let properties: [String: String]
  let body: String
  let nodes: [OrgNode]
}

struct CorpusFile: Identifiable, Hashable, Codable, Sendable {
  let relativePath: String
  let modifiedAt: Date?
  let byteCount: Int64?

  var id: String { relativePath }
  var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
}

struct CorpusFilePreview: Hashable, Sendable {
  let title: String
  let relativePath: String
  let startLine: Int
  let highlightedLine: Int?
  let content: String
}

struct OrgNode: Identifiable, Hashable {
  let id: String
  let title: String
  let todo: String?
  let level: Int
  let line: Int
  let tags: [String]
  let properties: [String: String]
  let planning: [OrgPlanningDate]
  let body: String
  let documentPath: String
}

struct OrgPlanningDate: Identifiable, Hashable {
  let kind: OrgPlanningKind
  let date: String

  var id: String { "\(kind.rawValue):\(date)" }
}

enum OrgPlanningKind: String, Hashable, Codable {
  case scheduled = "Scheduled"
  case deadline = "Deadline"
  case timestamp = "Timestamp"
}

struct AgendaEntry: Identifiable, Hashable, Codable {
  let id: String
  let title: String
  let todo: String
  let file: String
  let line: Int
  let date: String
  let kind: OrgPlanningKind
  let tags: [String]
  let body: String

  var isOverdue: Bool {
    date < Date.org2TodayString
  }
}

struct ApprovalEntry: Identifiable, Hashable, Codable {
  let id: String
  let title: String
  let status: String
  let todo: String?
  let level: Int?
  let file: String
  let line: Int?
  let sourceID: String?
  let properties: [String: String]
  let body: String
  let tags: [String]
  let kind: String?
  let runID: String?
  let approvalID: String?
  let fingerprint: String?
  let action: String?
  let riskClass: String?
  /// Who asked, for example the requesting agent. Absent for local corpus approvals.
  var requestedFrom: String? = nil
  var requestedAt: String? = nil

  var isRunApproval: Bool {
    kind == "run" && runID != nil && approvalID != nil
  }

  var sourceLabel: String {
    if let runID {
      return "Run \(runID)"
    }
    if let line {
      return "\(file):\(line)"
    } else {
      return file
    }
  }

  var whatsappText: String {
    """
    OpenClaw approval thread:

    \(title)
    Source: \(sourceLabel)
    Status: \(status)
    \(runID.map { "Run: \($0)" } ?? "")
    \(approvalID.map { "Approval: \($0)" } ?? "")
    \(fingerprint.map { "Fingerprint: \($0)" } ?? "")

    \(body.trimmedForDisplay(maxCharacters: 900))
    """
  }
}

enum AIChatApprovalAction: String {
  case discuss
  case decide

  var title: String {
    switch self {
    case .discuss:
      "Discuss"
    case .decide:
      "Decide"
    }
  }
}

extension String {
  func trimmedForDisplay(maxCharacters: Int = 280) -> String {
    let compact = prettyPrintedOrgLinks()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  func prettyPrintedOrgLinks() -> String {
    let pattern = #"\[\[([^\]\[]+)\](?:\[([^\]\[]*)\])?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
    let nsRange = NSRange(startIndex..<endIndex, in: self)
    let matches = regex.matches(in: self, range: nsRange).reversed()
    var result = self

    for match in matches {
      guard let matchRange = Range(match.range(at: 0), in: result),
            let targetRange = Range(match.range(at: 1), in: result) else {
        continue
      }
      let target = String(result[targetRange])
      let description: String?
      if match.range(at: 2).location != NSNotFound, let descriptionRange = Range(match.range(at: 2), in: result) {
        description = String(result[descriptionRange])
      } else {
        description = nil
      }

      let replacement = description?.isEmpty == false ? description! : target.prettyOrgLinkTarget()
      result.replaceSubrange(matchRange, with: replacement)
    }

    return result
  }

  private func prettyOrgLinkTarget() -> String {
    for prefix in ["id:", "file:", "attachment:"] {
      if lowercased().hasPrefix(prefix) {
        return String(dropFirst(prefix.count))
      }
    }
    return self
  }
}

extension Date {
  static var org2TodayString: String {
    MobileCaptureWriter.orgDayString(Date())
  }

  static let org2DayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
