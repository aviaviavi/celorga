import { documentTodoKeywords, documentTodoSequences, type TodoSequence } from "./todo.js";

export type PriorityConfig = {
  kind: "letter" | "number";
  highest: string;
  lowest: string;
  default: string;
  /** 1-based line of the `#+PRIORITIES:` keyword that set this range, when present. */
  line?: number;
};

export type PriorityLintRule =
  | "priority-out-of-range"
  | "priority-cookie-invalid"
  | "priority-cookie-malformed"
  | "priority-config-invalid";

export type PriorityLintIssue = {
  rule: PriorityLintRule;
  severity: "warning";
  /** 1-based line and column; `endColumn` is exclusive. */
  line: number;
  column: number;
  endColumn: number;
  message: string;
};

export const DEFAULT_PRIORITY_CONFIG: PriorityConfig = { kind: "letter", highest: "A", lowest: "C", default: "B" };

const PRIORITIES_KEYWORD_RE = /^\s*#\+PRIORITIES:\s*(.*?)\s*$/i;
const BLOCK_BEGIN_RE = /^\s*#\+begin_(\S+)/i;
const BLOCK_END_RE = /^\s*#\+end_(\S+)\s*$/i;

function priorityRank(value: string, kind: PriorityConfig["kind"]): number {
  return kind === "number" ? Number.parseInt(value, 10) : value.charCodeAt(0);
}

function isLiteralBlockLine(lines: string[]): boolean[] {
  const literal: boolean[] = [];
  let block: string | undefined;
  for (const line of lines) {
    if (block) {
      literal.push(true);
      if (BLOCK_END_RE.exec(line)?.[1].toLowerCase() === block) block = undefined;
      continue;
    }
    const begin = BLOCK_BEGIN_RE.exec(line);
    if (begin) block = begin[1].toLowerCase();
    literal.push(Boolean(begin));
  }
  return literal;
}

function parsePriorityKeyword(raw: string): PriorityConfig | string {
  const tokens = raw.split(/\s+/).filter(Boolean);
  if (tokens.length !== 3) return "expected three values: highest, lowest, and default (for example A C B)";
  const [highest, lowest, fallback] = tokens as [string, string, string];
  const kind = tokens.every((token) => /^\d+$/.test(token)) ? "number"
    : tokens.every((token) => /^[A-Z]$/.test(token)) ? "letter" : undefined;
  if (!kind) return "values must all be single uppercase letters or all be whole numbers";
  const config: PriorityConfig = { kind, highest, lowest, default: fallback };
  const hi = priorityRank(highest, kind);
  const lo = priorityRank(lowest, kind);
  const def = priorityRank(fallback, kind);
  if (hi > lo) return `highest priority ${highest} must come before lowest priority ${lowest}`;
  if (def < hi || def > lo) return `default priority ${fallback} must be between ${highest} and ${lowest}`;
  return config;
}

/** Reads the file's first `#+PRIORITIES: HIGHEST LOWEST DEFAULT` keyword outside blocks; Org's A–C (default B) otherwise. */
export function parsePriorityConfig(text: string): { config: PriorityConfig; issues: PriorityLintIssue[] } {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const literal = isLiteralBlockLine(lines);
  for (let i = 0; i < lines.length; i += 1) {
    if (literal[i]) continue;
    const match = PRIORITIES_KEYWORD_RE.exec(lines[i] ?? "");
    if (!match) continue;
    const parsed = parsePriorityKeyword(match[1] ?? "");
    if (typeof parsed !== "string") return { config: { ...parsed, line: i + 1 }, issues: [] };
    const line = lines[i] ?? "";
    return {
      config: DEFAULT_PRIORITY_CONFIG,
      issues: [{
        rule: "priority-config-invalid",
        severity: "warning",
        line: i + 1,
        column: 1,
        endColumn: line.length + 1,
        message: `#+PRIORITIES is invalid: ${parsed}. Using the default range A–C.`,
      }],
    };
  }
  return { config: DEFAULT_PRIORITY_CONFIG, issues: [] };
}

function rangeLabel(config: PriorityConfig): string {
  const source = config.line ? `#+PRIORITIES on line ${config.line}` : "the default range";
  return `${config.highest}–${config.lowest} (${source})`;
}

/**
 * Lints headline priority cookies: values outside the file's priority range,
 * invalid cookies such as `[#-1]` or `[#AA]`, and unterminated ones such as
 * `[#A`. Cookies are recognized where the parser reads them: at the start of
 * the headline title, after any TODO keyword.
 */
export function lintPriorityCookies(text: string, options: { todoSequences?: readonly TodoSequence[] } = {}): PriorityLintIssue[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const { config, issues } = parsePriorityConfig(text);
  const keywords = documentTodoKeywords("", options.todoSequences ?? documentTodoSequences(text));
  const literal = isLiteralBlockLine(lines);

  for (let i = 0; i < lines.length; i += 1) {
    if (literal[i]) continue;
    const line = lines[i] ?? "";
    const headline = /^(\*+ )(.*)$/.exec(line);
    if (!headline) continue;
    let offset = headline[1]!.length;
    let rest = headline[2] ?? "";
    const skip = (count: number) => {
      const trimmed = rest.slice(count).replace(/^\s+/, "");
      offset += rest.length - trimmed.length;
      rest = trimmed;
    };
    // Mirrors the parser: a leading COMMENT marker ends headline metadata.
    if (rest === "COMMENT" || rest.startsWith("COMMENT ")) continue;
    const keyword = keywords.find((kw) => rest.startsWith(`${kw} `));
    if (keyword) skip(keyword.length);
    if (!rest.startsWith("[#")) continue;

    const column = offset + 1;
    const closed = /^\[#([^\]\s]*)\](?=\s|$)/.exec(rest);
    if (!closed) {
      const token = /^\[#[^\]\s]*(?=\s|$)/.exec(rest)?.[0];
      if (!token) continue;
      issues.push({
        rule: "priority-cookie-malformed",
        severity: "warning",
        line: i + 1,
        column,
        endColumn: column + token.length,
        message: `Priority cookie '${token}' is not closed; write it as [#${config.highest}] through [#${config.lowest}] followed by a space.`,
      });
      continue;
    }
    const value = closed[1] ?? "";
    const endColumn = column + closed[0].length;
    if (!/^[A-Za-z0-9]$/.test(value)) {
      issues.push({
        rule: "priority-cookie-invalid",
        severity: "warning",
        line: i + 1,
        column,
        endColumn,
        message: `'${closed[0]}' is not a priority cookie; use one letter or digit in ${rangeLabel(config)}.`,
      });
      continue;
    }
    const valueKind = /^\d$/.test(value) ? "number" : "letter";
    const rank = priorityRank(value, valueKind);
    const inRange = valueKind === config.kind
      && rank >= priorityRank(config.highest, config.kind)
      && rank <= priorityRank(config.lowest, config.kind);
    if (inRange) continue;
    const hint = valueKind === "letter" && value !== value.toUpperCase() && config.kind === "letter"
      ? ` Priorities are uppercase; did you mean [#${value.toUpperCase()}]?` : "";
    issues.push({
      rule: "priority-out-of-range",
      severity: "warning",
      line: i + 1,
      column,
      endColumn,
      message: `Priority [#${value}] is outside ${rangeLabel(config)}.${hint}`,
    });
  }

  return issues.sort((a, b) => a.line - b.line || a.column - b.column);
}
