import Foundation

/// The visible state of agent work attached to one heading. A heading is
/// linked to work by its `:ORG2_RUN_ID:` property (the durable run) and by its
/// `:ID:` (the canonical `id:` resource chat thread).
public enum HeadingWorkState: String, Sendable, Equatable, CaseIterable {
  /// The agent is producing a reply right now.
  case working
  /// The run is queued and not started.
  case queued
  /// The agent replied and the run is still open: your turn.
  case yourTurn = "your-turn"
  /// The run is blocked, waiting for approval, or failed validation.
  case needsYou = "needs-you"
  case failed
  case done

  public var label: String {
    switch self {
    case .working: "Working"
    case .queued: "Queued"
    case .yourTurn: "Your turn"
    case .needsYou: "Needs you"
    case .failed: "Failed"
    case .done: "Done"
    }
  }

  public var systemImage: String {
    switch self {
    case .working: "circle.dotted"
    case .queued: "clock"
    case .yourTurn: "arrowshape.turn.up.left"
    case .needsYou: "exclamationmark.circle"
    case .failed: "xmark.octagon"
    case .done: "checkmark.circle"
    }
  }

  /// Whether this state asks something of the user.
  public var needsAttention: Bool {
    self == .yourTurn || self == .needsYou || self == .failed
  }
}

public struct HeadingWorkBadge: Equatable, Sendable, Identifiable {
  public var id: Int { line }
  public let line: Int
  public let state: HeadingWorkState
  public let runID: String?
  public let threadID: UUID?

  public init(line: Int, state: HeadingWorkState, runID: String?, threadID: UUID?) {
    self.line = line
    self.state = state
    self.runID = runID
    self.threadID = threadID
  }
}

/// A heading's linkage properties, extracted from Org source without the
/// full parser. Only the heading line and its property drawer are read.
struct HeadingWorkLink: Equatable, Sendable {
  let line: Int
  let todo: String?
  let idValue: String?
  let runID: String?
  var agentRef: String? = nil
  var goalRef: String? = nil
}

struct StartWorkPromptSummary: Equatable, Sendable {
  let title: String
  let source: String?
  let runID: String?
}

enum HeadingWorkStatus {
  static let terminalTodoKeywords: Set<String> = ["DONE", "CANCELED", "CANCELLED"]
  static let openTodoKeywords: Set<String> = ["TODO", "NEXT", "IN_PROGRESS", "IN-PROGRESS", "WAITING", "HOLD", "STARTED"]

