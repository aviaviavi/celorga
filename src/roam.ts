// Shared graph, alias, and linkification semantics used by CLI and native clients.
import fs from "node:fs";
import path from "node:path";
import { parseOrgToCanonicalAst } from "./parser.js";
import type { DocumentNode, HeadlineNode, Node } from "./ast.js";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { idLinkTargetId } from "./linkSearch.js";

export function normalizeRoamLinkLabel(raw: string): string {
  return String(raw || "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

export function parseRoamAliasTokens(raw: string): string[] {
  const input = String(raw || "").trim();
  if (!input) return [];

  const out: string[] = [];
  const seen = new Set<string>();
  const pushAlias = (value: string): void => {
    const alias = String(value || "").trim();
    if (!alias) return;
    const key = alias.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push(alias);
  };

  const quotedRe = /"([^"]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = quotedRe.exec(input)) !== null) {
    pushAlias(m[1] || "");
  }

  const remainder = input.replace(quotedRe, " ").trim();
  if (remainder) {
    const commaSplit = remainder.split(/[;,]/).map((part) => part.trim()).filter(Boolean);
    if (commaSplit.length > 1) {
      for (const part of commaSplit) pushAlias(part);
    } else {
      pushAlias(remainder);
    }
  }

  return out;
}

export type RoamNodeForIndex = {
  line: number;
  lineEnd: number;
  id: string;
  labels: string[];
};

export type RoamLinkifyNode = {
  id: string;
  file: string;
  labels: string[];
};

export type RoamLinkifyCandidate = {
  id: string;
  label: string;
  file: string;
};

export type RoamLinkifyRepresentedSuggestion = {
  label: string;
  candidate: string;
  line: number;
  lineEnd: number;
  sourceRange: { startLine: number; endLine: number };
  sourceKind: "line" | "paragraph";
  text: string;
  confidence: number;
  reason: string;
  evidence: string[];
};

export type RoamLinkifyFileResult = {
  file: string;
  changed: boolean;
  replacements: number;
  ambiguousSkips: number;
  representedSuggestions: number;
  outText: string;
  debugMatches?: Array<{ label: string; candidate: string; line: number; count: number }>;
  debugAmbiguous?: Array<{ label: string; line: number; candidates: string[] }>;
  debugRepresented?: RoamLinkifyRepresentedSuggestion[];
};

export type RoamGraphNode = {
  line: number;
  lineEnd: number;
  id: string;
  label: string;
  labels: string[];
  file: string;
  degreeIn: number;
  degreeOut: number;
  degree: number;
};

export type RoamGraphEdge = {
  source: string;
  target: string;
  count: number;
};

export type RoamGraphData = {
  nodes: RoamGraphNode[];
  edges: RoamGraphEdge[];
};

type RoamLineWindow = { start: number; end: number };
type RoamSourceRange = { startLine: number; endLine: number };

function roamSourceRange(node: object): RoamSourceRange | undefined {
  return (node as { sourceRange?: RoamSourceRange }).sourceRange;
}

