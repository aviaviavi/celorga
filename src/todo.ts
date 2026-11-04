import fs from "node:fs";
import path from "node:path";
import { findConfigFile, loadConfig } from "./config.js";
import { formatLocalOrgTimestamp } from "./calendarDate.js";
import {
  computeSubtreeRange,
  findDrawerInLines,
  findHeadingAtOrAbove,
  findPlanningBlockEnd,
  getDrawerPropertyValue,
  splitSourceLines,
  upsertHeadlinePropertyInLines,
} from "./sourceLines.js";

export type TodoStatus = "todo" | "in_progress" | "done" | "canceled";
export type TerminalTodoStatus = Extract<TodoStatus, "done" | "canceled">;

export const TODO_KEYWORDS = ["TODO", "IN_PROGRESS", "DONE", "CANCELED", "CANCELLED"] as const;

/** File-local Org workflows. The last state is terminal when no separator is given. */
export type TodoSequence = { keywords: string[]; terminal: string[] };
export function documentTodoSequences(input: string, defaults: readonly TodoSequence[] = []): TodoSequence[] {
  const sequences: TodoSequence[] = [];
  let block: string | undefined;
  let drawer = false;
  for (const line of input.split(/\r?\n/)) {
    const begin = /^\s*#\+begin_(\S+)/i.exec(line);
    if (begin && !block) { block = begin[1].toLowerCase(); continue; }
    if (block) {
      if (/^\s*#\+end_(\S+)\s*$/i.exec(line)?.[1].toLowerCase() === block) block = undefined;
      continue;
    }
    if (/^\s*:END:\s*$/i.test(line)) { drawer = false; continue; }
    if (/^\s*:[A-Za-z0-9_]+:\s*$/.test(line)) { drawer = true; continue; }
    if (drawer) continue;
    const match = /^\s*#\+(?:TODO|SEQ_TODO|TYP_TODO):\s*(.*)$/i.exec(line);
    if (!match) continue;
    const tokens = match[1].trim().split(/\s+/).map(token => token.replace(/\([^)]*\)$/, ""));
    const separator = tokens.indexOf("|");
    const keywords = tokens.filter(token => token !== "|" && /^[\p{L}][\p{L}\p{N}_-]*$/u.test(token));
    if (!keywords.length) continue;
    const terminal = separator < 0 ? keywords.slice(-1) : tokens.slice(separator + 1).filter(token => keywords.includes(token));
    sequences.push({ keywords: [...new Set(keywords)], terminal: [...new Set(terminal)] });
  }
  return sequences.length ? sequences : [...defaults];
}

export function documentTodoKeywords(input: string, defaults: readonly TodoSequence[] = []): string[] {
  return [...new Set([...TODO_KEYWORDS, ...documentTodoSequences(input, defaults).flatMap(sequence => sequence.keywords)])];
}

/** Validate portable corpus definitions using the same syntax as file declarations. */
export function parseTodoSequenceDefinitions(value: unknown): TodoSequence[] {
  if (!Array.isArray(value) || !value.every(item => typeof item === "string")) {
    throw new Error("todo.sequences must be an array of strings, such as [\"TODO WAITING | DONE CANCELED\"].");
  }
  const result: TodoSequence[] = [];
  const seen = new Set<string>();
  for (const definition of value) {
    const tokens = definition.trim().split(/\s+/);
    if (tokens.filter((token: string) => token === "|").length > 1 || tokens.some((token: string) => token !== "|" && !/^[\p{L}][\p{L}\p{N}_-]*(?:\([^\s()]*\))?$/u.test(token))) {
      throw new Error(`Invalid TODO sequence: ${definition}. Use space-separated keywords and one | before terminal states.`);
    }
    const sequence = documentTodoSequences(`#+TODO: ${definition}`)[0];
    if (!sequence || !sequence.terminal.length || sequence.terminal.length === sequence.keywords.length) {
      throw new Error("Each TODO sequence needs at least one active state and one terminal state.");
    }
    for (const token of tokens.filter((token: string) => token !== "|").map((token: string) => token.replace(/\([^)]*\)$/, ""))) {
      if (seen.has(token)) throw new Error(`TODO keyword ${token} appears more than once. Give each state one sequence.`);
      seen.add(token);
    }
    result.push(sequence);
  }
  return result;
}

export function todoSequencesForFile(filePath?: string, includeFileDeclarations = false): TodoSequence[] {
  if (!filePath) return [];
  const configPath = findConfigFile(path.dirname(path.resolve(filePath)));
  const value = configPath ? loadConfig(configPath).todo?.sequences : undefined;
  const defaults = value === undefined ? [] : parseTodoSequenceDefinitions(value);
  return includeFileDeclarations && fs.existsSync(filePath)
    ? documentTodoSequences(fs.readFileSync(filePath, "utf8"), defaults) : defaults;
}

