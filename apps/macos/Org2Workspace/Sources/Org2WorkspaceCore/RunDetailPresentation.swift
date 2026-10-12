import Foundation

/// Visual state of one plan step in the run detail's step track.
enum RunStepVisualState: Equatable, Sendable {
  case done
  case current
  case waitingOnYou
  case failed
  case blocked
  case skipped
  case upcoming

  var label: String {
    switch self {
    case .done: "Done"
    case .current: "In progress"
    case .waitingOnYou: "Waiting on you"
    case .failed: "Failed"
    case .blocked: "Blocked"
    case .skipped: "Skipped"
    case .upcoming: "Up next"
    }
  }

  var symbol: String {
    switch self {
    case .done: "checkmark"
    case .current: "circle.fill"
    case .waitingOnYou: "hand.raised.fill"
    case .failed: "xmark"
    case .blocked: "exclamationmark"
    case .skipped: "minus"
    case .upcoming: "circle"
    }
  }
}

/// Coarse tone used for risk, review, and check badges. Views map tones to
/// theme colors so this stays testable without SwiftUI.
enum RunDetailTone: Equatable, Sendable {
  case positive
  case neutral
  case caution
  case critical
}

struct RunRiskPresentation: Equatable, Sendable {
  let label: String
  let detail: String
  let symbol: String
  let tone: RunDetailTone
}

struct RunBadgePresentation: Equatable, Sendable {
  let text: String
  let symbol: String
  let tone: RunDetailTone
}

/// Pure presentation rules for the Agent Work run detail. Every function is
/// O(steps) or cheaper so the detail pane stays fast for very large runs.
enum RunDetailPresentation {
  /// Plans up to this length render as a horizontal step track; longer plans
  /// use a segmented bar plus the paged vertical list.
  static let maxTrackSteps = 7
  /// Segmented progress bars collapse into one continuous bar beyond this.
  static let maxProgressSegments = 12

  static func usesStepTrack(stepCount: Int) -> Bool {
    (2...maxTrackSteps).contains(stepCount)
  }

  static func stepState(
    _ step: AgentRunStepItem,
    hasPendingApproval: Bool
  ) -> RunStepVisualState {
    switch step.status {
    case "completed": return .done
    case "failed": return .failed
    case "blocked": return .blocked
    case "skipped": return .skipped
    case "running", "waiting-approval":
      if step.kind == "approval" && (hasPendingApproval || step.status == "waiting-approval") {
        return .waitingOnYou
      }
      return .current
    default:
      return .upcoming
    }
  }

  static func finishedStepCount(_ plan: [AgentRunStepItem]) -> Int {
    plan.reduce(0) { $0 + ($1.status == "completed" || $1.status == "skipped" ? 1 : 0) }
  }

  static func progressFraction(_ plan: [AgentRunStepItem]) -> Double {
    guard !plan.isEmpty else { return 0 }
    return Double(finishedStepCount(plan)) / Double(plan.count)
  }

  static func progressValue(_ plan: [AgentRunStepItem]) -> String {
    guard !plan.isEmpty else { return "No plan" }
    return "\(finishedStepCount(plan)) of \(plan.count) step\(plan.count == 1 ? "" : "s")"
  }

  /// The step a reader should look at now: the first one that is not done.
  static func focusStep(
    _ plan: [AgentRunStepItem],
    hasPendingApproval: Bool
  ) -> (step: AgentRunStepItem, state: RunStepVisualState)? {
    for step in plan {
      let state = stepState(step, hasPendingApproval: hasPendingApproval)
      if state != .done && state != .skipped { return (step, state) }
    }
    return nil
  }