/** Locate only the title text of an already parsed headline, preserving source columns. */
function roamHeadlineTitleWindow(line: string, node: HeadlineNode): RoamLineWindow {
  let start = node.level + 1;
  let end = line.length;
  if (node.tags?.length) end = line.lastIndexOf(":" + node.tags.join(":") + ":");
  if (node.commented && line.slice(start).startsWith("COMMENT ")) start += "COMMENT ".length;
  if (node.todo && line.slice(start).startsWith(node.todo + " ")) start += node.todo.length + 1;
  if (node.priority) {
    const priority = /^\[#[A-Za-z0-9]\]\s*/.exec(line.slice(start));
    if (priority) start += priority[0].length;
  }
  if (node.commented && line.slice(start).startsWith("COMMENT ")) start += "COMMENT ".length;
  while (start < end && /\s/.test(line[start]!)) start += 1;
  while (end > start && /\s/.test(line[end - 1]!)) end -= 1;
  return { start, end: Math.max(start, end) };
}

/** Canonical blocks/drawers and headline metadata are never writable mention text. */
export function readRoamSourceStructure(content: string, filePath?: string) {
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const windows: Array<RoamLineWindow | null> = lines.map(line => ({ start: 0, end: line.length }));
  const headlines = new Map<number, HeadlineNode>();
  let document: DocumentNode;
  try {
    document = parseOrgToCanonicalAst(lines.join("\n"), { sourceRanges: true, sourcePath: filePath });
  } catch {
    // A malformed document cannot supply trustworthy IDs or safe edit ranges.
    return { lines, windows: windows.map(() => null), headlines, document: null };
  }
  const protect = (node: object) => {
    const range = roamSourceRange(node);
    if (range) for (let line = range.startLine; line <= range.endLine; line += 1) windows[line - 1] = null;
  };
  const visit = (node: Node, protectedParent = false): void => {
    if (node.type === "Headline") {
      const range = roamSourceRange(node)!;
      headlines.set(range.startLine, node);
      const window = roamHeadlineTitleWindow(lines[range.startLine - 1]!, node);
      const title = lines[range.startLine - 1]!.slice(window.start, window.end);
      const protectedHeading = protectedParent || !!node.commented || normalizeRoamLinkLabel(title) === "backlinks";
      if (protectedHeading) protect(node);
      else windows[range.startLine - 1] = window;
      node.children.forEach(child => visit(child, protectedHeading));
    } else if (node.type === "List") {
      node.items.forEach(child => visit(child, protectedParent));
    } else if (node.type === "ListItem") {
      node.children.forEach(child => visit(child, protectedParent));
    } else if (!["Paragraph", "Table", "Text", "FootnoteDefinition"].includes(node.type)) {
      protect(node);
    }
  };
  document.children.forEach(node => visit(node));
  return { lines, windows, headlines, document };
}

export function collectRoamNodesForIndex(content: string, filePath: string, includeDuplicateIds = false): RoamNodeForIndex[] {
  const { lines, headlines, document } = readRoamSourceStructure(content, filePath);
  if (!document) return [];
  const nodes: RoamNodeForIndex[] = [];
  const firstHeadline = document.children.findIndex(node => node.type === "Headline");
  const preamble = firstHeadline < 0 ? document.children : document.children.slice(0, firstHeadline);
  const keywords = preamble.filter(node => node.type === "KeywordLine");
  const fileTitle = keywords.find(node => node.keyRaw.toLowerCase() === "title")?.valueRaw.trim()
    || path.basename(filePath).replace(/\.(org2|org)$/i, "");
  const fileAliases = keywords.filter(node => /^roam_alias(?:es)?$/i.test(node.keyRaw))
    .flatMap(node => parseRoamAliasTokens(node.valueRaw));
  const seenNodeIds = new Set<string>();
  const pushNode = (idRaw: string, labels: string[], line = 1, lineEnd = lines.length) => {
    const id = idRaw.trim().toLowerCase();
    if (!id || (!includeDuplicateIds && seenNodeIds.has(id))) return;
    const uniqueLabels = [...new Set(labels.map(label => label.trim()).filter(Boolean))];
    if (!uniqueLabels.length) return;
    seenNodeIds.add(id);
    nodes.push({ id, labels: uniqueLabels, line, lineEnd });
  };
  const drawerProperties = (children: Node[]) => children.filter(node => node.type === "PropertyDrawer")
    .flatMap(node => node.properties);
  for (const keyword of keywords.filter(node => node.keyRaw.toLowerCase() === "id")) {
    pushNode(keyword.valueRaw, [fileTitle, ...fileAliases]);
  }
  const fileProperties = drawerProperties(preamble);
  const filePropertyAliases = fileProperties.filter(prop => /^ROAM_ALIASES$/i.test(prop.key))
    .flatMap(prop => parseRoamAliasTokens(prop.value));
  for (const prop of fileProperties.filter(prop => prop.key.toUpperCase() === "ID")) {
    pushNode(prop.value, [fileTitle, ...fileAliases, ...filePropertyAliases]);
  }
  for (const [line, headline] of headlines) {
    const titleWindow = roamHeadlineTitleWindow(lines[line - 1]!, headline);
    const title = lines[line - 1]!.slice(titleWindow.start, titleWindow.end);
    const properties = drawerProperties(headline.children);
    const aliases = properties.filter(prop => /^ROAM_ALIASES$/i.test(prop.key)).flatMap(prop => parseRoamAliasTokens(prop.value));
    for (const prop of properties.filter(prop => prop.key.toUpperCase() === "ID")) {
      pushNode(prop.value, [title, ...aliases], line, roamSourceRange(headline)!.endLine);
    }
  }
  return nodes;
}

export function buildRoamTitleIndex(files: string[]): Map<string, Set<string>> {
  const index = new Map<string, Set<string>>();

  const add = (labelRaw: string, idRaw: string): void => {
    const label = normalizeRoamLinkLabel(labelRaw);
    const id = String(idRaw || "").trim().toLowerCase();
    if (!label || !id) return;

    const existing = index.get(label);
    if (existing) {
      existing.add(id);
      return;
    }
    index.set(label, new Set([id]));
  };

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    const nodes = collectRoamNodesForIndex(content, filePath);
    for (const node of nodes) {
      for (const label of node.labels) {
        add(label, node.id);
      }
    }
  }

  return index;
}