export function todoConfigurationKey(filePath: string): string {
  return JSON.stringify(todoSequencesForFile(filePath));
}

export function todoKeywordInWorkflow(value: string | undefined, sequences: readonly TodoSequence[]): string | undefined {
  if (!value) return undefined;
  return sequences.flatMap(sequence => sequence.keywords).find(keyword => keyword === value)
    ?? normalizeTodoKeyword(value);
}

export type TodoKeyword = typeof TODO_KEYWORDS[number];

const TODO_KEYWORD_SET = new Set<string>(TODO_KEYWORDS);

export function isTodoKeyword(value: string | undefined): value is TodoKeyword {
  return typeof value === "string" && TODO_KEYWORD_SET.has(value);
}

export function normalizeTodoKeyword(value: string | undefined): TodoKeyword | undefined {
  const normalized = (value || "").trim().toUpperCase();
  return isTodoKeyword(normalized) ? normalized : undefined;
}

export function keywordFromStatus(status: TodoStatus, opts?: { canceledKeyword?: "CANCELED" | "CANCELLED" }): TodoKeyword {
  if (status === "todo") return "TODO";
  if (status === "in_progress") return "IN_PROGRESS";
  if (status === "done") return "DONE";
  return opts?.canceledKeyword === "CANCELLED" ? "CANCELLED" : "CANCELED";
}

export function statusFromKeyword(keyword: string | undefined, sequences: readonly TodoSequence[] = []): TodoStatus {
  const sequence = sequences.find(sequence => sequence.keywords.includes(keyword ?? ""));
  if (sequence) return sequence.terminal.includes(keyword!) ? (keyword!.toUpperCase().startsWith("CANCEL") ? "canceled" : "done") : (keyword === "IN_PROGRESS" ? "in_progress" : "todo");
  const k = (keyword || "").trim().toUpperCase();
  if (k === "IN_PROGRESS") return "in_progress";
  if (k === "DONE") return "done";
  if (k === "CANCELED" || k === "CANCELLED") return "canceled";
  return "todo";
}

export function terminalTodoStatusFromKeyword(keyword: string | null | undefined, sequences: readonly TodoSequence[] = []): TerminalTodoStatus | undefined {
  const status = statusFromKeyword(keyword ?? undefined, sequences);
  return status === "done" || status === "canceled" ? status : undefined;
}

export function isTerminalTodoKeyword(keyword: string | null | undefined, sequences: readonly TodoSequence[] = []): boolean {
  return terminalTodoStatusFromKeyword(keyword, sequences) !== undefined;
}

export function isActiveTodoKeyword(keyword: string | null | undefined, sequences: readonly TodoSequence[] = []): boolean {
  return Boolean(keyword) && !isTerminalTodoKeyword(keyword, sequences);
}

export function formatOrgTimestamp(now: Date): string {
  return formatLocalOrgTimestamp(now, { includeTime: true });
}

function parseHeadlineTodoKeyword(line: string, sequences: readonly TodoSequence[] = []): string | undefined {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return undefined;
  const rest = m[2];
  const first = rest.split(/\s+/)[0] || "";
  return todoKeywordInWorkflow(first, sequences);
}

function replaceOrInsertTodoKeyword(line: string, newKeyword: string, sequences: readonly TodoSequence[]): { line: string; oldKeyword?: string } {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return { line };
  const stars = m[1];
  const rest = m[2];
  const old = parseHeadlineTodoKeyword(line, sequences);

  if (old) {
    // Replace only the leading keyword.
    const replaced = newKeyword + rest.slice((rest.split(/\s+/)[0] || "").length);
    return { line: `${stars} ${replaced}`, oldKeyword: old };
  }

  // Insert keyword before title.
  return { line: `${stars} ${newKeyword} ${rest}`, oldKeyword: undefined };
}

function upsertClosedPlanning(lines: string[], headingIndex: number, endExclusive: number, closedAt: string): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  let firstClosedIndex = -1;

  for (let i = headingIndex + 1; i < planningEnd; i++) {
    if (!/^CLOSED:\s/.test(lines[i] ?? "")) continue;
    if (firstClosedIndex < 0) {
      firstClosedIndex = i;
      continue;
    }
    // Deduplicate stale duplicate CLOSED lines while preserving first position.
    lines.splice(i, 1);
    i--;
  }

  if (firstClosedIndex >= 0) {
    lines[firstClosedIndex] = `CLOSED: ${closedAt}`;
    return;
  }

  lines.splice(planningEnd, 0, `CLOSED: ${closedAt}`);
}

