export const DATETREE_LEVELS = ["year", "quarter", "month", "week", "day"] as const;
export type DatetreeLevel = typeof DATETREE_LEVELS[number];

export type DatetreeDate = { year: number; month: number; day: number };

export type DatetreeHeading = {
  level: DatetreeLevel;
  /** Headline title, e.g. `2026`, `2026-Q4`, `2026-10 October`, `2026-W44`, `2026-10-26 Monday`. */
  title: string;
  /** Sort/identity key matched against existing sibling titles. */
  key: string;
};

const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const DAY_MS = 86_400_000;

const KEY_PATTERNS: Record<DatetreeLevel, RegExp> = {
  year: /^([12]\d{3})(?=\s|$)/,
  quarter: /^([12]\d{3}-Q[1-4])(?=\s|$)/,
  month: /^([12]\d{3}-[01]\d)\s+\S/,
  week: /^([12]\d{3}-W[0-5]\d)(?=\s|$)/,
  day: /^([12]\d{3}-[01]\d-[0-3]\d)\s+\S/,
};

const pad = (value: number, width = 2) => String(value).padStart(width, "0");

/** Parses a comma-separated level list such as `year,month,day` into canonical outer-to-inner order. */
export function parseDatetreeLevels(raw: string): DatetreeLevel[] {
  const tokens = raw.split(",").map((token) => token.trim().toLowerCase()).filter(Boolean);
  if (!tokens.length) throw new Error("datetree needs at least one of: year, quarter, month, week, day");
  const unknown = tokens.filter((token) => !(DATETREE_LEVELS as readonly string[]).includes(token));
  if (unknown.length) throw new Error(`unknown datetree level(s): ${unknown.join(", ")}. Use year, quarter, month, week, day`);
  return DATETREE_LEVELS.filter((level) => tokens.includes(level));
}

/** ISO-8601 week-numbering year and week for a calendar date. */
export function isoWeekOf(date: DatetreeDate): { isoYear: number; week: number; thursday: DatetreeDate } {
  const utc = Date.UTC(date.year, date.month - 1, date.day);
  const isoWeekday = ((new Date(utc).getUTCDay() + 6) % 7) + 1;
  const thursdayUtc = utc + (4 - isoWeekday) * DAY_MS;
  const thursday = new Date(thursdayUtc);
  const isoYear = thursday.getUTCFullYear();
  const week = Math.floor((thursdayUtc - Date.UTC(isoYear, 0, 1)) / (7 * DAY_MS)) + 1;
  return { isoYear, week, thursday: { year: isoYear, month: thursday.getUTCMonth() + 1, day: thursday.getUTCDate() } };
}

/**
 * Datetree headings for `date`, outermost first. With `week`, the year is the
 * ISO week-numbering year and a week belongs to the month containing its
 * Thursday. Quarters are 13-week periods when `week` is used without `month`,
 * and 3-month periods otherwise. The day heading always shows the real date.
 */
export function datetreeHierarchy(date: DatetreeDate, levels: readonly DatetreeLevel[]): DatetreeHeading[] {
  const has = (level: DatetreeLevel) => levels.includes(level);
  const iso = isoWeekOf(date);
  const nominalYear = has("week") ? iso.isoYear : date.year;
  const nominalMonth = has("week") ? iso.thursday.month : date.month;
  const quarter = has("week") && !has("month")
    ? Math.min(4, Math.floor((iso.week - 1) / 13) + 1)
    : Math.floor((nominalMonth - 1) / 3) + 1;
  const weekday = new Date(Date.UTC(date.year, date.month - 1, date.day)).getUTCDay();

  const headings: DatetreeHeading[] = [];
  const add = (level: DatetreeLevel, key: string, title = key) => headings.push({ level, key, title });
  if (has("year")) add("year", String(nominalYear));
  if (has("quarter")) add("quarter", `${nominalYear}-Q${quarter}`);
  if (has("month")) add("month", `${nominalYear}-${pad(nominalMonth)}`, `${nominalYear}-${pad(nominalMonth)} ${MONTH_NAMES[nominalMonth - 1]}`);
  if (has("week")) add("week", `${iso.isoYear}-W${pad(iso.week)}`);
  if (has("day")) {
    const key = `${date.year}-${pad(date.month)}-${pad(date.day)}`;
    add("day", key, `${key} ${WEEKDAY_NAMES[weekday]}`);
  }
  return headings;
}