  /// Headings in `text` (whose first line is `baseLine`) with their TODO
  /// keyword, `:ID:`, and `:ORG2_RUN_ID:`.
  static func links(in text: String, baseLine: Int) -> [HeadingWorkLink] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [HeadingWorkLink] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      guard let depth = headingDepth(line) else { index += 1; continue }
      let afterStars = line.dropFirst(depth).drop(while: { $0 == " " })
      let firstWord = afterStars.split(separator: " ", maxSplits: 1).first.map(String.init)
      let todo = firstWord.flatMap { word in
        terminalTodoKeywords.contains(word) || openTodoKeywords.contains(word) ? word : nil
      }
      var idValue: String?
      var runID: String?
      var agentRef: String?
      var goalRef: String?
      var cursor = index + 1
      // Planning lines may precede the property drawer.
      while cursor < lines.count {
        let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.hasPrefix("SCHEDULED:") || trimmed.hasPrefix("DEADLINE:") || trimmed.hasPrefix("CLOSED:") {
          cursor += 1
        } else {
          break
        }
      }
      if cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" {
        cursor += 1
        while cursor < lines.count {
          let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
          if trimmed.uppercased() == ":END:" || headingDepth(lines[cursor]) != nil { break }
          if let (key, value) = property(trimmed) {
            switch key {
            case "ID": idValue = value
            case "CELORGA_RUN_ID": runID = value
            case "ORG2_RUN_ID": runID = runID ?? value
            case "AGENT_REF": agentRef = value
            case "GOAL_REF": goalRef = value
            default: break
            }
          }
          cursor += 1
        }
      }
      result.append(HeadingWorkLink(
        line: baseLine + index,
        todo: todo,
        idValue: idValue,
        runID: runID,
        agentRef: agentRef,
        goalRef: goalRef
      ))
      index += 1
    }
    return result
  }

  /// Derives each linked heading's badge. A heading with neither a run nor an
  /// active resource thread gets no badge.
  static func badges(
    links: [HeadingWorkLink],
    runsByID: [String: AgentRunItem],
    resourceThreadIDsByKey: [String: UUID],
    isThreadRunning: (UUID) -> Bool,
    threadIDForRun: (AgentRunItem) -> UUID? = { _ in nil }
  ) -> [HeadingWorkBadge] {
    links.compactMap { link in
      // Work started in an existing chat is not that heading's resource
      // thread; the run's "AI chat thread:" comment still links them.
      let threadID = link.idValue.flatMap { resourceThreadIDsByKey["id:\($0)"] }
        ?? link.runID.flatMap { runsByID[$0] }.flatMap(threadIDForRun)
      let threadRunning = threadID.map(isThreadRunning) ?? false
      guard let runID = link.runID else {
        // Without a durable run, show only live work in this heading's thread.
        return threadRunning
          ? HeadingWorkBadge(line: link.line, state: .working, runID: nil, threadID: threadID)
          : nil
      }
      guard let run = runsByID[runID] else {
        return threadRunning
          ? HeadingWorkBadge(line: link.line, state: .working, runID: runID, threadID: threadID)
          : nil
      }
      guard let state = state(for: run, threadRunning: threadRunning, hasThread: threadID != nil) else {
        return nil
      }
      return HeadingWorkBadge(line: link.line, state: state, runID: runID, threadID: threadID)
    }
  }

  static func state(for run: AgentRunItem, threadRunning: Bool, hasThread: Bool) -> HeadingWorkState? {
    if threadRunning { return .working }
    switch run.status.lowercased() {
    case "completed": return .done
    case "canceled", "cancelled": return nil
    case "failed": return .failed
    case "queued": return .queued
    case "blocked", "waiting-approval": return .needsYou
    default:
      if run.needsAttention || !run.actionablePendingApprovals.isEmpty { return .needsYou }
      // A running run whose chat is idle is waiting on the person.
      return hasThread ? .yourTurn : .working
    }
  }

  private static func headingDepth<S: StringProtocol>(_ line: S) -> Int? {
    var depth = 0
    for character in line {
      if character == "*" { depth += 1; continue }
      return depth > 0 && character == " " ? depth : nil
    }
    return nil
  }

  private static func property(_ trimmed: String) -> (String, String)? {
    guard trimmed.hasPrefix(":") else { return nil }
    let body = trimmed.dropFirst()
    guard let colon = body.firstIndex(of: ":") else { return nil }
    let key = body[..<colon].uppercased()
    let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !value.isEmpty else { return nil }
    return (key, value)
  }

  /// The first line of every Start work prompt. The transcript recognizes it
  /// to show the sent prompt as a compact card.
  static let startWorkPromptLead = "Start work on this TODO from my corpus."

  /// The task, source, and run named by a Start work prompt in `text`, or nil
  /// when `text` is not one.
  static func startWorkPromptSummary(in text: String) -> StartWorkPromptSummary? {
    guard text.contains(startWorkPromptLead) else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let lead = lines.firstIndex(of: startWorkPromptLead) else { return nil }
    func value(_ prefix: String) -> String? {
      lines[lead...].prefix(6).first(where: { $0.hasPrefix(prefix) })
        .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let title = value("Task:") else { return nil }
    return StartWorkPromptSummary(title: title, source: value("Source:"), runID: value("Durable run:"))
  }

  /// The prompt sent to the chat destination when work starts on a heading.
  static func startWorkPrompt(
    title: String,
    reference: String,
    runID: String,
    keepsCLIInstructions: Bool
  ) -> String {
    var lines = [
      startWorkPromptLead,
      "",
      "Task: \(title)",
      "Source: \(reference)",
      "Durable run: \(runID)",
      "",
      "Read the heading, its notes, and nearby context first. Then do the work. If the task is ambiguous, reply with a short plan and the specific questions you need answered instead of guessing.",
      "",
      "When you finish:",
      "- Add a short outcome note under the heading. Keep its :PROPERTIES: drawer, :ID:, and :ORG2_RUN_ID: intact.",
      "- Mark the heading DONE only if the task is actually complete.",
    ]
    if keepsCLIInstructions {
      lines.append("- If you can run the Celorga CLI, close the run with `celorga run complete \(runID) --summary \"…\"`, or `celorga run block \(runID) --reason \"…\"` when you need me.")
    }
    return lines.joined(separator: "\n")
  }
}

