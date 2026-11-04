export type CheckboxProgress = {
  total: number;
  checked: number;
  unchecked: number;
  percent: number;
  cookies: Array<{ raw: string; line: number; format: "fraction" | "percent"; done?: number; total?: number; percent?: number; stale: boolean; expectedRaw: string }>;
};

export type CheckboxProgressIssue = {
  type: "stale-progress-cookie";
  line: number;
  raw: string;
  expectedRaw: string;
  checked: number;
  total: number;
};

/**
 * The value of an Org `[p%]` cookie for `done` of `total` items: rounded down,
 * so 100 means every item is complete, and at least 1 once any item is done
 * (Org 10: 1 of 101 is [1%], not [0%]).
 */
export function orgPercentCookieValue(done: number, total: number): number {
  if (!(total > 0) || !(done > 0)) return 0;
  const percent = Math.floor((100 * done) / total);
  return percent === 0 ? 1 : percent;
}

function headingLevel(line: string): number {
  const match = /^(\*+)\s+/.exec(line);
  return match ? (match[1] || "").length : 0;
}

export function checkboxOpaqueLineIndexes(lines: string[]): Set<number> {
  const opaque = new Set<number>();
  let blockEnd: RegExp | null = null;
  let inDrawer = false;
  for (let i = 0; i < lines.length; i += 1) {
    const trimmed = (lines[i] || "").trim();
    if (blockEnd) {
      opaque.add(i);
      if (blockEnd.test(trimmed)) blockEnd = null;
      continue;
    }
    if (inDrawer) {
      opaque.add(i);
      if (/^:END:\s*$/i.test(trimmed)) inDrawer = false;
      continue;
    }
    const block = /^#\+begin_([A-Za-z0-9_-]+)\b/i.exec(trimmed);
    if (block) {
      opaque.add(i);
      blockEnd = new RegExp(`^#\\+end_${String(block[1] || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i");
      continue;
    }
    if (/^#\+begin:\s*/i.test(trimmed)) {
      opaque.add(i);
      blockEnd = /^#\+end:\s*/i;
      continue;
    }
    const drawer = /^:([A-Za-z0-9_@#%+.-]+):\s*$/.exec(trimmed);
    if (drawer && String(drawer[1] || "").toUpperCase() !== "END") {
      opaque.add(i);
      inDrawer = true;
    }
  }
  return opaque;
}

export function checkboxHeadingEndExclusive(
  lines: string[],
  startIndex: number,
  level: number,
  opaqueLines: ReadonlySet<number>,
): number {
  for (let i = startIndex + 1; i < lines.length; i += 1) {
    if (opaqueLines.has(i)) continue;
    const nextLevel = headingLevel(lines[i] || "");
    if (nextLevel > 0 && nextLevel <= level) return i;
  }
  return lines.length;
}

export function extractCheckboxProgress(
  lines: string[],
  startIndex: number,
  endExclusive: number,
  opaqueLines: ReadonlySet<number> = checkboxOpaqueLineIndexes(lines),
): CheckboxProgress {
  let checked = 0;
  let unchecked = 0;
  const found: Array<Omit<CheckboxProgress["cookies"][number], "stale" | "expectedRaw">> = [];
  for (let i = startIndex; i < endExclusive; i += 1) {
    if (opaqueLines.has(i)) continue;
    const line = lines[i] || "";
    const item = /^\s*(?:[-+*]|\d+[.)])\s+\[([ Xx-])\]/.exec(line);
    if (item) {
      if (/^[Xx]$/.test(item[1] || "")) checked += 1;
      else unchecked += 1;
    }
    if (headingLevel(line) === 0 && !/^\s*(?:[-+*]|\d+[.)])\s+/.test(line)) continue;
    const re = /\[(?:(\d+)\/(\d+)|\/)\]|\[(\d{1,3})?%\]/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(line)) !== null) {
      const format = (match[0] || "").includes("/") ? "fraction" : "percent";
      const raw = match[0] || "";
      const doneValue = match[1] !== undefined ? Number.parseInt(match[1] || "0", 10) : undefined;
      const totalValue = match[2] !== undefined ? Number.parseInt(match[2] || "0", 10) : undefined;
      const percentValue = format === "percent" && match[3] !== undefined
        ? Number.parseInt(match[3] || "0", 10)
        : (totalValue && totalValue > 0 && doneValue !== undefined ? orgPercentCookieValue(doneValue, totalValue) : 0);
      found.push({
        raw,
        line: i + 1,
        format,
        ...(doneValue !== undefined ? { done: doneValue } : {}),
        ...(totalValue !== undefined ? { total: totalValue } : {}),
        percent: percentValue,
      });
    }
  }
  const total = checked + unchecked;
  const percent = orgPercentCookieValue(checked, total);
  const cookies = found.map((cookie) => {
    const expectedRaw = cookie.format === "fraction" ? `[${checked}/${total}]` : `[${percent}%]`;
    return { ...cookie, stale: cookie.raw !== expectedRaw, expectedRaw };
  });
  return { total, checked, unchecked, percent, cookies };
}

type CheckboxIssueOwner = {
  span: number;
  startIndex: number;
  issue: CheckboxProgressIssue | null;
};

function registerOwnedCheckboxScope(
  owners: Map<string, CheckboxIssueOwner>,
  progress: CheckboxProgress,
  startIndex: number,
  endExclusive: number,
): void {
  const span = endExclusive - startIndex;
  for (const cookie of progress.cookies) {
    const key = `${cookie.line}:${cookie.raw}`;
    const existing = owners.get(key);
    if (existing && (existing.span < span || (existing.span === span && existing.startIndex >= startIndex))) continue;
    owners.set(key, {
      span,
      startIndex,
      issue: cookie.stale ? {
        type: "stale-progress-cookie",
        line: cookie.line,
        raw: cookie.raw,
        expectedRaw: cookie.expectedRaw,
        checked: progress.checked,
        total: progress.total,
      } : null,
    });
  }
}

function ownedCheckboxIssues(owners: Map<string, CheckboxIssueOwner>): CheckboxProgressIssue[] {
  return [...owners.values()]
    .flatMap((owner) => owner.issue ? [owner.issue] : [])
    .sort((a, b) => a.line - b.line || a.raw.localeCompare(b.raw));
}

/**
 * Return stale cookies from their narrowest containing heading scope.
 *
 * A heading's per-node progress intentionally covers its recursive subtree, so
 * an ancestor also sees cookies owned by descendant headings. Top-level issues
 * must use the innermost owner, including a non-stale evaluation, so an
 * ancestor's wider aggregate cannot turn a correct descendant cookie stale.
 */
export function extractOwnedCheckboxIssues(lines: string[]): CheckboxProgressIssue[] {
  const owners = new Map<string, CheckboxIssueOwner>();
  const opaqueLines = checkboxOpaqueLineIndexes(lines);
  const firstHeadingIndex = lines.findIndex((line, index) => !opaqueLines.has(index) && headingLevel(line || "") > 0);
  const preambleEndExclusive = firstHeadingIndex === -1 ? lines.length : firstHeadingIndex;
  registerOwnedCheckboxScope(owners, extractCheckboxProgress(lines, 0, preambleEndExclusive, opaqueLines), 0, preambleEndExclusive);
  for (let i = 0; i < lines.length; i += 1) {
    if (opaqueLines.has(i)) continue;
    const level = headingLevel(lines[i] || "");
    if (level > 0) {
      const endExclusive = checkboxHeadingEndExclusive(lines, i, level, opaqueLines);
      registerOwnedCheckboxScope(owners, extractCheckboxProgress(lines, i, endExclusive, opaqueLines), i, endExclusive);
    }
  }
  return ownedCheckboxIssues(owners);
}

/** Collect top-level issues while reusing progress already computed for each scope. */
export function createCheckboxIssueCollector() {
  const owners = new Map<string, CheckboxIssueOwner>();
  return {
    add(progress: CheckboxProgress, startIndex: number, endExclusive: number) {
      registerOwnedCheckboxScope(owners, progress, startIndex, endExclusive);
    },
    issues() {
      return ownedCheckboxIssues(owners);
    },
  };
}
