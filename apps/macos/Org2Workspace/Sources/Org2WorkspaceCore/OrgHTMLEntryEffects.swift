import Foundation

/// An immediate, provisional change to one heading in the rendered document.
///
/// Heading mutations (TODO state, priority, planning, archive) write through
/// the CLI and then re-render the document, which takes a noticeable moment.
/// The store emits an effect as soon as the user acts so the rendered view
/// reflects the change at once, with a short animation. The authoritative
/// re-render then replaces the page; a failed mutation restores the last
/// authoritative render.
struct OrgHTMLEntryEffect: Equatable, Sendable {
  enum Change: Equatable, Sendable {
    /// `closedTimestamp` is shown on a finished heading until the re-render
    /// supplies the real CLOSED line.
    case todo(keyword: String, state: OrgTodoVisualState, closedTimestamp: String)
    /// The keyword is predicted from the rendered heading when it follows the
    /// built-in TODO, IN_PROGRESS, DONE cycle; otherwise the heading only
    /// shows that it is updating.
    case toggleTodo(closedTimestamp: String)
    case priority(String?)
    case planning(kind: PlanningEditKind, timestamp: String)
    case remove
    /// The mutation succeeded: drop any "updating" treatment.
    case settle
    /// The mutation failed: restore the last authoritative render.
    case revert
  }

  let id: UInt64
  let file: String
  let line: Int
  let change: Change

  /// Effects that play an animation. A re-render that arrives while one is
  /// running waits for it to finish instead of cutting it off.
  var isAnimated: Bool {
    switch change {
    case .todo, .toggleTodo, .priority, .planning, .remove: true
    case .settle, .revert: false
    }
  }

  static func todoChange(for status: TodoEditStatus, now: Date = Date()) -> Change {
    let state: OrgTodoVisualState = switch status {
    case .done: .done
    case .canceled: .canceled
    case .todo, .inProgress: .open
    }
    return .todo(keyword: status.label, state: state, closedTimestamp: closedTimestamp(now))
  }

  /// Matches the CLI's CLOSED stamp, for example `<2026-11-03 Tue 13:36>`.
  static func closedTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }

  /// Matches `celorga plan set --date YYYY-MM-DD`, for example
  /// `<2026-11-09 Mon>`. Returns the bare date in brackets if it is not a
  /// valid calendar date.
  static func planningTimestamp(date: String) -> String {
    let parser = DateFormatter()
    parser.calendar = Calendar(identifier: .gregorian)
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone.current
    parser.dateFormat = "yyyy-MM-dd"
    guard let parsed = parser.date(from: date) else { return "<\(date)>" }
    let weekday = DateFormatter()
    weekday.calendar = parser.calendar
    weekday.locale = parser.locale
    weekday.timeZone = parser.timeZone
    weekday.dateFormat = "EEE"
    return "<\(date) \(weekday.string(from: parsed))>"
  }

  /// The payload passed to `window.__org2ApplyEntryEffect`. Nil for effects
  /// handled natively (`revert` reloads the last render).
  var scriptPayload: [String: Any]? {
    var payload: [String: Any] = ["line": line]
    switch change {
    case .todo(let keyword, let state, let closedTimestamp):
      payload["kind"] = "todo"
      payload["keyword"] = keyword
      payload["state"] = Self.stateName(state)
      payload["closed"] = closedTimestamp
    case .toggleTodo(let closedTimestamp):
      payload["kind"] = "toggle"
      payload["closed"] = closedTimestamp
    case .priority(let priority):
      payload["kind"] = "priority"
      payload["priority"] = priority ?? ""
    case .planning(let kind, let timestamp):
      payload["kind"] = "planning"
      payload["planning"] = kind.rawValue.uppercased()
      payload["timestamp"] = timestamp
    case .remove:
      payload["kind"] = "remove"
    case .settle:
      payload["kind"] = "settle"
    case .revert:
      return nil
    }
    return payload
  }

  private static func stateName(_ state: OrgTodoVisualState) -> String {
    switch state {
    case .open: "open"
    case .done: "done"
    case .canceled: "canceled"
    }
  }
}