function removeClosedPlanning(lines: string[], headingIndex: number, endExclusive: number): void {
  const planningEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  for (let i = planningEnd - 1; i > headingIndex; i--) {
    if (/^CLOSED:\s/.test(lines[i] ?? "")) {
      lines.splice(i, 1);
    }
  }
}

function ensureLogbookDrawer(lines: string[], insertAt: number): { start: number; end: number } {
  lines.splice(insertAt, 0, ":LOGBOOK:", ":END:");
  return { start: insertAt, end: insertAt + 1 };
}

export type UpdateTodoResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  oldKeyword?: string;
  newKeyword: string;
  oldStatus: TodoStatus;
  newStatus: TodoStatus;
  closedAt?: string;
  changed: boolean;
  text: string;
};

export type UpdateTodoOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  status?: TodoStatus;
  keyword?: string;
  toggle?: boolean;
  now?: Date;
  logbook?: boolean;
};

export type AssignTodoResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  property: "ASSIGNEE";
  oldAssignee?: string;
  newAssignee: string;
  oldAgentRef?: string;
  newAgentRef?: string;
  oldGoalRef?: string;
  newGoalRef?: string;
  oldAgentStart?: string;
  newAgentStart?: string;
  changed: boolean;
  text: string;
};

export type AssignTodoOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  assignee: string;
  agentRef?: string;
  goalRef?: string;
  /** `scheduled` opts the heading into starting at its SCHEDULED time (`:AGENT_START:`). */
  agentStart?: string;
};

export function computeToggleStatus(current: TodoStatus): TodoStatus {
  // Cycle: todo -> in_progress -> done -> todo
  if (current === "todo") return "in_progress";
  if (current === "in_progress") return "done";
  // done or canceled -> todo
  return "todo";
}

export function updateTodoInText(input: string, opts: UpdateTodoOptions): UpdateTodoResult {
  const now = opts.now ?? new Date();
  const stamp = formatOrgTimestamp(now);
  const lines = splitSourceLines(input);

  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);

  const sequences = documentTodoSequences(input, todoSequencesForFile(opts.filePath));
  const oldKeyword = parseHeadlineTodoKeyword(lines[headingIndex] ?? "", sequences);
  const oldStatus = statusFromKeyword(oldKeyword, sequences);
  const sequence = sequences.find(sequence => sequence.keywords.includes(oldKeyword ?? ""));

  const canceledKeywordPreference = oldKeyword === "CANCELLED" ? "CANCELLED" : undefined;
  let newKeyword: string;
  if (opts.keyword) {
    const keyword = todoKeywordInWorkflow(opts.keyword, sequences);
    if (!keyword) throw new Error(`Unknown TODO keyword "${opts.keyword}". Declare it with #+TODO: active | terminal or in celorga.json todo.sequences.`);
    newKeyword = keyword;
  } else if (opts.toggle && sequence) {
    newKeyword = sequence.keywords[(sequence.keywords.indexOf(oldKeyword!) + 1) % sequence.keywords.length];
  } else {
    const target = opts.toggle ? computeToggleStatus(oldStatus) : opts.status;
    if (!target) throw new Error("Must provide either status, keyword, or toggle");
    newKeyword = keywordFromStatus(target, { canceledKeyword: canceledKeywordPreference });
  }
  const targetStatus = statusFromKeyword(newKeyword, sequences);

  const { line: newHeadlineLine } = replaceOrInsertTodoKeyword(lines[headingIndex] ?? "", newKeyword, sequences);
  const changed = newHeadlineLine !== (lines[headingIndex] ?? "");
  lines[headingIndex] = newHeadlineLine;

  const subtreeEndExclusive = (): number => computeSubtreeRange(lines, headingIndex).endExclusive;

  // Optionally write state transition logbook entries.
  if (oldKeyword ? oldKeyword !== newKeyword : oldStatus !== targetStatus) {
    // closedAt for done/canceled; reopening clears stale CLOSED metadata.
    let closedAt: string | undefined;
    if (targetStatus === "done" || targetStatus === "canceled") {
      closedAt = stamp;
      upsertClosedPlanning(lines, headingIndex, subtreeEndExclusive(), closedAt);
    } else {
      removeClosedPlanning(lines, headingIndex, subtreeEndExclusive());
    }

    // Figure insertion base after planning block and property drawer (if present).
    let endExclusive = subtreeEndExclusive();
    const afterPlanning = findPlanningBlockEnd(lines, headingIndex, endExclusive);
    let insertAfterProps = afterPlanning;

    const props = findDrawerInLines(lines, afterPlanning, endExclusive, "PROPERTIES");
    if (props && props.terminated) {
      insertAfterProps = props.end + 1;
    }

    if (opts.logbook) {
      // Prefer existing LOGBOOK drawer placement (even if it appears before PROPERTIES)
      // to avoid creating duplicate drawers during status transitions.
      const logbookSearchStart = afterPlanning;
      let logbook = findDrawerInLines(lines, logbookSearchStart, endExclusive, "LOGBOOK");
      if (!logbook || !logbook.terminated) {
        const created = ensureLogbookDrawer(lines, insertAfterProps);
        logbook = { start: created.start, end: created.end, terminated: true };
      }

      // Insert log entry before :END:
      // Find end again (may have shifted)
      endExclusive = subtreeEndExclusive();
      const log2 = findDrawerInLines(lines, logbookSearchStart, endExclusive, "LOGBOOK");
      if (log2 && log2.terminated) {
        const oldKeywordForLog =
          oldKeyword && statusFromKeyword(oldKeyword, sequences) === oldStatus
            ? oldKeyword
            : keywordFromStatus(oldStatus, {
                ...(canceledKeywordPreference ? { canceledKeyword: canceledKeywordPreference } : {}),
              });
        const entry = `- State \"${newKeyword}\" from \"${oldKeywordForLog}\" ${stamp}`;
        lines.splice(log2.end, 0, entry);
      }
    }

    return {
      filePath: opts.filePath,
      headingLineNumber: headingIndex + 1,
      oldKeyword,
      newKeyword,
      oldStatus,
      newStatus: targetStatus,
      ...(closedAt ? { closedAt } : {}),
      changed,
      text: lines.join("\n"),
    };
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    oldKeyword,
    newKeyword,
    oldStatus,
    newStatus: targetStatus,
    changed,
    text: lines.join("\n"),
  };
}