function literalBlockFlags(lines: readonly string[]): boolean[] {
  const flags: boolean[] = [];
  let block: string | undefined;
  for (const line of lines) {
    if (block) {
      flags.push(true);
      if (/^\s*#\+end_(\S+)\s*$/i.exec(line)?.[1].toLowerCase() === block) block = undefined;
      continue;
    }
    const begin = /^\s*#\+begin_(\S+)/i.exec(line);
    if (begin) block = begin[1].toLowerCase();
    flags.push(Boolean(begin));
  }
  return flags;
}

function headlineLevel(line: string): number {
  return /^(\*+) /.exec(line)?.[1].length ?? 0;
}

function lastContentIndex(lines: readonly string[], start: number, endExclusive: number): number {
  let index = endExclusive;
  while (index > start && !(lines[index - 1] ?? "").trim()) index -= 1;
  return index;
}

export type DatetreeLocation = {
  lines: string[];
  /** 0-based index of the innermost datetree heading. */
  headingIndex: number;
  /** 0-based exclusive end of the innermost datetree heading's subtree. */
  subtreeEnd: number;
  /** Headline level of the innermost datetree heading. */
  depth: number;
  headings: DatetreeHeading[];
  created: string[];
};

/**
 * Finds or creates the datetree path for `date` in `lines`, starting at
 * top-level headings. Existing siblings whose titles match the level's format
 * are compared by key; a missing heading is inserted before the first later
 * sibling, or after the last one. Headings inside blocks are ignored.
 */
export function findOrCreateDatetree(input: readonly string[], date: DatetreeDate, levels: readonly DatetreeLevel[]): DatetreeLocation {
  const lines = [...input];
  const headings = datetreeHierarchy(date, levels);
  if (!headings.length) throw new Error("datetree needs at least one level");
  const created: string[] = [];
  let start = 0;
  let end = lines.length;
  let level = 1;
  let headingIndex = -1;

  for (const heading of headings) {
    const literal = literalBlockFlags(lines);
    let found = -1;
    let insertAt = -1;
    for (let i = start; i < end; i += 1) {
      if (literal[i] || headlineLevel(lines[i] ?? "") !== level) continue;
      const key = KEY_PATTERNS[heading.level].exec((lines[i] ?? "").slice(level + 1))?.[1];
      if (!key) continue;
      if (key === heading.key) { found = i; break; }
      if (key > heading.key) { insertAt = i; break; }
    }
    if (found < 0) {
      if (insertAt < 0) {
        insertAt = lastContentIndex(lines, headingIndex + 1, end);
      }
      lines.splice(insertAt, 0, `${"*".repeat(level)} ${heading.title}`);
      created.push(heading.title);
      found = insertAt;
      end += 1;
    }
    headingIndex = found;
    start = found + 1;
    end = start;
    const literalAfter = literalBlockFlags(lines);
    while (end < lines.length) {
      const nextLevel = literalAfter[end] ? 0 : headlineLevel(lines[end] ?? "");
      if (nextLevel > 0 && nextLevel <= level) break;
      end += 1;
    }
    level += 1;
  }

  return { lines, headingIndex, subtreeEnd: end, depth: level - 1, headings, created };
}

/**
 * Files `entryText` (an Org entry starting with a top-level headline) as the
 * last child of the datetree heading for `date`, demoting its headlines.
 */
export function fileEntryInDatetree(input: string, entryText: string, date: DatetreeDate, levels: readonly DatetreeLevel[]): {
  text: string;
  entryLine1: number;
  datetreeLine1: number;
  headings: DatetreeHeading[];
  created: string[];
} {
  const sourceLines = input ? input.replace(/\r\n?/g, "\n").replace(/\n+$/, "").split("\n") : [];
  const location = findOrCreateDatetree(sourceLines, date, levels);
  const { lines, depth, headingIndex } = location;
  const entryLines = entryText.replace(/\r\n?/g, "\n").replace(/\n+$/, "").split("\n");
  const entryLiteral = literalBlockFlags(entryLines);
  const demoted = entryLines.map((line, index) => (!entryLiteral[index] && headlineLevel(line) ? `${"*".repeat(depth)}${line}` : line));
  const insertAt = lastContentIndex(lines, headingIndex + 1, location.subtreeEnd);
  const block = insertAt === headingIndex + 1 ? demoted : ["", ...demoted];
  if (insertAt < lines.length && (lines[insertAt] ?? "").trim()) block.push("");
  lines.splice(insertAt, 0, ...block);
  const entryLine1 = insertAt + (block[0] === "" ? 1 : 0) + 1;
  return {
    text: `${lines.join("\n")}\n`,
    entryLine1,
    datetreeLine1: headingIndex + 1,
    headings: location.headings,
    created: location.created,
  };
}