export function buildRoamLinkifyIndex(files: string[]): Map<string, RoamLinkifyCandidate[]> {
  const index = new Map<string, RoamLinkifyCandidate[]>();

  const add = (labelRaw: string, node: RoamLinkifyNode): void => {
    const label = normalizeRoamLinkLabel(labelRaw);
    if (!label) return;

    const existing = index.get(label) || [];
    if (!existing.some((entry) => entry.id === node.id)) {
      existing.push({ id: node.id, label: labelRaw.trim(), file: node.file });
      index.set(label, existing);
    }
  };

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    const nodes = collectRoamNodesForIndex(content, filePath).map((node) => ({
      ...node,
      file: filePath,
    }));

    for (const node of nodes) {
      for (const label of node.labels) add(label, node);
    }
  }

  return index;
}

export function extractRoamFileId(content: string): string | null {
  const { document } = readRoamSourceStructure(content);
  if (!document) return null;
  for (const node of document.children) {
    if (node.type === "Headline") break;
    if (node.type === "KeywordLine" && node.keyRaw.toLowerCase() === "id") return node.valueRaw.trim().toLowerCase();
    if (node.type === "PropertyDrawer") {
      const id = node.properties.find(prop => prop.key.toUpperCase() === "ID")?.value.trim().toLowerCase();
      if (id) return id;
    }
  }
  return null;
}

export function findRoamIdLinksInLine(line: string): string[] {
  const ids: string[] = [];
  const bracketRe = /\[\[id:([^\s\[\]<>]+)(?:\]\[[^\]\n]*\])?\]\]/g;
  let match: RegExpExecArray | null;

  // An Org 10 `id:ID::SEARCH` target still links to ID.
  const push = (raw: string | undefined) => {
    const id = idLinkTargetId(`id:${raw || ""}`);
    if (id) ids.push(id);
  };
  while ((match = bracketRe.exec(line)) !== null) push(match[1]);

  const withoutBracketLinks = line.replace(/\[\[id:[^\s\[\]<>]+(?:\]\[[^\]\n]*\])?\]\]/g, "");
  const bareRe = /\bid:([^\s\[\]<>]+)(?=$|[\s\[\]<>])/g;
  while ((match = bareRe.exec(withoutBracketLinks)) !== null) push(match[1]);

  return ids;
}

