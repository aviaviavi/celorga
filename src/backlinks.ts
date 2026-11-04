import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { isUuidIdLinkTarget, parseIdLinkTarget } from "./linkSearch.js";

export interface Backlink {
  targetId: string;
  srcId: string | null;
  srcTitle: string;
  file: string;
  // 0-based line index
  line: number;
  context: string;
}

export type ResolveWikiLinkIds = (label: string) => string[];

function basenameNoExt(p: string): string {
  const parts = p.replace(/\\/g, "/").split("/");
  const base = parts[parts.length - 1] ?? p;
  return base.replace(/\.[^.]+$/, "");
}

function extractFileId(lines: string[]): string | null {
  // Accept #+id: anywhere near top.
  for (let i = 0; i < Math.min(lines.length, 30); i += 1) {
    const m = /^#\+id:\s*(\S+)\s*$/i.exec((lines[i] ?? "").trim());
    if (m) return m[1] ?? null;
  }

  // Look for a top-of-file :PROPERTIES: drawer (after blanks/comments)
  let idx = 0;
  while (idx < lines.length) {
    const l = (lines[idx] ?? "").trim();
    if (l === "" || l.startsWith("#")) {
      idx += 1;
      continue;
    }
    break;
  }

  if ((lines[idx] ?? "").trim() !== ":PROPERTIES:") return null;

  for (let j = idx + 1; j < lines.length; j += 1) {
    const l = (lines[j] ?? "").trim();
    if (l === ":END:") return null;
    const m = /^:ID:\s*(\S+)\s*$/.exec(l);
    if (m) return m[1] ?? null;
  }

  return null;
}

function findIdLinksInLine(line: string): string[] {
  const ids: string[] = [];

  // [[id:UUID]], [[id:UUID][...]], and Org 10 [[id:UUID::SEARCH][...]].
  // A link with a search option is still a backlink to the ID's node.
  const bracketRe = /\[\[([^\]\n]+?)(?:\]\[[^\]\n]*)?\]\]/g;
  let m: RegExpExecArray | null;
  let withoutBracketLinks = "";
  let cursor = 0;
  while ((m = bracketRe.exec(line)) !== null) {
    const parsed = parseIdLinkTarget(m[1]);
    if (!parsed || !isUuidIdLinkTarget(m[1])) continue;
    ids.push(parsed.id.toLowerCase());
    // Avoid double-counting `id:` inside [[id:...]] links.
    withoutBracketLinks += line.slice(cursor, m.index);
    cursor = m.index + m[0].length;
  }
  withoutBracketLinks += line.slice(cursor);

  // Bare id:UUID (a trailing ::SEARCH does not change the target)
  const bareRe = /\bid:([0-9a-fA-F-]{36})\b/g;
  while ((m = bareRe.exec(withoutBracketLinks)) !== null) {
    const id = (m[1] ?? "").toLowerCase();
    ids.push(id);
  }

  return ids;
}

function isWikiLinkTargetCandidate(targetRaw: string): boolean {
  const target = String(targetRaw || "").trim();
  if (!target) return false;

  const lower = target.toLowerCase();
  if (lower.startsWith("id:")) return false;
  if (lower.startsWith("file:")) return false;
  if (lower.startsWith("http://") || lower.startsWith("https://")) return false;
  if (lower.startsWith("mailto:")) return false;
  if (lower.startsWith("color:")) return false;
  if (target.startsWith("#") || target.startsWith("*")) return false;
  if (target.startsWith("/") || target.startsWith("./") || target.startsWith("../")) return false;

  return true;
}

function findWikiLinksInLine(line: string): string[] {
  const labels: string[] = [];
  const bracketRe = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*)\])?\]\]/g;

  let m: RegExpExecArray | null;
  while ((m = bracketRe.exec(line)) !== null) {
    const targetRaw = String(m[1] || "").trim();
    if (!isWikiLinkTargetCandidate(targetRaw)) continue;
    labels.push(targetRaw);
  }

  return labels;
}

export function findBacklinksInText(
  content: string,
  filePath: string,
  targetIdRaw: string,
  options?: { resolveWikiLinkIds?: ResolveWikiLinkIds },
): Backlink[] {
  const targetId = targetIdRaw.toLowerCase();
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const resolveWikiLinkIds = options?.resolveWikiLinkIds;

  const fileId = extractFileId(lines);

  let currentHeadlineTitle: string | null = null;
  let currentHeadlineLine: number | null = null;
  let currentHeadlineId: string | null = null;

  const out: Backlink[] = [];

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    // Headline
    const hm = /^(\*+)\s+(.*)$/.exec(line);
    if (hm) {
      currentHeadlineTitle = parseHeadlineTitleForRoam(line);
      currentHeadlineLine = i;
      currentHeadlineId = null;
    }

    // Property drawer: headline-level if immediately after headline (ignoring blank lines)
    if (line.trim() === ":PROPERTIES:") {
      // Determine if this is a headline drawer.
      let belongsToHeadline = false;
      if (currentHeadlineLine !== null) {
        // allow up to 1 blank line between headline and :PROPERTIES:
        const prev = (lines[i - 1] ?? "").trim();
        if (i - 1 === currentHeadlineLine || (prev === "" && i - 2 === currentHeadlineLine)) {
          belongsToHeadline = true;
        }
      }

      for (let j = i + 1; j < lines.length; j += 1) {
        const l = (lines[j] ?? "").trim();
        if (l === ":END:") {
          i = j; // advance outer loop to end
          break;
        }
        const idm = /^:ID:\s*(\S+)\s*$/.exec(l);
        if (idm && belongsToHeadline) {
          currentHeadlineId = (idm[1] ?? "").toLowerCase();
        }
      }
      continue;
    }

    const ids = findIdLinksInLine(line);
    if (resolveWikiLinkIds) {
      const wikiLabels = findWikiLinksInLine(line);
      for (const label of wikiLabels) {
        const resolved = resolveWikiLinkIds(label).map((id) => id.toLowerCase());
        ids.push(...resolved);
      }
    }
    if (ids.length === 0) continue;

    for (const id of ids) {
      if (id !== targetId) continue;

      const srcId = currentHeadlineId ?? fileId;
      const srcTitle = currentHeadlineTitle ?? basenameNoExt(filePath);

      out.push({
        targetId,
        srcId,
        srcTitle,
        file: filePath,
        line: i,
        context: line.trim(),
      });
    }
  }

  return out;
}