/// Rendered-document chrome for heading work: a hover "Start work" button on
/// open TODO headings, and an always-visible state badge on headings with
/// attached work. Injected by the app; the shared HTML export is unchanged.
enum OrgHTMLHeadingWorkScript {
  static let installation = """
  (() => {
    if (window.__org2HeadingWorkInstalled) return;
    window.__org2HeadingWorkInstalled = true;
    const style = document.createElement('style');
    style.textContent = `
      .org2-work-badge { display: inline-flex; align-items: center; gap: 0.3rem; margin-left: 0.45rem;
        padding: 0.1rem 0.42rem; border-radius: 999px; border: 0; font: inherit; font-size: 0.72rem;
        font-weight: 650; line-height: 1.3; vertical-align: middle; transform: translateY(-2px); cursor: pointer;
        color: var(--org2-muted); background: color-mix(in srgb, var(--org2-muted) 12%, transparent); }
      .org2-work-badge::before { content: ''; width: 0.42rem; height: 0.42rem; border-radius: 50%; background: currentColor; }
      .org2-work-badge.state-working { color: var(--org2-accent); background: color-mix(in srgb, var(--org2-accent) 12%, transparent); }
      .org2-work-badge.state-working::before { animation: org2-work-pulse 1.2s ease-in-out infinite; }
      .org2-work-badge.state-your-turn, .org2-work-badge.state-needs-you { color: var(--org2-warning); background: color-mix(in srgb, var(--org2-warning) 13%, transparent); }
      .org2-work-badge.state-failed { color: var(--org2-danger); background: color-mix(in srgb, var(--org2-danger) 11%, transparent); }
      .org2-work-badge.state-done { color: var(--org2-success); background: color-mix(in srgb, var(--org2-success) 11%, transparent); }
      .org2-work-badge:hover { filter: brightness(0.95); text-decoration: underline; }
      @keyframes org2-work-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }
      @media (prefers-reduced-motion: reduce) { .org2-work-badge.state-working::before { animation: none; } }`;
    document.documentElement.appendChild(style);
    const go = (url) => { window.location.href = url; };
    window.__org2InstallStartWork = (enabled) => {
      document.querySelectorAll('.org2-heading-start-work').forEach((node) => node.remove());
      if (!enabled) return;
      document.querySelectorAll('details.org2-headline[data-org2-start-line]').forEach((headline) => {
        const summary = headline.querySelector(':scope > .org2-headline-summary');
        if (!summary) return;
        const todo = summary.querySelector('.org2-todo');
        if (!todo || /todo-(done|canceled|cancelled)/.test(todo.className)) return;
        const line = headline.dataset.org2StartLine;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'org2-heading-ai-action org2-heading-start-work';
        button.textContent = '▶ Start work…';
        button.title = 'Start an agent run on this task and open its chat';
        button.setAttribute('aria-label', 'Start work on this task with AI');
        button.addEventListener('click', (event) => {
          event.preventDefault(); event.stopPropagation();
          go('org2-workspace://start-work?line=' + encodeURIComponent(line));
        });
        const ask = summary.querySelector(':scope > .org2-heading-ai-action:not(.org2-heading-start-work)');
        summary.insertBefore(button, ask || null);
      });
    };
    window.__org2SetWorkBadges = (badges) => {
      document.querySelectorAll('.org2-work-badge').forEach((node) => node.remove());
      document.querySelectorAll('.org2-heading-start-work').forEach((node) => { node.hidden = false; });
      for (const badge of badges || []) {
        const headline = document.querySelector('details.org2-headline[data-org2-start-line="' + badge.line + '"]');
        const summary = headline?.querySelector(':scope > .org2-headline-summary');
        if (!summary) continue;
        const heading = summary.querySelector(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6') || summary;
        const element = document.createElement('button');
        element.type = 'button';
        element.className = 'org2-work-badge state-' + badge.state;
        element.textContent = badge.label;
        element.title = badge.help;
        element.setAttribute('aria-label', badge.help);
        element.addEventListener('click', (event) => {
          event.preventDefault(); event.stopPropagation();
          go('org2-workspace://open-work?line=' + encodeURIComponent(badge.line));
        });
        heading.appendChild(element);
        const start = summary.querySelector(':scope > .org2-heading-start-work');
        if (start && badge.state !== 'done') start.hidden = true;
      }
    };
  })();
  """

  static func badgesPayload(_ badges: [HeadingWorkBadge]) -> String {
    let objects: [[String: Any]] = badges.map { badge in
      [
        "line": badge.line,
        "state": badge.state.rawValue,
        "label": badge.state.label,
        "help": help(for: badge.state),
      ]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8)
    else { return "[]" }
    return json
  }

  static func help(for state: HeadingWorkState) -> String {
    switch state {
    case .working: "An agent is working on this now. Click to open its chat."
    case .queued: "The run is queued. Click to open it."
    case .yourTurn: "The agent replied and is waiting for you. Click to open its chat."
    case .needsYou: "The run is blocked or waiting for approval. Click to open it."
    case .failed: "The run failed. Click to see what happened."
    case .done: "The run is complete. Click to open its chat."
    }
  }
}
