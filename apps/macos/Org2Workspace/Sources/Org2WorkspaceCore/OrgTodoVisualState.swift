import Foundation

/// How strongly a heading's TODO state should read on screen, following
/// Emacs Org: open keywords use the `org-todo` face, finished ones the
/// `org-done` face, and a finished heading's title is softened
/// (`org-headline-done`). Celorga additionally greys out and strikes through
/// canceled headings so they recede further than completed work.
enum OrgTodoVisualState: Equatable, Sendable {
  case open
  case done
  case canceled

  /// Classifies a heading keyword. Returns nil when the heading has no TODO
  /// keyword. Custom terminal keywords from `#+TODO:` sequences read as done.
  static func classify(_ keyword: String?, sequences: [Org2TodoSequence] = []) -> OrgTodoVisualState? {
    guard let keyword = keyword?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty else {
      return nil
    }
    let normalized = keyword.uppercased()
    if normalized == "CANCELED" || normalized == "CANCELLED" {
      return .canceled
    }
    if normalized == "DONE" {
      return .done
    }
    if sequences.contains(where: { sequence in
      sequence.terminal.contains { $0.uppercased() == normalized }
    }) {
      return .done
    }
    return .open
  }

  /// Opacity applied to a heading title in this state.
  var titleOpacity: Double {
    switch self {
    case .open: 1
    case .done: 0.62
    case .canceled: 0.45
    }
  }

  var strikesThroughTitle: Bool { self == .canceled }
}
