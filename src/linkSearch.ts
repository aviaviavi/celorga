// Org link search options: `file:PATH::SEARCH` and, since Org 10,
// `id:ID::SEARCH`. This module is the single TypeScript definition of how
// Celorga splits those targets and resolves the search part. It must stay
// free of Node APIs because the mobile JavaScriptCore runtime imports it.

export type IdLinkTarget = { id: string; search?: string };

/** Splits `id:ID` or `id:ID::SEARCH`; returns null for any other target. */
export function parseIdLinkTarget(raw: string | null | undefined): IdLinkTarget | null {
  const value = String(raw ?? "").trim();
  if (!/^id:/i.test(value)) return null;
  const body = value.slice(3);
  const separator = body.indexOf("::");
  const id = (separator < 0 ? body : body.slice(0, separator)).trim();
  if (!id) return null;
  const search = separator < 0 ? "" : body.slice(separator + 2).trim();
  return search ? { id, search } : { id };
}

/** The lowercased ID an `id:` target points at, ignoring any search option. */
export function idLinkTargetId(raw: string | null | undefined): string | null {
  return parseIdLinkTarget(raw)?.id.toLowerCase() ?? null;
}

/** The raw `::SEARCH` suffix of an `id:` target, or "" when it has none. */
export function idLinkSearchSuffix(raw: string | null | undefined): string {
  const value = String(raw ?? "").trim();
  if (!/^id:/i.test(value)) return "";
  const separator = value.indexOf("::");
  return separator < 0 ? "" : value.slice(separator);
}

export const UUID_ID_PATTERN = /^[0-9a-f-]{36}$/i;

/** True for `id:UUID` and `id:UUID::SEARCH`, the shape corpus indexes treat as stable links. */
export function isUuidIdLinkTarget(raw: string | null | undefined): boolean {
  const parsed = parseIdLinkTarget(raw);
  return !!parsed && UUID_ID_PATTERN.test(parsed.id);
}

export type OrgSearchOptionKind = "line" | "heading" | "custom-id" | "target" | "name" | "text";
/** `line` is 1-based. */
export type OrgSearchOptionMatch = { line: number; kind: OrgSearchOptionKind };
/** 1-based, inclusive line range. */
export type OrgLineRange = { startLine: number; endLine: number };

function toLines(text: string | string[]): string[] {
  return Array.isArray(text) ? text : String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
}