export function findRoamWikiLinksInLine(line: string): string[] {
  const labels: string[] = [];
  const scanLine = line.replace(/`[^`]*`/g, "");
  const bracketRe = /\[\[([^\]\n]+?)(?:\]\[[^\]\n]*)?\]\]/g;
  let match: RegExpExecArray | null;

  while ((match = bracketRe.exec(scanLine)) !== null) {
    const targetRaw = String(match[1] || "").trim();
    const lower = targetRaw.toLowerCase();
    if (!targetRaw) continue;
    if (lower.startsWith("id:")) continue;
    if (/^[a-z][a-z0-9+.-]*:/i.test(targetRaw)) continue;
    if (targetRaw.startsWith("#") || targetRaw.startsWith("*")) continue;
    if (
      targetRaw.startsWith("~") ||
      targetRaw.startsWith("/") ||
      targetRaw.startsWith("./") ||
      targetRaw.startsWith("../")
    ) {
      continue;
    }
    labels.push(targetRaw);
  }

  return labels;
}

export function buildRoamGraph(files: string[]): RoamGraphData {
  const nodesById = new Map<string, { id: string; label: string; labels: string[]; file: string; line: number; lineEnd: number }>();
  const titleIndex = buildRoamTitleIndex(files);

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    for (const node of collectRoamNodesForIndex(content, filePath)) {
      if (nodesById.has(node.id)) continue;
      nodesById.set(node.id, {
        id: node.id,
        line: node.line,
        lineEnd: node.lineEnd,
        label: node.labels[0] || node.id,
        labels: node.labels,
        file: filePath,
      });
    }
  }

  const edgeCounts = new Map<string, number>();
  const degreeIn = new Map<string, number>();
  const degreeOut = new Map<string, number>();

  const bump = (map: Map<string, number>, id: string): void => {
    map.set(id, (map.get(id) || 0) + 1);
  };

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    const { lines, windows, headlines } = readRoamSourceStructure(content, filePath);
    const fileNodes = collectRoamNodesForIndex(content, filePath);
    const fileId = extractRoamFileId(content);
    let currentHeadlineId: string | null = null;

    for (let i = 0; i < lines.length; i += 1) {
      const headline = headlines.get(i + 1);
      if (headline) {
        currentHeadlineId = fileNodes.find(node => node.line === i + 1)?.id || null;
        continue;
      }
      const window = windows[i];
      if (!window) continue;
      const line = lines[i]!.slice(window.start, window.end);
      const sourceId = currentHeadlineId || fileId;
      if (!sourceId || !nodesById.has(sourceId)) continue;

      const targets = new Set<string>();
      for (const id of findRoamIdLinksInLine(line)) {
        if (nodesById.has(id)) targets.add(id);
      }
      for (const label of findRoamWikiLinksInLine(line)) {
        const resolved = Array.from(titleIndex.get(normalizeRoamLinkLabel(label)) || []);
        if (resolved.length === 1 && nodesById.has(resolved[0]!)) targets.add(resolved[0]!);
      }

      for (const targetId of targets) {
        if (targetId === sourceId) continue;
        const key = `${sourceId}\t${targetId}`;
        edgeCounts.set(key, (edgeCounts.get(key) || 0) + 1);
        bump(degreeOut, sourceId);
        bump(degreeIn, targetId);
      }
    }
  }

  const nodes: RoamGraphNode[] = Array.from(nodesById.values())
    .map((node) => {
      const incoming = degreeIn.get(node.id) || 0;
      const outgoing = degreeOut.get(node.id) || 0;
      return {
        ...node,
        degreeIn: incoming,
        degreeOut: outgoing,
        degree: incoming + outgoing,
      };
    })
    .sort((a, b) => b.degree - a.degree || a.label.localeCompare(b.label));

  const edges: RoamGraphEdge[] = Array.from(edgeCounts.entries())
    .map(([key, count]) => {
      const [source, target] = key.split("\t");
      return { source: source || "", target: target || "", count };
    })
    .sort((a, b) => b.count - a.count || `${a.source}:${a.target}`.localeCompare(`${b.source}:${b.target}`));

  return { nodes, edges };
}

export function escapeRegExp(raw: string): string {
  return raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function renderRoamLink(title: string, opts?: { style?: "wiki" | "id"; id?: string | null }): string {
  const style = opts?.style || "wiki";
  if (style === "id") return `[[id:${opts?.id || ""}][${title}]]`;
  return `[[${title}]]`;
}

export function isRoamLinkifyLabelEligible(labelRaw: string): boolean {
  const label = String(labelRaw || "").trim();
  if (!label) return false;
  if (label.length < 3) return false;
  if (!/[A-Za-z]/.test(label)) return false;
  return true;
}

export function lineAllowsRoamLinkify(line: string, inBlock: boolean, inDrawer: boolean): boolean {
  if (inBlock || inDrawer) return false;

  const trimmed = line.trim();
  if (!trimmed) return false;
  if (/^#\+/.test(trimmed)) return false;
  if (/^# /.test(trimmed)) return false;
  if (/^\s*: /.test(line)) return false;

  return true;
}

export function splitRoamLinkifyProtectedSegments(line: string): Array<{ text: string; protected: boolean }> {
  const segments: Array<{ text: string; protected: boolean }> = [];
  const protectedPattern = /(\[\[[^\]]+\](?:\[[^\]]*\])?\]|https?:\/\/[^\s'"`<>]+|'[^'\n]*'|"[^"\n]*"|=[^=\n]+=|~[^~\n]+~)/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = protectedPattern.exec(line)) !== null) {
    const start = match.index;
    const end = start + match[0].length;
    if (start > lastIndex) segments.push({ text: line.slice(lastIndex, start), protected: false });
    segments.push({ text: match[0], protected: true });
    lastIndex = end;
  }

  if (lastIndex < line.length) segments.push({ text: line.slice(lastIndex), protected: false });
  if (segments.length === 0) segments.push({ text: line, protected: false });
  return segments;
}