  static func risk(_ riskClass: String) -> RunRiskPresentation {
    switch riskClass {
    case "read-only":
      return RunRiskPresentation(label: "Read only", detail: "Can't change anything", symbol: "eye", tone: .positive)
    case "local-draft":
      return RunRiskPresentation(label: "Local draft", detail: "Drafts stay in your notes", symbol: "pencil.and.outline", tone: .positive)
    case "canonical-write":
      return RunRiskPresentation(label: "Edits notes", detail: "Changes canonical files", symbol: "square.and.pencil", tone: .neutral)
    case "external-action":
      return RunRiskPresentation(label: "External action", detail: "Acts outside Celorga", symbol: "arrow.up.forward.app", tone: .caution)
    case "high-impact":
      return RunRiskPresentation(label: "High impact", detail: "Wide or irreversible", symbol: "exclamationmark.shield", tone: .critical)
    default:
      return RunRiskPresentation(
        label: AgentRunItem.humanizedLabel(riskClass.isEmpty ? "unspecified" : riskClass),
        detail: "Risk class",
        symbol: "shield",
        tone: .neutral
      )
    }
  }

  static func agentName(assignee: String?, provider: String?, destinationTitle: String?) -> String {
    for candidate in [assignee, destinationTitle, provider.map(AgentRunItem.humanizedLabel)] {
      if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    return "Unassigned"
  }

  static func agentDetail(model: String?, provider: String?) -> String {
    if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty, model != "configured-agent" {
      return model
    }
    return "Default model"
  }

  /// Active time between start and finish (or the latest update for open
  /// runs). Deliberately not relative to "now", so an idle run waiting on a
  /// person does not appear to be working for weeks.
  static func elapsedText(start: String?, end: String?) -> String? {
    guard let start, let end,
          let startDate = AgentRunTimestampPresentation.date(from: start),
          let endDate = AgentRunTimestampPresentation.date(from: end) else { return nil }
    let seconds = max(0, Int(endDate.timeIntervalSince(startDate)))
    if seconds < 60 { return seconds == 0 ? "Just started" : "\(seconds) sec" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    if hours < 24 {
      let remainder = minutes % 60
      return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
    let days = hours / 24
    return "\(days) day\(days == 1 ? "" : "s")"
  }

  /// A count line for the decision card. One lone approval needs no count.
  static func approvalCountText(pending: Int, total: Int) -> String? {
    guard pending > 0, total > 1 else { return nil }
    return "\(pending) of \(total) need\(pending == 1 ? "s" : "") a decision"
  }

  static func reviewBadge(_ reviewStatus: String?, runFinished: Bool) -> RunBadgePresentation? {
    switch reviewStatus {
    case "review-required":
      return runFinished
        ? RunBadgePresentation(text: "Review was pending", symbol: "clock.badge.exclamationmark", tone: .neutral)
        : RunBadgePresentation(text: "Needs review", symbol: "eye", tone: .caution)
    case "accepted", "approved", "reviewed", "promoted":
      return RunBadgePresentation(text: "Reviewed", symbol: "checkmark.seal.fill", tone: .positive)
    case "rejected":
      return RunBadgePresentation(text: "Rejected", symbol: "xmark.seal", tone: .critical)
    default:
      return nil
    }
  }

  static func checkBadge(_ status: String) -> RunBadgePresentation {
    switch status {
    case "passed": RunBadgePresentation(text: "Passed", symbol: "checkmark.seal.fill", tone: .positive)
    case "failed": RunBadgePresentation(text: "Failed", symbol: "xmark.octagon.fill", tone: .critical)
    case "warning": RunBadgePresentation(text: "Warning", symbol: "exclamationmark.triangle.fill", tone: .caution)
    case "skipped": RunBadgePresentation(text: "Skipped", symbol: "minus.circle", tone: .neutral)
    default: RunBadgePresentation(text: AgentRunItem.humanizedLabel(status), symbol: "circle.dashed", tone: .neutral)
    }
  }

  static func artifactSymbol(role: String, mediaType: String?, path: String) -> String {
    if role == "export" { return "square.and.arrow.up" }
    let lowered = path.lowercased()
    if mediaType?.hasPrefix("image/") == true
      || [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"].contains(where: lowered.hasSuffix) {
      return "photo"
    }
    if lowered.hasSuffix(".pdf") { return "doc.richtext" }
    if [".csv", ".parquet", ".json", ".tsv"].contains(where: lowered.hasSuffix) { return "tablecells" }
    if role == "report" { return "doc.text.image" }
    return "doc.text"
  }

  static func fileName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  static func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    let letters = words.prefix(2).compactMap(\.first)
    return letters.isEmpty ? "?" : String(letters).uppercased()
  }
}