export function updateTodoInFile(opts: UpdateTodoOptions & { apply: boolean }): UpdateTodoResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = updateTodoInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}

export function assignTodoInText(input: string, opts: AssignTodoOptions): AssignTodoResult {
  const assignee = opts.assignee.trim();
  if (!assignee) throw new Error("Assignee cannot be empty");

  const lines = splitSourceLines(input);
  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);
  const endExclusive = computeSubtreeRange(lines, headingIndex).endExclusive;
  const afterPlanning = findPlanningBlockEnd(lines, headingIndex, endExclusive);

  const props = findDrawerInLines(lines, afterPlanning, endExclusive, "PROPERTIES");
  const oldAssignee = props ? getDrawerPropertyValue(lines, props, "ASSIGNEE") : undefined;
  const oldAgentRef = props ? getDrawerPropertyValue(lines, props, "AGENT_REF") : undefined;
  const oldGoalRef = props ? getDrawerPropertyValue(lines, props, "GOAL_REF") : undefined;
  const oldAgentStart = props ? getDrawerPropertyValue(lines, props, "AGENT_START") : undefined;
  const agentRef = opts.agentRef?.trim() || undefined;
  const goalRef = opts.goalRef?.trim() || undefined;
  const agentStart = opts.agentStart?.trim().toLowerCase() || undefined;
  if (agentStart && agentStart !== "scheduled") throw new Error("--start supports only 'scheduled'");
  const changed = oldAssignee !== assignee
    || (opts.agentRef !== undefined && oldAgentRef !== agentRef)
    || (opts.goalRef !== undefined && oldGoalRef !== goalRef)
    || (agentStart !== undefined && oldAgentStart !== agentStart);
  if (oldAssignee !== assignee) {
    upsertHeadlinePropertyInLines(lines, headingIndex, "ASSIGNEE", assignee);
  }
  if (agentRef && oldAgentRef !== agentRef) upsertHeadlinePropertyInLines(lines, headingIndex, "AGENT_REF", agentRef);
  if (goalRef && oldGoalRef !== goalRef) upsertHeadlinePropertyInLines(lines, headingIndex, "GOAL_REF", goalRef);
  if (agentStart && oldAgentStart !== agentStart) upsertHeadlinePropertyInLines(lines, headingIndex, "AGENT_START", agentStart);

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    property: "ASSIGNEE",
    ...(oldAssignee ? { oldAssignee } : {}),
    newAssignee: assignee,
    ...(oldAgentRef ? { oldAgentRef } : {}),
    ...(agentRef ? { newAgentRef: agentRef } : {}),
    ...(oldGoalRef ? { oldGoalRef } : {}),
    ...(goalRef ? { newGoalRef: goalRef } : {}),
    ...(oldAgentStart ? { oldAgentStart } : {}),
    ...(agentStart ? { newAgentStart: agentStart } : {}),
    changed,
    text: lines.join("\n"),
  };
}

export function assignTodoInFile(opts: AssignTodoOptions & { apply: boolean }): AssignTodoResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = assignTodoInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}