enum OrgHTMLEntryEffectScript {
  /// How long the longest effect animation runs, in seconds.
  static let animationDuration: TimeInterval = 0.9

  static func invocation(for effect: OrgHTMLEntryEffect) -> String? {
    guard let payload = effect.scriptPayload,
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8)
    else { return nil }
    return installation + "\nwindow.__org2ApplyEntryEffect(\(json));"
  }

  static let stylesheet = """
  .org2-effect-host { position: relative; }
  .org2-effect-host, .org2-effect-host > .org2-todo, .org2-effect-host > .org2-priority {
    transition: color 320ms ease, background-color 320ms ease, opacity 320ms ease;
  }
  .org2-effect-pop { animation: org2-effect-pop 460ms cubic-bezier(.2, .8, .25, 1.25); }
  @keyframes org2-effect-pop {
    0% { transform: scale(1); }
    30% { transform: scale(1.28); }
    60% { transform: scale(.94); }
    100% { transform: scale(1); }
  }
  .org2-effect-burst { position: absolute; width: 0; height: 0; pointer-events: none; z-index: 2; }
  .org2-effect-ring {
    position: absolute; left: -14px; top: -14px; width: 28px; height: 28px;
    border-radius: 50%; border: 2px solid var(--org2-success, #2f9e5b); opacity: 0;
    animation: org2-effect-ring 520ms ease-out forwards;
  }
  @keyframes org2-effect-ring {
    0% { transform: scale(.3); opacity: .85; }
    100% { transform: scale(1.6); opacity: 0; }
  }
  .org2-effect-dot {
    position: absolute; left: -2.5px; top: -2.5px; width: 5px; height: 5px;
    border-radius: 50%; background: var(--org2-success, #2f9e5b); opacity: 0;
    animation: org2-effect-dot 560ms cubic-bezier(.15, .7, .3, 1) forwards;
  }
  @keyframes org2-effect-dot {
    0% { transform: translate(0, 0) scale(1); opacity: 1; }
    70% { opacity: .9; }
    100% { transform: translate(var(--org2-dx), var(--org2-dy)) scale(.4); opacity: 0; }
  }
  .org2-effect-sweep {
    position: absolute; height: 2px; border-radius: 1px; pointer-events: none;
    transform-origin: left center; transform: scaleX(0);
    animation: org2-effect-sweep 620ms cubic-bezier(.4, 0, .2, 1) forwards;
  }
  @keyframes org2-effect-sweep {
    0% { transform: scaleX(0); opacity: .95; }
    55% { transform: scaleX(1); opacity: .95; }
    100% { transform: scaleX(1); opacity: 0; }
  }
  .org2-effect-flash { animation: org2-effect-flash 900ms ease-out; border-radius: 4px; }
  @keyframes org2-effect-flash {
    0% { background-color: color-mix(in srgb, var(--org2-accent, #3b82f6) 22%, transparent); }
    100% { background-color: transparent; }
  }
  .org2-effect-pending > summary { animation: org2-effect-pending 1.1s ease-in-out infinite; }
  @keyframes org2-effect-pending { 0%, 100% { opacity: 1; } 50% { opacity: .5; } }
  .org2-effect-removing { overflow: hidden; transition: height 280ms ease, opacity 220ms ease, margin 280ms ease; }
  @media (prefers-reduced-motion: reduce) {
    .org2-effect-pop, .org2-effect-ring, .org2-effect-dot, .org2-effect-sweep,
    .org2-effect-flash, .org2-effect-pending > summary { animation: none !important; }
    .org2-effect-burst, .org2-effect-sweep { display: none; }
  }
  """

  /// Idempotent; defines `window.__org2ApplyEntryEffect(payload)`.
  static let installation = """
  (() => {
    if (window.__org2EntryEffectsInstalled) return;
    window.__org2EntryEffectsInstalled = true;
    const style = document.createElement('style');
    style.setAttribute('data-org2-entry-effects', '');
    style.textContent = \(jsStringLiteral(stylesheet));
    (document.head || document.documentElement).appendChild(style);

    const reduceMotion = () => !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    const later = (ms, fn) => setTimeout(fn, ms);
    const restart = (el, cls) => { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); };
    const entryAt = (line) => document.querySelector(
      `details.org2-headline[data-org2-start-line="${line}"], section.org2-headline[data-org2-start-line="${line}"]`
    );
    const headingOf = (entry) => entry && entry.querySelector(
      ':scope > summary > :is(h1, h2, h3, h4, h5, h6), :scope > :is(h1, h2, h3, h4, h5, h6)'
    );
    const todoClass = (keyword) => 'todo-' + keyword.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
    const isFinished = (h) => h.classList.contains('org2-headline-done') || h.classList.contains('org2-headline-canceled');
    const host = (h) => { h.classList.add('org2-effect-host'); void h.offsetWidth; };
    const releaseHost = (h, ms) => later(ms, () => {
      h.classList.remove('org2-effect-host');
      h.querySelectorAll('.org2-effect-pop').forEach((el) => el.classList.remove('org2-effect-pop'));
      if (!h.getAttribute('class')) h.removeAttribute('class');
    });

    const setHeadingState = (h, state) => {
      h.classList.remove('org2-headline-done', 'org2-headline-canceled');
      if (state === 'done') h.classList.add('org2-headline-done');
      if (state === 'canceled') h.classList.add('org2-headline-canceled');
      if (!h.getAttribute('class')) h.removeAttribute('class');
    };

    // Rendered headings read: [number] [TODO] [priority] [COMMENT] title [tags],
    // each prefix followed by a single space that leads the next text node.
    const ensureChip = (h) => {
      let chip = h.querySelector(':scope > .org2-todo');
      if (chip) return chip;
      chip = document.createElement('span');
      chip.className = 'org2-todo';
      const number = h.querySelector(':scope > .org2-headline-number');
      if (number) number.after(' ', chip); else h.prepend(chip, ' ');
      return chip;
    };

    const body = (entry, create) => {
      let element = entry.querySelector(':scope > .org2-headline-body');
      if (!element && create) {
        element = document.createElement('div');
        element.className = 'org2-headline-body';
        const summary = entry.querySelector(':scope > summary');
        if (summary) summary.after(element); else entry.append(element);
      }
      return element;
    };
    const planningLines = (entry) => {
      const element = body(entry, false);
      return element ? Array.from(element.querySelectorAll(':scope > p.org2-planning')) : [];
    };
    const planningKind = (p) => (p.querySelector('.org2-planning-kind')?.textContent || '').trim().toUpperCase();
    const setPlanning = (entry, kind, timestamp, animate) => {
      const lines = planningLines(entry);
      let p = lines.find((line) => planningKind(line) === kind);
      if (!p) {
        p = document.createElement('p');
        p.className = 'org2-planning';
        const last = lines[lines.length - 1];
        if (last) last.after(p); else body(entry, true).prepend(p);
      }
      const label = document.createElement('span');
      label.className = 'org2-planning-kind';
      label.textContent = kind;
      p.replaceChildren(label, ' ' + timestamp);
      if (animate) {
        restart(p, 'org2-effect-flash');
        later(950, () => p.classList.remove('org2-effect-flash'));
      }
    };
    const removePlanning = (entry, kind) => {
      planningLines(entry).filter((line) => planningKind(line) === kind).forEach((line) => line.remove());
      const element = body(entry, false);
      if (element && !element.children.length && !element.textContent.trim()) element.remove();
    };

    const titleLines = (h) => {
      const range = document.createRange();
      const prefixes = h.querySelectorAll(
        ':scope > .org2-headline-number, :scope > .org2-todo, :scope > .org2-priority, :scope > .org2-comment-keyword'
      );
      const lastPrefix = prefixes[prefixes.length - 1];
      const first = lastPrefix ? lastPrefix.nextSibling : h.firstChild;
      if (first && first.nodeType === Node.TEXT_NODE) {
        // Start the line at the title's first letter, not the separating space.
        range.setStart(first, Math.min(first.textContent.length - first.textContent.trimStart().length, first.textContent.length));
      } else if (lastPrefix) {
        range.setStartAfter(lastPrefix);
      } else {
        range.setStart(h, 0);
      }
      const tags = h.querySelector(':scope > .org2-tags');
      if (tags) range.setEndBefore(tags); else range.setEnd(h, h.childNodes.length);
      const origin = h.getBoundingClientRect();
      const lines = [];
      for (const rect of Array.from(range.getClientRects())) {
        if (rect.width < 2 || rect.height < 2) continue;
        const r = { left: rect.left - origin.left, top: rect.top - origin.top, width: rect.width, height: rect.height };
        const line = lines.find((l) => Math.abs((l.top + l.height / 2) - (r.top + r.height / 2)) < Math.min(l.height, r.height) / 2);
        if (line) {
          const right = Math.max(line.left + line.width, r.left + r.width);
          line.left = Math.min(line.left, r.left);
          line.width = right - line.left;
          line.top = Math.min(line.top, r.top);
          line.height = Math.max(line.height, r.height);
        } else {
          lines.push(r);
        }
      }
      return lines;
    };
    const sweep = (h, color) => {
      titleLines(h).forEach((line, index) => {
        const bar = document.createElement('span');
        bar.className = 'org2-effect-sweep';
        bar.setAttribute('aria-hidden', 'true');
        bar.style.left = line.left + 'px';
        bar.style.top = (line.top + line.height / 2 - 1) + 'px';
        bar.style.width = line.width + 'px';
        bar.style.background = color;
        bar.style.animationDelay = (80 + index * 120) + 'ms';
        h.append(bar);
        later(800 + index * 120, () => bar.remove());
      });
    };
    const burst = (h, chip) => {
      const origin = h.getBoundingClientRect();
      const rect = chip.getBoundingClientRect();
      const container = document.createElement('span');
      container.className = 'org2-effect-burst';
      container.setAttribute('aria-hidden', 'true');
      container.style.left = (rect.left - origin.left + rect.width / 2) + 'px';
      container.style.top = (rect.top - origin.top + rect.height / 2) + 'px';
      const ring = document.createElement('span');
      ring.className = 'org2-effect-ring';
      container.append(ring);
      const count = 10;
      for (let index = 0; index < count; index += 1) {
        const dot = document.createElement('span');
        dot.className = 'org2-effect-dot';
        const angle = (index / count) * Math.PI * 2 + (Math.random() - 0.5) * 0.35;
        const distance = Math.max(rect.width / 2, 10) + 8 + Math.random() * 10;
        dot.style.setProperty('--org2-dx', (Math.cos(angle) * distance).toFixed(1) + 'px');
        dot.style.setProperty('--org2-dy', (Math.sin(angle) * distance).toFixed(1) + 'px');
        dot.style.animationDelay = Math.round(Math.random() * 40) + 'ms';
        container.append(dot);
      }
      h.append(container);
      later(800, () => container.remove());
    };

    const applyTodo = (entry, h, keyword, state, closed, animate) => {
      const wasFinished = isFinished(h);
      if (animate) host(h);
      const chip = ensureChip(h);
      chip.textContent = keyword;
      chip.className = 'org2-todo ' + todoClass(keyword);
      if (state === 'open') removePlanning(entry, 'CLOSED');
      else if (!wasFinished || !planningLines(entry).some((line) => planningKind(line) === 'CLOSED')) setPlanning(entry, 'CLOSED', closed, false);
      if (!animate) { setHeadingState(h, state); return; }
      restart(chip, 'org2-effect-pop');
      if (state === 'done' && !wasFinished) {
        burst(h, chip);
        sweep(h, 'var(--org2-success, #2f9e5b)');
        later(260, () => setHeadingState(h, state));
      } else if (state === 'canceled' && !h.classList.contains('org2-headline-canceled')) {
        sweep(h, 'var(--org2-muted, #8a8a8a)');
        later(320, () => setHeadingState(h, state));
      } else {
        setHeadingState(h, state);
      }
      releaseHost(h, 900);
    };

    // Mirrors `celorga todo toggle` for the built-in keywords:
    // TODO -> IN_PROGRESS -> DONE -> TODO, and CANCELED -> TODO.
    const predictToggle = (h) => {
      const keyword = (h.querySelector(':scope > .org2-todo')?.textContent || '').trim().toUpperCase();
      if (keyword === 'TODO') return ['IN_PROGRESS', 'open'];
      if (keyword === 'IN_PROGRESS') return ['DONE', 'done'];
      if (keyword === 'DONE' || keyword === 'CANCELED' || keyword === 'CANCELLED') return ['TODO', 'open'];
      return null;
    };

    const applyPriority = (h, priority, animate) => {
      let span = h.querySelector(':scope > .org2-priority');
      if (!priority) {
        if (!span) return;
        const next = span.nextSibling;
        if (next && next.nodeType === Node.TEXT_NODE && next.textContent.startsWith(' ')) next.textContent = next.textContent.slice(1);
        const previous = span.previousSibling;
        span.remove();
        if (previous && previous.nodeType === Node.TEXT_NODE && previous.textContent === ' ' && !previous.previousSibling) previous.remove();
        return;
      }
      if (!span) {
        span = document.createElement('span');
        span.className = 'org2-priority';
        const before = h.querySelector(':scope > .org2-todo') || h.querySelector(':scope > .org2-headline-number');
        if (before) before.after(' ', span); else h.prepend(span, ' ');
      }
      if (animate) host(h);
      span.textContent = '[#' + priority + ']';
      if (animate) { restart(span, 'org2-effect-pop'); releaseHost(h, 600); }
    };

    const removeEntry = (entry, animate) => {
      if (!animate) { entry.style.display = 'none'; return; }
      const height = entry.getBoundingClientRect().height;
      entry.style.height = height + 'px';
      entry.classList.add('org2-effect-removing');
      void entry.offsetHeight;
      entry.style.height = '0px';
      entry.style.opacity = '0';
      entry.style.marginTop = '0px';
      entry.style.marginBottom = '0px';
      later(320, () => { entry.style.display = 'none'; });
    };

    window.__org2ApplyEntryEffect = (payload) => {
      const entry = entryAt(payload.line);
      if (!entry) return false;
      const h = headingOf(entry);
      const animate = !reduceMotion();
      entry.classList.remove('org2-effect-pending');
      switch (payload.kind) {
        case 'todo':
          if (!h) return false;
          applyTodo(entry, h, payload.keyword, payload.state, payload.closed, animate);
          return true;
        case 'toggle': {
          const predicted = h && predictToggle(h);
          if (!predicted) { entry.classList.add('org2-effect-pending'); return true; }
          applyTodo(entry, h, predicted[0], predicted[1], payload.closed, animate);
          return true;
        }
        case 'priority':
          if (!h) return false;
          applyPriority(h, payload.priority, animate);
          return true;
        case 'planning':
          setPlanning(entry, payload.planning, payload.timestamp, animate);
          return true;
        case 'remove':
          removeEntry(entry, animate);
          return true;
        case 'settle':
          return true;
        default:
          return false;
      }
    };
  })();
  """

  private static func jsStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let array = String(data: data, encoding: .utf8)
    else { return "''" }
    return String(array.dropFirst().dropLast())
  }
}

extension WorkspaceStore {
  /// The rendered document keeps only the most recent effects; it applies
  /// those newer than the last one it saw.
  static let renderedEntryEffectHistoryLimit = 16

  func emitRenderedEntryEffect(_ change: OrgHTMLEntryEffect.Change, file: String, line: Int) {
    renderedEntryEffectCounter &+= 1
    renderedEntryEffects.append(OrgHTMLEntryEffect(
      id: renderedEntryEffectCounter,
      file: file,
      line: line,
      change: change
    ))
    let overflow = renderedEntryEffects.count - Self.renderedEntryEffectHistoryLimit
    if overflow > 0 {
      renderedEntryEffects.removeFirst(overflow)
    }
  }
}