function normalizeSearchText(value: string): string {
  return value
    .replace(/\[\d*\/\d*\]|\[\d*%\]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

/**
 * A heading matches when its title equals `wanted` after removing tags, an
 * optional priority, and statistics cookies. A leading upper-case word may be
 * a TODO keyword from any workflow, so the title also matches without it.
 */
function headingMatches(line: string, wanted: string): boolean {
  if (!/^\*+\s+/.test(line)) return false;
  const base = line.trim().replace(/^\*+\s+/, "").replace(/\s+:[^\s:]+(?::[^\s:]+)*:\s*$/, "").trim();
  const candidates = [base];
  const keyword = /^[A-Z][A-Z0-9_-]*\s+(.+)$/.exec(base);
  if (keyword) candidates.push(keyword[1]!);
  return candidates.some((candidate) => normalizeSearchText(candidate.replace(/^\[#[A-Za-z0-9]\]\s+/, "")) === wanted);
}

function headingLevel(line: string): number {
  const match = /^(\*+)\s/.exec(line);
  return match ? match[1]!.length : 0;
}

/**
 * The subtree that starts at the 1-based `headingLine`: the heading and every
 * line before the next heading of the same or a higher level.
 */
export function orgSubtreeLineRange(text: string | string[], headingLine: number): OrgLineRange {
  const lines = toLines(text);
  const start = Math.max(1, Math.min(headingLine, lines.length));
  const level = headingLevel(lines[start - 1] ?? "");
  if (!level) return { startLine: 1, endLine: lines.length };
  let end = lines.length;
  for (let i = start; i < lines.length; i += 1) {
    const other = headingLevel(lines[i] ?? "");
    if (other && other <= level) {
      end = i;
      break;
    }
  }
  return { startLine: start, endLine: end };
}

function findInRange(
  lines: string[],
  range: OrgLineRange,
  test: (line: string, inBlock: boolean) => boolean,
): number | null {
  let inBlock = false;
  for (let i = range.startLine - 1; i < range.endLine && i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const trimmed = line.trim();
    if (/^#\+begin_/i.test(trimmed)) {
      inBlock = true;
      continue;
    }
    if (/^#\+end_/i.test(trimmed)) {
      inBlock = false;
      continue;
    }
    if (test(line, inBlock)) return i + 1;
  }
  return null;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Resolves an Org search option against a file, Celorga-style:
 *
 * - `42` is a 1-based line of the file (never scoped).
 * - `*Heading` matches a heading title (TODO keyword, priority, tags and
 *   statistics cookies ignored; case-insensitive).
 * - `#custom-id` matches a `:CUSTOM_ID:` property line.
 * - Plain text matches a dedicated target `<<text>>`, then a `#+NAME:`,
 *   then a heading title (all case-insensitive), then the first line
 *   containing the text.
 *
 * When `scope` is given, non-numeric searches look inside it first and then
 * fall back to the whole file.
 */
export function resolveOrgSearchOption(
  text: string | string[],
  rawSearch: string,
  options: { scope?: OrgLineRange } = {},
): OrgSearchOptionMatch | null {
  const lines = toLines(text);
  const search = String(rawSearch ?? "").trim();
  if (!search || lines.length === 0) return null;

  if (/^\d+$/.test(search)) {
    const line = Number.parseInt(search, 10);
    if (!Number.isFinite(line) || line < 1) return null;
    return { line: Math.min(line, lines.length), kind: "line" };
  }

  const whole: OrgLineRange = { startLine: 1, endLine: lines.length };
  const ranges = options.scope ? [options.scope, whole] : [whole];
  const first = (test: (line: string, inBlock: boolean) => boolean): number | null => {
    for (const range of ranges) {
      const found = findInRange(lines, range, test);
      if (found !== null) return found;
    }
    return null;
  };

  if (search.startsWith("*")) {
    const wanted = normalizeSearchText(search.replace(/^\*+\s*/, ""));
    if (!wanted) return null;
    const line = first((candidate) => headingMatches(candidate, wanted));
    return line === null ? null : { line, kind: "heading" };
  }

  if (search.startsWith("#")) {
    const wanted = search.slice(1).trim().toLowerCase();
    if (!wanted) return null;
    const line = first((candidate) => (/^\s*:CUSTOM_ID:\s*(\S+)\s*$/i.exec(candidate)?.[1] ?? "").toLowerCase() === wanted);
    return line === null ? null : { line, kind: "custom-id" };
  }

  const wanted = normalizeSearchText(search);
  const targetPattern = new RegExp(`<<<?\\s*${escapeRegExp(search.replace(/\s+/g, " ")).replace(/ /g, "\\s+")}\\s*>>>?`, "i");
  const targetLine = first((candidate, inBlock) => !inBlock && targetPattern.test(candidate));
  if (targetLine !== null) return { line: targetLine, kind: "target" };
  const nameLine = first((candidate) => normalizeSearchText(/^\s*#\+name:\s*(.*)$/i.exec(candidate)?.[1] ?? "\0") === wanted);
  if (nameLine !== null) return { line: nameLine, kind: "name" };
  const headingLine = first((candidate) => headingMatches(candidate, wanted));
  if (headingLine !== null) return { line: headingLine, kind: "heading" };
  const lowered = search.toLowerCase();
  const textLine = first((candidate) => candidate.toLowerCase().includes(lowered));
  return textLine === null ? null : { line: textLine, kind: "text" };
}

/**
 * The line that owns `id` in a file: the heading whose property drawer has
 * `:ID: id`, or line 1 for a file-level `:ID:` / `#+ID:`. Returns the owner
 * line and its subtree (the whole file for a file-level ID).
 */
export function findIdOwner(text: string | string[], rawId: string): { line: number; scope: OrgLineRange } | null {
  const lines = toLines(text);
  const id = String(rawId ?? "").trim().toLowerCase();
  if (!id) return null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const property = /^\s*:ID:\s*(\S+)\s*$/i.exec(line);
    const keyword = property ? null : /^\s*#\+ID:\s*(\S+)\s*$/i.exec(line);
    const match = property ?? keyword;
    if (!match || match[1]!.toLowerCase() !== id) continue;
    const heading = enclosingHeadingLine(lines, i + 1);
    if (heading === null) return { line: 1, scope: { startLine: 1, endLine: lines.length } };
    // `#+ID:` only identifies the file, and only before the first heading.
    if (keyword) continue;
    return { line: heading, scope: orgSubtreeLineRange(lines, heading) };
  }
  return null;
}

/**
 * Resolves `id:ID::SEARCH` inside the file that contains the ID. Searches
 * the ID's subtree first, then the rest of the file; a numeric search is a
 * file line. Without a search option this returns the ID owner line.
 */
export function resolveIdLinkInText(
  text: string | string[],
  target: string | IdLinkTarget,
): (OrgSearchOptionMatch & { ownerLine: number }) | null {
  const parsed = typeof target === "string" ? parseIdLinkTarget(target) : target;
  if (!parsed) return null;
  const lines = toLines(text);
  const owner = findIdOwner(lines, parsed.id);
  if (!owner) return null;
  if (!parsed.search) return { line: owner.line, kind: "heading", ownerLine: owner.line };
  const match = resolveOrgSearchOption(lines, parsed.search, { scope: owner.scope });
  return match ? { ...match, ownerLine: owner.line } : null;
}

/** The innermost heading that contains the 1-based `line`, or null before the first heading. */
export function enclosingHeadingLine(text: string | string[], line: number): number | null {
  const lines = toLines(text);
  for (let i = Math.min(line, lines.length) - 1; i >= 0; i -= 1) {
    if (headingLevel(lines[i] ?? "")) return i + 1;
  }
  return null;
}
