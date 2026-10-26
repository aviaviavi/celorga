import fs from "node:fs";
import { formatOrgDateTimestamp } from "./calendarDate.js";
import { computeSubtreeRange, findHeadingAtOrAbove, findPlanningBlockEnd, splitSourceLines } from "./sourceLines.js";

export type PlanningKind = "SCHEDULED" | "DEADLINE";

export type PlanningKindArg = "scheduled" | "deadline";

export function planningKindFromArg(kind: PlanningKindArg): PlanningKind {
  if (kind === "deadline") return "DEADLINE";
  return "SCHEDULED";
}

function formatPlanningDateTimestamp(dateIso: string): string {
  // Format like <2026-01-17 Sat>
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateIso)) {
    throw new Error(`Invalid --date (expected YYYY-MM-DD): ${dateIso}`);
  }

  const timestamp = formatOrgDateTimestamp(dateIso);
  if (!timestamp) {
    throw new Error(`Invalid --date: ${dateIso}`);
  }
  return timestamp;
}

function replacePlanningTokenInLine(line: string, kind: PlanningKind, timestamp: string): string {
  // Supports either dedicated planning lines or shared lines like:
  // "SCHEDULED: <...> DEADLINE: <...>"
  // We replace only the token for `kind`, preserving the rest.

  const tokenRe = new RegExp(`\\b${kind}:\\s+<[^>]*>`, "i");
  if (tokenRe.test(line)) {
    return line.replace(tokenRe, `${kind}: ${timestamp}`);
  }

  // If the line contains `${kind}:` but not a recognized <...> timestamp, do a looser replacement.
  const looseRe = new RegExp(`\\b${kind}:\\s*[^\n]*?(?=(\\s+(SCHEDULED|DEADLINE|CLOSED):)|$)`, "i");
  if (looseRe.test(line)) {
    return line.replace(looseRe, `${kind}: ${timestamp}`);
  }

  // Otherwise append at the end (keep it on the same line).
  return line.trimEnd() + (line.trimEnd().length ? " " : "") + `${kind}: ${timestamp}`;
}

export type UpdatePlanningResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  kind: PlanningKind;
  date: string; // YYYY-MM-DD
  changed: boolean;
  text: string;
};

export type UpdatePlanningOptions = {
  filePath: string;
  lineNumber: number; // 1-based cursor line
  kind: PlanningKind;
  date: string; // YYYY-MM-DD
};

export function updatePlanningInText(input: string, opts: UpdatePlanningOptions): UpdatePlanningResult {
  const lines = splitSourceLines(input);
  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);

  const { endExclusive } = computeSubtreeRange(lines, headingIndex);

  const timestamp = formatPlanningDateTimestamp(opts.date);

  // Planning lines (if present) are expected to appear immediately after the headline.
  // We'll update the first planning line that mentions the target kind; otherwise insert
  // a new planning line at the end of the planning block.

  const planStart = headingIndex + 1;
  const planEnd = findPlanningBlockEnd(lines, headingIndex, endExclusive);

  let changed = false;

  // Search within planning block.
  for (let i = planStart; i < planEnd; i++) {
    const line = lines[i] ?? "";
    if (new RegExp(`\\b${opts.kind}:`, "i").test(line)) {
      const updated = replacePlanningTokenInLine(line, opts.kind, timestamp);
      if (updated !== line) {
        lines[i] = updated;
        changed = true;
      }
      return {
        filePath: opts.filePath,
        headingLineNumber: headingIndex + 1,
        kind: opts.kind,
        date: opts.date,
        changed,
        text: lines.join("\n"),
      };
    }
  }

  // No existing token.
  if (planEnd === planStart) {
    // No planning lines; insert immediately after headline.
    lines.splice(planStart, 0, `${opts.kind}: ${timestamp}`);
    changed = true;
  } else {
    // Planning block exists, but doesn't include this kind; append to last planning line.
    const lastIdx = planEnd - 1;
    const before = lines[lastIdx] ?? "";
    const updated = replacePlanningTokenInLine(before, opts.kind, timestamp);
    if (updated !== before) {
      lines[lastIdx] = updated;
      changed = true;
    }
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    kind: opts.kind,
    date: opts.date,
    changed,
    text: lines.join("\n"),
  };
}

export function updatePlanningInFile(opts: UpdatePlanningOptions & { apply: boolean }): UpdatePlanningResult {
  const raw = fs.readFileSync(opts.filePath, "utf8");
  const res = updatePlanningInText(raw, opts);
  if (opts.apply) {
    fs.writeFileSync(opts.filePath, res.text, "utf8");
  }
  return res;
}

export type CancelledRepeater = {
  line: number; // 1-based
  repeater: string;
  before: string;
  after: string;
};

export type CancelRepeatersResult = {
  filePath: string;
  headingLineNumber: number; // 1-based
  changed: boolean;
  cancelled: CancelledRepeater[];
  text: string;
};

const ACTIVE_TIMESTAMP_RE = /<(\d{4}-\d{2}-\d{2}(?:[^<>\n]*?))>/g;
const REPEATER_COOKIE_RE = /\s+(?:\+\+|\.\+|\+)\d+[hdwmy](?:\/\d+[hdwmy])?(?=\s|$)/gi;
const LITERAL_BLOCK_BEGIN_RE = /^\s*#\+begin_(src|example|export)\b/i;

export function stripTimestampRepeaters(timestampBody: string): { body: string; removed: string[] } {
  const removed: string[] = [];
  const body = timestampBody.replace(REPEATER_COOKIE_RE, (match) => {
    removed.push(match.trim());
    return "";
  });
  return { body, removed };
}

// Removes repeater cookies (including habit `/N` parts) from every active
// timestamp in the entry at `lineNumber`: the headline, planning lines, and
// body text up to the next headline. Dates, times, and warning delays stay.
export function cancelRepeatersInText(input: string, opts: { filePath: string; lineNumber: number }): CancelRepeatersResult {
  const lines = splitSourceLines(input);
  const headingIndex = findHeadingAtOrAbove(lines, opts.lineNumber);
  const cancelled: CancelledRepeater[] = [];
  let literalBlockEnd: RegExp | null = null;

  for (let i = headingIndex; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (i > headingIndex && /^\*+\s+/.test(line)) break;
    if (literalBlockEnd) {
      if (literalBlockEnd.test(line)) literalBlockEnd = null;
      continue;
    }
    const begin = LITERAL_BLOCK_BEGIN_RE.exec(line);
    if (begin) {
      literalBlockEnd = new RegExp(`^\\s*#\\+end_${begin[1]}\\b`, "i");
      continue;
    }
    const removedOnLine: string[] = [];
    const updated = line.replace(ACTIVE_TIMESTAMP_RE, (whole, body: string) => {
      const stripped = stripTimestampRepeaters(body);
      if (!stripped.removed.length) return whole;
      removedOnLine.push(...stripped.removed);
      return `<${stripped.body}>`;
    });
    if (updated !== line) {
      lines[i] = updated;
      for (const repeater of removedOnLine) cancelled.push({ line: i + 1, repeater, before: line, after: updated });
    }
  }

  return {
    filePath: opts.filePath,
    headingLineNumber: headingIndex + 1,
    changed: cancelled.length > 0,
    cancelled,
    text: lines.join("\n"),
  };
}