export function replaceRoamLinkifyOutsideLinks(
  line: string,
  candidate: RoamLinkifyCandidate,
): { line: string; replaced: boolean; count: number } {
  const escaped = escapeRegExp(candidate.label);
  const regex = new RegExp(`(^|[^A-Za-z0-9_])(${escaped})(?=$|[^A-Za-z0-9_])`, "gi");
  const parts = splitRoamLinkifyProtectedSegments(line);
  let replaced = false;
  let count = 0;

  for (let i = 0; i < parts.length; i += 1) {
    if (parts[i]?.protected) continue;
    const part = parts[i]?.text || "";
    parts[i]!.text = part.replace(regex, (_match, prefix: string, labelText: string) => {
      replaced = true;
      count += 1;
      return `${prefix}${renderRoamLink(labelText, { style: "id", id: candidate.id })}`;
    });
  }

  return { line: parts.map((part) => part.text).join(""), replaced, count };
}

export function isRoamLinkifyGenericLabel(labelRaw: string): boolean {
  const label = normalizeRoamLinkLabel(labelRaw);
  if (!label) return true;
  if (/\b(meeting|meetings|call|sync|standup|retro|backlinks)\b/.test(label)) return true;
  return false;
}

export function roamLinkifySemanticTokens(raw: string): string[] {
  const stop = new Set([
    "a", "an", "and", "about", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with",
    "follow", "followup", "review", "reviews", "notes", "note", "plan", "plans", "planning", "strategy",
  ]);
  const tokens = String(raw || "")
    .toLowerCase()
    .replace(/\[\[[^\]]+\](?:\[[^\]]*\])?\]/g, " ")
    .match(/[a-z0-9]+/g) || [];
  return tokens.filter((token) => token.length >= 3 && !stop.has(token));
}

export function findRoamLinkifyRepresentedSuggestion(
  text: string,
  normalizedLabel: string,
  candidates: RoamLinkifyCandidate[],
  sourceRange: { startLine: number; endLine: number },
  sourceKind: "line" | "paragraph",
): RoamLinkifyRepresentedSuggestion | null {
  const labelTokens = roamLinkifySemanticTokens(normalizedLabel);
  if (labelTokens.length < 2) return null;

  const sourceForTokens = sourceKind === "line" && /^\*+\s+/.test(text) ? parseHeadlineTitleForRoam(text) : text;
  const sourceTokens = new Set(roamLinkifySemanticTokens(sourceForTokens));
  if (!labelTokens.every((token) => sourceTokens.has(token))) return null;

  const contiguous = new RegExp(`(^|[^A-Za-z0-9_])(${escapeRegExp(normalizedLabel)})(?=$|[^A-Za-z0-9_])`, "i");
  if (contiguous.test(text)) return null;

  const resolved = resolveRoamLinkifyCandidate(normalizedLabel, candidates);
  if (!resolved) return null;

  const textTrimmed = text.trim().replace(/\s+/g, " ");
  const textSnippet = textTrimmed.length > 320 ? `${textTrimmed.slice(0, 317)}…` : textTrimmed;
  const evidence = labelTokens.filter((token) => sourceTokens.has(token));

  return {
    label: normalizedLabel,
    candidate: `${resolved.label} @ ${resolved.file}`,
    line: sourceRange.startLine,
    lineEnd: sourceRange.endLine,
    sourceRange,
    sourceKind,
    text: textSnippet,
    confidence: sourceKind === "paragraph" ? 0.72 : 0.78,
    reason: sourceKind === "paragraph"
      ? "all significant label tokens appear across this paragraph, but not as exact contiguous title text"
      : "all significant label tokens appear in this heading/paragraph, but not as exact contiguous title text",
    evidence,
  };
}

export function collectRoamLinkifySemanticParagraphs(lines: string[]): Array<{ startLine: number; endLine: number; text: string }> {
  const paragraphs: Array<{ startLine: number; endLine: number; text: string }> = [];
  let current: Array<{ lineNumber: number; text: string }> = [];
  const { windows, headlines } = readRoamSourceStructure(lines.join("\n"));

  const flush = (): void => {
    if (current.length > 1) {
      const first = current[0]!;
      const last = current[current.length - 1]!;
      paragraphs.push({
        startLine: first.lineNumber,
        endLine: last.lineNumber,
        text: current.map((entry) => entry.text.trim()).join("\n"),
      });
    }
    current = [];
  };

  for (let i = 0; i < lines.length; i += 1) {
    const window = windows[i];
    const line = window ? (lines[i] || "").slice(window.start, window.end) : "";
    if (!window || headlines.has(i + 1) || !line.trim()) {
      flush();
      continue;
    }

    current.push({ lineNumber: i + 1, text: line });
  }

  flush();
  return paragraphs;
}

export function isRoamLinkifyDateLikeBaseName(filePath: string): boolean {
  const base = path.basename(filePath).replace(/\.(org2|org)$/i, "");
  return /^\d{4}[-_]\d{2}[-_]\d{2}(?:[T_]\d+)?$/.test(base) || /^\d{14,}$/.test(base);
}

export function scoreRoamLinkifyCandidate(candidate: RoamLinkifyCandidate, normalizedLabel: string): number {
  let score = 0;
  const base = path.basename(candidate.file).replace(/\.(org2|org)$/i, "");
  const normalizedBase = normalizeRoamLinkLabel(base);

  if (normalizedBase === normalizedLabel) score += 100;
  if (!isRoamLinkifyDateLikeBaseName(candidate.file)) score += 20;
  if (!/\.bak\b|\.archive\b|\/archive\//i.test(candidate.file)) score += 10;
  if (/\.(org2|org)$/i.test(candidate.file)) score += 5;
  if (candidate.file.endsWith('.org2')) score += 3;
  if (candidate.label.trim() === candidate.label && normalizeRoamLinkLabel(candidate.label) === normalizedLabel) score += 2;

  return score;
}

export function resolveRoamLinkifyCandidate(
  normalizedLabel: string,
  candidates: RoamLinkifyCandidate[],
): RoamLinkifyCandidate | null {
  if (candidates.length === 0) return null;
  if (candidates.length === 1) return candidates[0] || null;

  const ranked = [...candidates].sort((a, b) => {
    const diff = scoreRoamLinkifyCandidate(b, normalizedLabel) - scoreRoamLinkifyCandidate(a, normalizedLabel);
    if (diff !== 0) return diff;
    return a.file.localeCompare(b.file);
  });

  const first = ranked[0]!;
  const second = ranked[1];
  if (!second) return first;
  if (scoreRoamLinkifyCandidate(first, normalizedLabel) > scoreRoamLinkifyCandidate(second, normalizedLabel)) return first;
  return null;
}

export function applyRoamLinkifyToFile(
  content: string,
  filePath: string,
  labelIndex: Map<string, RoamLinkifyCandidate[]>,
): RoamLinkifyFileResult {
  const normalized = content.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const ownNodes = collectRoamNodesForIndex(normalized, filePath);
  const ownNodeIds = new Set(ownNodes.map((node) => node.id.toLowerCase()));
  const ownLabels = new Set(ownNodes.flatMap((node) => node.labels).map((label) => normalizeRoamLinkLabel(label)));

  const labels = Array.from(labelIndex.keys())
    .filter(isRoamLinkifyLabelEligible)
    .filter((label) => !isRoamLinkifyGenericLabel(label))
    .sort((a, b) => b.length - a.length || a.localeCompare(b));

  const { windows } = readRoamSourceStructure(normalized, filePath);
  let replacements = 0;
  let ambiguousSkips = 0;
  const debugMatches: Array<{ label: string; candidate: string; line: number; count: number }> = [];
  const debugAmbiguous: Array<{ label: string; line: number; candidates: string[] }> = [];
  const debugRepresented: RoamLinkifyRepresentedSuggestion[] = [];
  const representedSeen = new Set<string>();

  for (let i = 0; i < lines.length; i += 1) {
    const window = windows[i];
    if (!window) continue;
    const originalLine = lines[i] || "";
    let line = originalLine.slice(window.start, window.end);
    if (!lineAllowsRoamLinkify(line, false, false)) continue;

    for (const normalizedLabel of labels) {
      if (ownLabels.has(normalizedLabel)) continue;
      const candidates = (labelIndex.get(normalizedLabel) || []).filter(
        (candidate) => !ownNodeIds.has(candidate.id.toLowerCase()),
      );
      if (candidates.length == 0) continue;

      const resolved = resolveRoamLinkifyCandidate(normalizedLabel, candidates);
      const probeLabel = resolved?.label || candidates[0]?.label || normalizedLabel;
      const boundaryRegex = new RegExp(
        `(^|[^A-Za-z0-9_])(${escapeRegExp(probeLabel)})(?=$|[^A-Za-z0-9_])`,
        "i",
      );
      if (!boundaryRegex.test(line)) {
        const suggestion = findRoamLinkifyRepresentedSuggestion(
          line,
          normalizedLabel,
          candidates,
          { startLine: i + 1, endLine: i + 1 },
          "line",
        );
        if (suggestion) {
          const key = `${suggestion.sourceRange.startLine}\t${suggestion.sourceRange.endLine}\t${suggestion.label}\t${suggestion.candidate}`;
          if (!representedSeen.has(key)) {
            representedSeen.add(key);
            debugRepresented.push(suggestion);
          }
        }
        continue;
      }

      if (!resolved) {
        ambiguousSkips += 1;
        debugAmbiguous.push({
          label: normalizedLabel,
          line: i + 1,
          candidates: candidates.slice(0, 8).map((candidate) => `${candidate.label} @ ${candidate.file}`),
        });
        continue;
      }

      const replaced = replaceRoamLinkifyOutsideLinks(line, resolved);
      if (!replaced.replaced) continue;

      lines[i] = originalLine.slice(0, window.start) + replaced.line + originalLine.slice(window.end);
      replacements += replaced.count;
      debugMatches.push({
        label: normalizedLabel,
        candidate: `${resolved.label} @ ${resolved.file}`,
        line: i + 1,
        count: replaced.count,
      });
      line = replaced.line;
    }
  }

  for (const paragraph of collectRoamLinkifySemanticParagraphs(lines)) {
    for (const normalizedLabel of labels) {
      if (ownLabels.has(normalizedLabel)) continue;
      const candidates = (labelIndex.get(normalizedLabel) || []).filter(
        (candidate) => !ownNodeIds.has(candidate.id.toLowerCase()),
      );
      if (candidates.length === 0) continue;

      const resolved = resolveRoamLinkifyCandidate(normalizedLabel, candidates);
      const probeLabel = resolved?.label || candidates[0]?.label || normalizedLabel;
      const boundaryRegex = new RegExp(
        `(^|[^A-Za-z0-9_])(${escapeRegExp(probeLabel)})(?=$|[^A-Za-z0-9_])`,
        "i",
      );
      if (boundaryRegex.test(paragraph.text)) continue;

      const suggestion = findRoamLinkifyRepresentedSuggestion(
        paragraph.text,
        normalizedLabel,
        candidates,
        { startLine: paragraph.startLine, endLine: paragraph.endLine },
        "paragraph",
      );
      if (!suggestion) continue;
      const key = `${suggestion.sourceRange.startLine}\t${suggestion.sourceRange.endLine}\t${suggestion.label}\t${suggestion.candidate}`;
      if (representedSeen.has(key)) continue;
      representedSeen.add(key);
      debugRepresented.push(suggestion);
    }
  }

  const outText = lines.join("\n");
  return {
    file: filePath,
    changed: outText !== normalized,
    replacements,
    ambiguousSkips,
    representedSuggestions: debugRepresented.length,
    outText,
    debugMatches,
    debugAmbiguous,
    debugRepresented,
  };
}
