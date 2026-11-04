import { parseProjectNote } from "./project.js";
import fs from "node:fs";
import path from "node:path";
import v8 from "node:v8";
import { buildGeneratedArtifactMetadata, sha256Hex, type Org2GeneratedArtifactMetadata } from "./artifactMetadata.js";
import { documentTodoSequences, todoSequencesForFile, todoConfigurationKey, todoKeywordInWorkflow, isTerminalTodoKeyword, type TodoSequence } from "./todo.js";
import { extractClockReport, type OrgClockInterval, type OrgClockIssue, type OrgClockSummary } from "./clock.js";
import {
  checkboxHeadingEndExclusive,
  checkboxOpaqueLineIndexes,
  createCheckboxIssueCollector,
  extractCheckboxProgress,
  type CheckboxProgress,
  type CheckboxProgressIssue,
} from "./checkboxProgress.js";
import { brandProperty, isBrandName } from "./brandNames.js";
import { idLinkTargetId, isUuidIdLinkTarget } from "./linkSearch.js";

export { extractCheckboxProgress, extractOwnedCheckboxIssues } from "./checkboxProgress.js";
export type { CheckboxProgress, CheckboxProgressIssue } from "./checkboxProgress.js";

export type CompiledCorpusLink = {
  type: "id" | "wiki" | "file" | "url" | "other";
  target: string;
  description?: string;
  line: number;
};

export type CompiledCorpusBacklink = {
  sourceKey: string;
  sourceId: string | null;
  sourceTitle: string;
  file: string;
  line: number;
  linkType: "id" | "wiki";
};

export type CompiledCorpusEntity = {
  nodeKey: string;
  id: string | null;
  title: string;
  entityType: string;
  file: string;
  line: number;
  source: "property" | "tag";
};

export type CompiledCorpusEntityProfile = {
  entityId: string;
  canonicalName: string;
  type: string;
  aliases: string[];
  nodeKeys: string[];
  backlinks: CompiledCorpusBacklink[];
  mentions: Array<{ sourceKey: string; sourceTitle: string; file: string; line: number; label: string }>;
  relations: CompiledCorpusRelation[];
  facts: Array<{ key: string; value: string; provenance: Array<{ sourceKey: string; file: string; line: number }> }>;
  reviewNeeded: Array<{ type: "conflicting-fact" | "ambiguous-alias"; message: string; key?: string; values?: string[]; labels?: string[] }>;
};

export type CompiledCorpusRelation = {
  subjectKey: string;
  subjectId: string | null;
  subjectTitle: string;
  predicate: string;
  objectId: string | null;
  objectTitle?: string;
  objectRef: string;
  file: string;
  line: number;
  evidence: string;
  confidence: "explicit" | "inferred-pattern";
  method: string;
};

export type CompiledCorpusNode = {
  key: string;
  kind: "file" | "heading";
  file: string;
  sourceRange: { startLine: number; endLine: number };
  id: string | null;
  title: string;
  level?: number;
  todo?: string;
  todoTerminal?: boolean;
  priority?: string;
  tags: string[];
  aliases: string[];
  properties: Record<string, string>;
  /** Explicit properties overlaid on inherited file/ancestor heading properties. */
  effectiveProperties: Record<string, string>;
  /** Properties inherited from file/ancestor heading drawers and not overridden locally. */
  inheritedProperties: Record<string, string>;
  effort?: { raw: string; minutes: number };
  planning: Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }>;
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  checkboxProgress: CheckboxProgress;
  links: CompiledCorpusLink[];
  backlinks: CompiledCorpusBacklink[];
  entityType?: string;
  snippet: string;
  snippetStartLine: number | null;
};

export type CompiledCorpusFile = {
  file: string;
  absolutePath: string;
  sha256: string;
  lineCount: number;
  title: string;
  id: string | null;
};

export type CompiledCorpusIndexState = {
  mode: "full" | "incremental";
  status: "fresh" | "stale";
  cacheFile?: string;
  reusedFiles: number;
  parsedFiles: number;
  deletedFiles: number;
  reason?: string;
};

export type CompiledCorpusLookupIndex = {
  ids: Record<string, string[]>;
  titles: Record<string, string[]>;
  tags: Record<string, string[]>;
  dates: Record<string, string[]>;
  files: Record<string, string[]>;
};

export type CompiledCorpus = {
  schemaVersion: "org2-compiled-corpus/v1";
  generatedBy: "org2 compile corpus";
  artifact: Org2GeneratedArtifactMetadata;
  rootDir: string;
  files: CompiledCorpusFile[];
  nodes: CompiledCorpusNode[];
  stats: {
    files: number;
    nodes: number;
    headings: number;
    links: number;
    backlinks: number;
    entities: number;
    relations: number;
    entityProfiles: number;
  };
  entities: CompiledCorpusEntity[];
  entityProfiles: CompiledCorpusEntityProfile[];
  relations: CompiledCorpusRelation[];
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  checkboxProgress: CheckboxProgress;
  checkboxIssues: Array<CheckboxProgressIssue & { file: string }>;
  clockSummary: ReturnType<typeof extractClockReport>["summary"];
  effortSummary: {
    totalMinutes: number;
    byProject: Record<string, number>;
    byTag: Record<string, number>;
    byFile: Record<string, number>;
  };
  index?: CompiledCorpusLookupIndex;
  indexState?: CompiledCorpusIndexState;
};

function normalizeText(raw: string): string {
  return String(raw || "").replace(/\r\n/g, "\n");
}

function normalizeId(raw: string | null | undefined): string | null {
  const value = String(raw || "").trim().toLowerCase();
  return value || null;
}


function parseEffortToMinutes(raw: string): number | null {
  const token = String(raw || "").trim().toLowerCase().replace(/\s+/g, "");
  if (!token) return null;
  const n = (value: string): number | null => (/^\d+$/.test(value) ? Number.parseInt(value, 10) : null);

  const hm = /^(\d+):(\d{1,2})$/.exec(token);
  if (hm) {
    const hours = n(hm[1] || "");
    const minutes = n(hm[2] || "");
    if (hours === null || minutes === null || minutes >= 60) return null;
    return hours * 60 + minutes;
  }

  const compact = /^(?:(\d+)h)?(?:(\d+)m)?$/.exec(token);
  if (compact && (compact[1] || compact[2])) {
    const hours = compact[1] ? n(compact[1]) : 0;
    const minutes = compact[2] ? n(compact[2]) : 0;
    if (hours === null || minutes === null) return null;
    return hours * 60 + minutes;
  }

  return n(token);
}

function effortFromProperties(properties: Record<string, string>): { raw: string; minutes: number } | undefined {
  const raw = String(properties.EFFORT || "").trim();
  if (!raw) return undefined;
  const minutes = parseEffortToMinutes(raw);
  return minutes === null ? undefined : { raw, minutes };
}

function buildEffortSummary(nodes: CompiledCorpusNode[]): CompiledCorpus["effortSummary"] {
  const byProject: Record<string, number> = {};
  const byTag: Record<string, number> = {};
  const byFile: Record<string, number> = {};
  let totalMinutes = 0;
  const add = (bucket: Record<string, number>, key: string, minutes: number) => {
    bucket[key] = (bucket[key] || 0) + minutes;
  };

  for (const node of nodes) {
    if (node.kind !== "heading" || !node.effort) continue;
    totalMinutes += node.effort.minutes;
    add(byProject, node.title, node.effort.minutes);
    add(byFile, node.file, node.effort.minutes);
    for (const tag of node.tags) add(byTag, tag, node.effort.minutes);
  }

  return { totalMinutes, byProject, byTag, byFile };
}

function slashPath(raw: string): string {
  return raw.replace(/\\/g, "/");
}

function relativePath(rootDir: string, filePath: string): string {
  const rel = path.relative(rootDir, filePath);
  return slashPath(rel && !rel.startsWith("..") ? rel : filePath);
}

function sha256(raw: string): string {
  return sha256Hex(raw);
}

function parseAliasTokens(raw: string): string[] {
  const out: string[] = [];
  const re = /"([^"]+)"|'([^']+)'|([^\s,]+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(raw)) !== null) {
    const value = String(match[1] || match[2] || match[3] || "").trim();
    if (value) out.push(value);
  }
  return Array.from(new Set(out));
}

function parseKeywordValue(lines: string[], key: string, maxLines: number): string | null {
  const re = new RegExp(`^#\\+${key}:\\s*(.*?)\\s*$`, "i");
  for (let i = 0; i < Math.min(lines.length, maxLines); i += 1) {
    const match = re.exec((lines[i] || "").trim());
    if (match) return String(match[1] || "").trim();
  }
  return null;
}

function parseKeywordAliases(lines: string[], maxLines: number): string[] {
  const aliases: string[] = [];
  for (let i = 0; i < Math.min(lines.length, maxLines); i += 1) {
    const match = /^#\+roam_alias(?:es)?:\s*(.*?)\s*$/i.exec((lines[i] || "").trim());
    if (match) aliases.push(...parseAliasTokens(match[1] || ""));
  }
  return Array.from(new Set(aliases));
}

function parsePropertyDrawerAt(lines: string[], startIndex: number): { properties: Record<string, string>; endIndex: number } | null {
  if ((lines[startIndex] || "").trim().toUpperCase() !== ":PROPERTIES:") return null;
  const properties: Record<string, string> = {};
  for (let i = startIndex + 1; i < lines.length; i += 1) {
    const trimmed = (lines[i] || "").trim();
    if (trimmed.toUpperCase() === ":END:") return { properties, endIndex: i };
    const match = /^:([^:\s]+):\s*(.*?)\s*$/.exec(trimmed);
    if (match) properties[String(match[1] || "").toUpperCase()] = String(match[2] || "").trim();
  }
  return null;
}

function findFilePropertyDrawer(lines: string[]): { properties: Record<string, string>; endIndex: number } | null {
  const firstHeadline = lines.findIndex((line) => /^\*+\s+/.test(line || ""));
  const scanEnd = firstHeadline === -1 ? lines.length : firstHeadline;
  for (let i = 0; i < scanEnd; i += 1) {
    if ((lines[i] || "").trim().toUpperCase() === ":PROPERTIES:") return parsePropertyDrawerAt(lines, i);
  }
  return null;
}

function stripTags(raw: string): { title: string; tags: string[] } {
  const match = /\s+(:[A-Za-z0-9_@#%:]+:)\s*$/.exec(raw);
  if (!match) return { title: raw.trim(), tags: [] };
  const tags = String(match[1] || "")
    .split(":")
    .map((value) => value.trim())
    .filter(Boolean);
  return { title: raw.slice(0, match.index).trim(), tags };
}

function normalizePriorityToken(raw: string): string | undefined {
  const match = /^#?([A-Za-z0-9])$/.exec(raw.trim().replace(/^\[#/, "").replace(/\]$/, ""));
  if (!match) return undefined;
  return (match[1] || "").toUpperCase();
}

function stripPriority(raw: string): { title: string; priority?: string } {
  const match = /^\[#([A-Za-z0-9])\](?:\s+|$)(.*)$/i.exec(raw.trim());
  if (!match) return { title: raw.trim() };
  return { priority: normalizePriorityToken(match[1] || ""), title: String(match[2] || "").trim() };
}

function parseHeading(line: string, sequences: readonly TodoSequence[] = []): { level: number; title: string; todo?: string; priority?: string; tags: string[] } | null {
  const match = /^(\*+)\s+(.*?)\s*$/.exec(line);
  if (!match) return null;
  const level = (match[1] || "").length;
  let rest = String(match[2] || "").trim();
  const tagStripped = stripTags(rest);
  rest = tagStripped.title;
  let todo: string | undefined;
  const first = rest.split(/\s+/)[0] || "";
  const normalizedTodo = todoKeywordInWorkflow(first, sequences);
  if (normalizedTodo) {
    todo = normalizedTodo;
    rest = rest.slice(first.length).trim();
  }
  const priorityStripped = stripPriority(rest);
  return { level, title: priorityStripped.title, todo, priority: priorityStripped.priority, tags: tagStripped.tags };
}

function headingEndExclusive(lines: string[], startIndex: number, level: number): number {
  for (let i = startIndex + 1; i < lines.length; i += 1) {
    const next = /^(\*+)\s+/.exec(lines[i] || "");
    const nextLevel = next ? (next[1] || "").length : 0;
    if (nextLevel > 0 && nextLevel <= level) return i;
  }
  return lines.length;
}

function propertyDrawerAfterHeading(lines: string[], headingIndex: number): { properties: Record<string, string>; endIndex: number } | null {
  let i = headingIndex + 1;
  while (i < lines.length) {
    const trimmed = (lines[i] || "").trim();
    if (!trimmed || /^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) {
      i += 1;
      continue;
    }
    break;
  }
  return parsePropertyDrawerAt(lines, i);
}

function extractPlanning(lines: string[], startIndex: number, endExclusive: number): Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }> {
  const out: Array<{ kind: "SCHEDULED" | "DEADLINE" | "CLOSED"; raw: string; line: number }> = [];
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const re = /\b(SCHEDULED|DEADLINE|CLOSED):\s*(.*?)(?=\s+\b(?:SCHEDULED|DEADLINE|CLOSED):|$)/g;
    let match: RegExpExecArray | null;
    while ((match = re.exec(line)) !== null) {
      const kind = match[1] as "SCHEDULED" | "DEADLINE" | "CLOSED";
      out.push({ kind, raw: String(match[2] || "").trim(), line: i + 1 });
    }
  }
  return out;
}

function linkType(target: string): CompiledCorpusLink["type"] {
  const value = target.trim();
  const lower = value.toLowerCase();
  if (isUuidIdLinkTarget(value)) return "id";
  if (lower.startsWith("file:")) return "file";
  if (lower.startsWith("http://") || lower.startsWith("https://")) return "url";
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value) && value && !value.startsWith("/") && !value.startsWith("./") && !value.startsWith("../") && !value.startsWith("#")) return "wiki";
  return "other";
}


function extractLinks(lines: string[], startIndex: number, endExclusive: number): CompiledCorpusLink[] {
  const links: CompiledCorpusLink[] = [];
  let inBlock = false;
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const trimmed = line.trim();
    if (/^#\+begin_/i.test(trimmed)) {
      inBlock = true;
      continue;
    }
    if (/^#\+end_/i.test(trimmed)) {
      inBlock = false;
      continue;
    }
    if (inBlock) continue;

    const bracketRe = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]/g;
    let match: RegExpExecArray | null;
    const bracketRanges: Array<{ start: number; end: number }> = [];
    while ((match = bracketRe.exec(line)) !== null) {
      const target = String(match[1] || "").trim();
      if (!target) continue;
      bracketRanges.push({ start: match.index, end: match.index + match[0].length });
      const link: CompiledCorpusLink = { type: linkType(target), target, line: i + 1 };
      const description = String(match[2] || "").trim();
      if (description) link.description = description;
      links.push(link);
    }

    const bareIdRe = /\bid:([0-9a-fA-F-]{36})\b/g;
    while ((match = bareIdRe.exec(line)) !== null) {
      const start = match.index;
      if (bracketRanges.some((range) => start >= range.start && start < range.end)) continue;
      links.push({ type: "id", target: `id:${String(match[1] || "").toLowerCase()}`, line: i + 1 });
    }
  }
  return links.sort((a, b) => a.line - b.line || a.target.localeCompare(b.target));
}

function extractSnippetWithLine(lines: string[], startIndex: number, endExclusive: number): { snippet: string; startLine: number | null } {
  let inDrawer = false;
  let inBlock = false;
  const parts: string[] = [];
  let snippetStartLine: number | null = null;
  for (let i = startIndex; i < endExclusive; i += 1) {
    const line = lines[i] || "";
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (/^\*+\s+/.test(line)) continue;
    if (trimmed.toUpperCase() === ":PROPERTIES:") {
      inDrawer = true;
      continue;
    }
    if (inDrawer) {
      if (trimmed.toUpperCase() === ":END:") inDrawer = false;
      continue;
    }
    if (/^#\+begin_/i.test(trimmed)) {
      inBlock = true;
      continue;
    }
    if (/^#\+end_/i.test(trimmed)) {
      inBlock = false;
      continue;
    }
    if (inBlock) continue;
    if (/^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) continue;
    if (/^#\+/.test(trimmed)) continue;
    if (snippetStartLine === null) snippetStartLine = i + 1;
    parts.push(trimmed.replace(/\s+/g, " "));
    if (parts.join(" ").length >= 240) break;
  }
  return { snippet: parts.join(" ").slice(0, 240), startLine: snippetStartLine };
}

function normalizeLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function normalizeEntityType(raw: string | null | undefined): string | undefined {
  const value = String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
  return value || undefined;
}

function normalizePredicate(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
}

function nodeEntityType(node: CompiledCorpusNode): string | undefined {
  const propertyType = normalizeEntityType(brandProperty(node.properties, "ORG2_ENTITY_TYPE") || node.properties.ENTITY_TYPE);
  if (propertyType) return propertyType;
  const typedTag = node.tags.find((tag) => /^type[-_:]/i.test(tag));
  return typedTag ? normalizeEntityType(typedTag.replace(/^type[-_:]/i, "")) : undefined;
}

function nodeLabels(node: CompiledCorpusNode): string[] {
  return Array.from(new Set([node.title, ...node.aliases].map((value) => value.trim()).filter(Boolean)));
}

function summarizeClockIntervals(intervals: OrgClockInterval[]): OrgClockSummary {
  const summary: OrgClockSummary = {
    totalMinutes: 0,
    byDay: {},
    byHeading: {},
    byTag: {},
    byProject: {},
    byFile: {},
  };
  const add = (bucket: Record<string, number>, key: string | undefined, minutes: number) => {
    const normalized = (key || "").trim() || "(none)";
    bucket[normalized] = (bucket[normalized] || 0) + minutes;
  };
  for (const interval of intervals) {
    summary.totalMinutes += interval.minutes;
    add(summary.byDay, interval.start.slice(0, 10), interval.minutes);
    add(summary.byHeading, interval.heading, interval.minutes);
    add(summary.byProject, interval.project, interval.minutes);
    add(summary.byFile, interval.file, interval.minutes);
    for (const tag of interval.tags) add(summary.byTag, tag, interval.minutes);
  }
  return summary;
}

function finalizeCompiledCorpus(options: {
  rootDir: string;
  corpusFiles: CompiledCorpusFile[];
  sourceNodes: CompiledCorpusNode[];
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  checkboxProgress: CheckboxProgress;
  checkboxIssues: CompiledCorpus["checkboxIssues"];
  generatedAt?: string;
  indexState: CompiledCorpusIndexState;
}): CompiledCorpus {
  const nodes: CompiledCorpusNode[] = options.sourceNodes.map((node) => ({
    ...node,
    backlinks: [],
  }));
  const byId = new Map<string, CompiledCorpusNode>();
  const labels = new Map<string, Set<string>>();
  for (const node of nodes) {
    if (node.id && !byId.has(node.id)) byId.set(node.id, node);
    if (!node.id) continue;
    for (const label of nodeLabels(node)) {
      const key = normalizeLabel(label);
      if (!key) continue;
      const set = labels.get(key) || new Set<string>();
      set.add(node.id);
      labels.set(key, set);
    }
  }

  for (const source of nodes) {
    for (const link of source.links) {
      let targetId: string | null = null;
      let resolvedBy: "id" | "wiki" | null = null;
      if (link.type === "id") {
        targetId = idLinkTargetId(link.target);
        resolvedBy = "id";
      } else if (link.type === "wiki") {
        const candidates = Array.from(labels.get(normalizeLabel(link.target)) || []);
        if (candidates.length === 1) {
          targetId = candidates[0] || null;
          resolvedBy = "wiki";
        }
      }
      if (!targetId || !resolvedBy) continue;
      const target = byId.get(targetId);
      if (!target) continue;
      target.backlinks.push({
        sourceKey: source.key,
        sourceId: source.id,
        sourceTitle: source.title,
        file: source.file,
        line: link.line,
        linkType: resolvedBy,
      });
    }
  }

  for (const node of nodes) {
    node.entityType = nodeEntityType(node);
    node.backlinks.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.sourceKey.localeCompare(b.sourceKey));
  }

  const entities = buildEntityIndex(nodes);
  const relations = buildRelationIndex(nodes, byId, labels);
  const entityProfiles = buildEntityProfiles(nodes, entities, relations, labels);
  const totalLinks = nodes.reduce((sum, node) => sum + node.links.length, 0);
  const totalBacklinks = nodes.reduce((sum, node) => sum + node.backlinks.length, 0);
  const sortedNodes = nodes.sort((a, b) => a.file.localeCompare(b.file) || a.sourceRange.startLine - b.sourceRange.startLine || a.kind.localeCompare(b.kind));
  const corpusFiles = options.corpusFiles.sort((a, b) => a.file.localeCompare(b.file));

  return {
    schemaVersion: "org2-compiled-corpus/v1",
    generatedBy: "org2 compile corpus",
    artifact: buildGeneratedArtifactMetadata({
      role: "compiled",
      generator: "org2 compile corpus",
      generatedAt: options.generatedAt,
      provenance: corpusFiles.map((file) => `file:${file.file}`),
      sourceHashes: corpusFiles.map((file) => ({ kind: "file", value: file.file, sha256: file.sha256 })),
      reviewStatus: "generated",
      claimState: "source-backed",
      observedAt: options.generatedAt,
      validAsOf: options.generatedAt,
    }),
    rootDir: options.rootDir,
    files: corpusFiles,
    nodes: sortedNodes,
    stats: {
      files: corpusFiles.length,
      nodes: sortedNodes.length,
      headings: sortedNodes.filter((node) => node.kind === "heading").length,
      links: totalLinks,
      backlinks: totalBacklinks,
      entities: entities.length,
      relations: relations.length,
      entityProfiles: entityProfiles.length,
    },
    entities,
    entityProfiles,
    relations,
    clocks: options.clocks,
    clockIssues: options.clockIssues,
    checkboxProgress: {
      ...options.checkboxProgress,
      percent: options.checkboxProgress.total > 0
        ? Math.round((options.checkboxProgress.checked / options.checkboxProgress.total) * 100)
        : 0,
    },
    checkboxIssues: options.checkboxIssues,
    clockSummary: summarizeClockIntervals(options.clocks),
    effortSummary: buildEffortSummary(sortedNodes),
    index: buildLookupIndex(sortedNodes),
    indexState: options.indexState,
  };
}

export function compileCorpus(files: string[], opts?: { rootDir?: string; generatedAt?: string }): CompiledCorpus {
  const rootDir = path.resolve(opts?.rootDir || process.cwd());
  const sortedFiles = Array.from(new Set(files.map((file) => path.resolve(file)))).sort();
  const corpusFiles: CompiledCorpusFile[] = [];
  const nodes: CompiledCorpusNode[] = [];
  const clockReport = extractClockReport(sortedFiles, { rootDir });
  const checkboxIssuesByKey = new Map<string, CompiledCorpus["checkboxIssues"][number]>();
  const corpusCheckboxProgress: CheckboxProgress = { total: 0, checked: 0, unchecked: 0, percent: 0, cookies: [] };
  const clocksByNode = new Map<string, OrgClockInterval[]>();
  const clockIssuesByNode = new Map<string, OrgClockIssue[]>();
  for (const clock of clockReport.intervals) clocksByNode.set(clock.nodeKey, [...(clocksByNode.get(clock.nodeKey) || []), clock]);
  for (const issue of clockReport.issues) if (issue.nodeKey) clockIssuesByNode.set(issue.nodeKey, [...(clockIssuesByNode.get(issue.nodeKey) || []), issue]);

  for (const filePath of sortedFiles) {
    const raw = fs.readFileSync(filePath, "utf8");
    const content = normalizeText(raw);
    const lines = content.split("\n");
    const opaqueLines = checkboxOpaqueLineIndexes(lines);
    const file = relativePath(rootDir, filePath);
    const title = parseKeywordValue(lines, "title", 80) || path.basename(filePath).replace(/\.(org2|org)$/i, "");
    const fileDrawer = findFilePropertyDrawer(lines);
    const keywordId = normalizeId(parseKeywordValue(lines, "id", 30));
    const drawerId = normalizeId(fileDrawer?.properties.ID);
    const id = keywordId || drawerId;
    const aliases = Array.from(new Set([...parseKeywordAliases(lines, 80), ...parseAliasTokens(fileDrawer?.properties.ROAM_ALIASES || "")]));
    const properties = fileDrawer?.properties || {};
    if (!brandProperty(properties, "ORG2_ENTITY_TYPE") && !properties.ENTITY_TYPE
        && /^#\+(?:CELORGA|ORG2)_KIND:\s*project\s*$/im.test(raw.slice(0, 8192))) {
      try {
        // Reuse project semantics so examples inside source blocks are not entities.
        parseProjectNote(rootDir, filePath, raw);
        properties.ORG2_ENTITY_TYPE = "project";
      } catch { /* Invalid project notes are reported by project discovery. */ }
    }
    const headingPropertyStack: Array<{ level: number; effectiveProperties: Record<string, string> }> = [];
    const checkboxIssueCollector = createCheckboxIssueCollector();
    const firstHeadingIndex = lines.findIndex((line) => /^\*+\s+/.test(line || ""));
    const preambleEndExclusive = firstHeadingIndex === -1 ? lines.length : firstHeadingIndex;
    const firstOwnedHeadingIndex = lines.findIndex((line, index) => !opaqueLines.has(index) && /^\*+\s+/.test(line || ""));
    const ownedPreambleEndExclusive = firstOwnedHeadingIndex === -1 ? lines.length : firstOwnedHeadingIndex;
    const fileLinks = extractLinks(lines, 0, preambleEndExclusive);
    const fileSnippet = extractSnippetWithLine(lines, 0, preambleEndExclusive);
    const fullFileCheckboxProgress = extractCheckboxProgress(lines, 0, lines.length, opaqueLines);
    corpusCheckboxProgress.total += fullFileCheckboxProgress.total;
    corpusCheckboxProgress.checked += fullFileCheckboxProgress.checked;
    corpusCheckboxProgress.unchecked += fullFileCheckboxProgress.unchecked;
    const fileCheckboxProgress = extractCheckboxProgress(lines, 0, preambleEndExclusive, opaqueLines);
    const ownedPreambleProgress = ownedPreambleEndExclusive === preambleEndExclusive
      ? fileCheckboxProgress
      : extractCheckboxProgress(lines, 0, ownedPreambleEndExclusive, opaqueLines);
    checkboxIssueCollector.add(ownedPreambleProgress, 0, ownedPreambleEndExclusive);

    corpusFiles.push({ file, absolutePath: filePath, sha256: sha256(content), lineCount: lines.length, title, id });
    const fileKey = `file:${file}`;
    nodes.push({
      key: fileKey,
      kind: "file",
      file,
      sourceRange: { startLine: 1, endLine: Math.max(1, preambleEndExclusive) },
      id,
      title,
      tags: [],
      aliases,
      properties,
      effectiveProperties: { ...properties },
      inheritedProperties: {},
      planning: extractPlanning(lines, 0, preambleEndExclusive),
      clocks: clocksByNode.get(fileKey) || [],
      clockIssues: clockIssuesByNode.get(fileKey) || [],
      checkboxProgress: fileCheckboxProgress,
      links: fileLinks,
      backlinks: [],
      snippet: fileSnippet.snippet,
      snippetStartLine: fileSnippet.startLine,
    });

    const sequences = documentTodoSequences(lines.join("\n"), todoSequencesForFile(filePath));
    for (let i = 0; i < lines.length; i += 1) {
      const heading = parseHeading(lines[i] || "", sequences);
      if (!heading) continue;
      const endExclusive = headingEndExclusive(lines, i, heading.level);
      const checkboxEndExclusive = opaqueLines.has(i)
        ? endExclusive
        : checkboxHeadingEndExclusive(lines, i, heading.level, opaqueLines);
      while (headingPropertyStack.length && (headingPropertyStack[headingPropertyStack.length - 1]?.level || 0) >= heading.level) headingPropertyStack.pop();
      const inheritedBase = headingPropertyStack[headingPropertyStack.length - 1]?.effectiveProperties || properties;
      const drawer = propertyDrawerAfterHeading(lines, i);
      const headingProperties = drawer?.properties || {};
      const headingEffectiveProperties = { ...inheritedBase, ...headingProperties };
      const headingInheritedProperties = Object.fromEntries(Object.entries(inheritedBase).filter(([key]) => !(key in headingProperties)));
      const headingId = normalizeId(headingProperties.ID);
      const headingAliases = parseAliasTokens(headingProperties.ROAM_ALIASES || "");
      const headingSnippet = extractSnippetWithLine(lines, i + 1, endExclusive);
      const headingCheckboxProgress = extractCheckboxProgress(lines, i, checkboxEndExclusive, opaqueLines);
      if (!opaqueLines.has(i)) checkboxIssueCollector.add(headingCheckboxProgress, i, checkboxEndExclusive);
      const headingKey = `heading:${file}:${i + 1}`;
      const node: CompiledCorpusNode = {
        key: headingKey,
        kind: "heading",
        file,
        sourceRange: { startLine: i + 1, endLine: Math.max(i + 1, endExclusive) },
        id: headingId,
        title: heading.title,
        level: heading.level,
        priority: heading.priority,
        tags: heading.tags,
        aliases: headingAliases,
        properties: headingProperties,
        effectiveProperties: headingEffectiveProperties,
        inheritedProperties: headingInheritedProperties,
        planning: extractPlanning(lines, i + 1, endExclusive),
        clocks: clocksByNode.get(headingKey) || [],
        clockIssues: clockIssuesByNode.get(headingKey) || [],
        checkboxProgress: headingCheckboxProgress,
        links: extractLinks(lines, i + 1, endExclusive),
        backlinks: [],
        snippet: headingSnippet.snippet,
        snippetStartLine: headingSnippet.startLine,
      };
      if (heading.todo) {
        node.todo = heading.todo;
        if (sequences.length) node.todoTerminal = isTerminalTodoKeyword(heading.todo, sequences);
      }
      const effort = effortFromProperties(headingProperties);
      if (effort) node.effort = effort;
      nodes.push(node);
      headingPropertyStack.push({ level: heading.level, effectiveProperties: headingEffectiveProperties });
    }
    for (const issue of checkboxIssueCollector.issues()) checkboxIssuesByKey.set(`${file}:${issue.line}:${issue.raw}`, { file, ...issue });
  }

  return finalizeCompiledCorpus({
    rootDir,
    corpusFiles,
    sourceNodes: nodes,
    clocks: clockReport.intervals,
    clockIssues: clockReport.issues,
    checkboxProgress: corpusCheckboxProgress,
    checkboxIssues: [...checkboxIssuesByKey.values()].sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
    generatedAt: opts?.generatedAt,
    indexState: {
      mode: "full",
      status: "fresh",
      reusedFiles: 0,
      parsedFiles: corpusFiles.length,
      deletedFiles: 0,
    },
  });
}


type IncrementalCorpusFileFingerprint = {
  todoConfiguration?: string;
  file: string;
  absolutePath: string;
  size: number;
  mtimeMs: number;
  sha256: string;
};

type IncrementalCorpusFragment = {
  fingerprint: IncrementalCorpusFileFingerprint;
  file: CompiledCorpusFile;
  nodes: CompiledCorpusNode[];
  clocks: OrgClockInterval[];
  clockIssues: OrgClockIssue[];
  checkboxProgress: CheckboxProgress;
  checkboxIssues: CompiledCorpus["checkboxIssues"];
};

type IncrementalCorpusCache = {
  schemaVersion: "org2-incremental-corpus-cache/v6";
  rootDir: string;
  files: IncrementalCorpusFileFingerprint[];
  checkboxProgressByFile: Record<string, CheckboxProgress>;
  corpus: CompiledCorpus;
};

function buildEntityIndex(nodes: CompiledCorpusNode[]): CompiledCorpusEntity[] {
  return nodes
    .filter((node) => !!node.entityType)
    .map((node) => ({
      nodeKey: node.key,
      id: node.id,
      title: node.title,
      entityType: node.entityType!,
      file: node.file,
      line: node.sourceRange.startLine,
      source: ((brandProperty(node.properties, "ORG2_ENTITY_TYPE") || node.properties.ENTITY_TYPE) ? "property" : "tag") as "property" | "tag",
    }))
    .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.title.localeCompare(b.title));
}

function parseRelationObject(raw: string): { objectRef: string; objectId: string | null; objectTitle?: string } {
  const value = String(raw || "").trim();
  const idMatch = /(?:^|\s)(?:id:)?([0-9a-fA-F-]{36})(?:\s|::|$)/.exec(value);
  if (idMatch) return { objectRef: `id:${String(idMatch[1]).toLowerCase()}`, objectId: String(idMatch[1]).toLowerCase() };
  const linkMatch = /\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]/.exec(value);
  if (linkMatch) {
    const target = String(linkMatch[1] || "").trim();
    const description = String(linkMatch[2] || "").trim();
    return { objectRef: target, objectId: isUuidIdLinkTarget(target) ? idLinkTargetId(target) : null, ...(description ? { objectTitle: description } : {}) };
  }
  return { objectRef: value, objectId: null };
}

function resolveLinkObject(rawTarget: string, rawDescription: string | undefined, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string } {
  const target = String(rawTarget || "").trim();
  const description = String(rawDescription || "").trim();
  if (isUuidIdLinkTarget(target)) {
    const objectId = idLinkTargetId(target)!;
    return { objectId, objectRef: `id:${objectId}`, objectTitle: description || byId.get(objectId)?.title };
  }
  const candidates = Array.from(labels.get(normalizeLabel(target)) || []);
  const objectId = candidates.length === 1 ? candidates[0] || null : null;
  return { objectId, objectRef: target, objectTitle: description || byId.get(objectId || "")?.title || target };
}

function addRelationOnce(relations: CompiledCorpusRelation[], relation: CompiledCorpusRelation): void {
  const key = `${relation.subjectKey}\0${relation.predicate}\0${relation.objectRef}\0${relation.file}\0${relation.line}\0${relation.method}`;
  if (relations.some((existing) => `${existing.subjectKey}\0${existing.predicate}\0${existing.objectRef}\0${existing.file}\0${existing.line}\0${existing.method}` === key)) return;
  relations.push(relation);
}

function nodeForResolvedObject(object: { objectId: string | null; objectRef: string; objectTitle?: string }, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): CompiledCorpusNode | null {
  if (object.objectId && byId.has(object.objectId)) return byId.get(object.objectId)!;
  const titleCandidates = Array.from(labels.get(normalizeLabel(object.objectTitle || object.objectRef)) || []);
  return titleCandidates.length === 1 ? byId.get(titleCandidates[0]!) || null : null;
}

function resolveObjectByTitle(title: string, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string } | null {
  const normalized = normalizeLabel(title);
  if (!normalized) return null;
  const candidates = Array.from(labels.get(normalized) || []);
  if (candidates.length === 1) {
    const node = byId.get(candidates[0]!);
    if (!node) return null;
    return { objectId: node.id || null, objectRef: node.id ? `id:${node.id}` : title, objectTitle: node.title };
  }

  // Some real corpora contain duplicate canonical notes for the same entity label
  // (for example, an .org and an .org2 version of the same company).  In that
  // case keep the textual object title instead of dropping the relation entirely;
  // title-based relation queries can still answer the question, while ID-based
  // queries stay conservative because there is no single safe ID to choose.
  const matchingNodes = candidates
    .map((id) => byId.get(id))
    .filter((node): node is CompiledCorpusNode => !!node && normalizeLabel(node.title) === normalized);
  if (matchingNodes.length > 1) return { objectId: null, objectRef: title, objectTitle: matchingNodes[0]!.title };
  return null;
}

function inferAdvisedObjectFromEvidence(evidence: string, subjectTitle: string, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): { objectId: string | null; objectRef: string; objectTitle?: string; method: string } | null {
  const escapedSubject = subjectTitle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const patterns: Array<{ re: RegExp; method: string }> = [
    { re: new RegExp(`${escapedSubject}[^.\\n]{0,160}?\\b(?:has\\s+been\\s+)?advis(?:ing|or|er)\\b[^.\\n]{0,80}?\\b(?:startup|company|org(?:anization)?)\\b\\s*,?\\s+([A-Z][A-Za-z0-9&.-]*(?:\\s+[A-Z][A-Za-z0-9&.-]*){0,4})`, "i"), method: "pattern:linked-subject-advising-named-object" },
    { re: new RegExp(`${escapedSubject}[^.\\n]{0,160}?\\b(?:has\\s+been\\s+)?advis(?:ing|or|er)\\b[^.\\n]{0,80}?\\bfor\\b[^.\\n]{0,40}?([A-Z][A-Za-z0-9&.-]*(?:\\s+[A-Z][A-Za-z0-9&.-]*){0,4})`, "i"), method: "pattern:linked-subject-advising-for-object" },
  ];
  for (const pattern of patterns) {
    const match = pattern.re.exec(evidence);
    if (!match) continue;
    const title = String(match[1] || "").trim().replace(/[.,;:]+$/, "");
    const object = resolveObjectByTitle(title, byId, labels);
    if (object) return { ...object, method: pattern.method };
  }
  return null;
}


function inferLinkedTextAdvisorRelationsForNode(relations: CompiledCorpusRelation[], node: CompiledCorpusNode, byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): void {
  const evidence = node.snippet || node.title;
  if (!/\badvis(?:ing|or|er)\b/i.test(evidence)) return;
  for (const candidate of byId.values()) {
    if (candidate.key === node.key) continue;
    if (candidate.entityType && candidate.entityType !== "person") continue;
    if (!candidate.title || candidate.title.length < 4) continue;
    const titlePattern = new RegExp(`\\b${candidate.title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i");
    if (!titlePattern.test(evidence)) continue;
    const advisedObject = inferAdvisedObjectFromEvidence(evidence, candidate.title, byId, labels);
    if (!advisedObject) continue;
    addRelationOnce(relations, {
      subjectKey: candidate.key,
      subjectId: candidate.id,
      subjectTitle: candidate.title,
      predicate: "advisor_to",
      objectId: advisedObject.objectId,
      ...(advisedObject.objectTitle ? { objectTitle: advisedObject.objectTitle } : {}),
      objectRef: advisedObject.objectRef,
      file: node.file,
      line: node.snippetStartLine || node.sourceRange.startLine,
      evidence,
      confidence: "inferred-pattern",
      method: `text-subject:${advisedObject.method}`,
    });
  }
}

function buildRelationIndex(nodes: CompiledCorpusNode[], byId: Map<string, CompiledCorpusNode>, labels: Map<string, Set<string>>): CompiledCorpusRelation[] {
  const relations: CompiledCorpusRelation[] = [];
  const fileNodesByFile = new Map(nodes.filter((node) => node.kind === "file").map((node) => [node.file, node]));
  const relationSubjectForNode = (node: CompiledCorpusNode): CompiledCorpusNode => {
    if (node.kind === "heading" && !node.id && /^(details?|notes?)$/i.test(node.title.trim())) return fileNodesByFile.get(node.file) || node;
    return node;
  };
  for (const node of nodes) {
    inferLinkedTextAdvisorRelationsForNode(relations, node, byId, labels);
    const explicitValues = Object.entries(node.effectiveProperties || node.properties).filter(([key]) => isBrandName(key, "ORG2_RELATION") || /^(?:CELORGA|ORG2)_RELATION_/.test(key));
    for (const [key, value] of explicitValues) {
      const suffix = isBrandName(key, "ORG2_RELATION") ? "" : key.replace(/^(?:CELORGA|ORG2)_RELATION_/, "");
      const parts = String(value || "").trim().split(/\s+/);
      const predicate = normalizePredicate(suffix || parts.shift() || "");
      if (!predicate || parts.length === 0) continue;
      const object = parseRelationObject(parts.join(" "));
      addRelationOnce(relations, {
        subjectKey: node.key,
        subjectId: node.id,
        subjectTitle: node.title,
        predicate,
        objectId: object.objectId,
        ...(object.objectTitle ? { objectTitle: object.objectTitle } : {}),
        objectRef: object.objectRef,
        file: node.file,
        line: node.sourceRange.startLine,
        evidence: `${key}: ${value}`,
        confidence: "explicit",
        method: "property",
      });
    }

    for (const link of node.links) {
      if (link.type !== "id" && link.type !== "wiki") continue;
      const object = resolveLinkObject(link.target, link.description, byId, labels);
      const title = (link.description || link.target).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const evidence = node.snippet || node.title;
      const patterns: Array<{ predicate: string; re: RegExp; method: string }> = [
        { predicate: "advisor_to", re: new RegExp(`\\b(?:advisor|adviser)\\s+(?:for|to|at)\\s+.*${title}`, "i"), method: "pattern:advisor-for-to-at" },
        { predicate: "advisor_to", re: new RegExp(`\\badvising\\s+.*${title}`, "i"), method: "pattern:advising" },
        { predicate: "advisor_to", re: new RegExp(`\\bstrategic\\s+(?:advisor|adviser)\\s+at\\s+.*${title}`, "i"), method: "pattern:strategic-advisor-at" },
      ];
      for (const pattern of patterns) {
        if (!pattern.re.test(evidence)) continue;
        const subject = relationSubjectForNode(node);
        addRelationOnce(relations, {
          subjectKey: subject.key,
          subjectId: subject.id,
          subjectTitle: subject.title,
          predicate: pattern.predicate,
          objectId: object.objectId,
          ...(object.objectTitle ? { objectTitle: object.objectTitle } : {}),
          objectRef: object.objectRef,
          file: node.file,
          line: link.line,
          evidence,
          confidence: "inferred-pattern",
          method: pattern.method,
        });
      }

      const linkedSubjectNode = nodeForResolvedObject(object, byId, labels);
      const linkedSubjectTitle = linkedSubjectNode?.title || object.objectTitle || "";
      if (linkedSubjectNode && linkedSubjectTitle) {
        const advisedObject = inferAdvisedObjectFromEvidence(evidence, linkedSubjectTitle, byId, labels);
        if (advisedObject) {
          addRelationOnce(relations, {
            subjectKey: linkedSubjectNode.key,
            subjectId: linkedSubjectNode.id,
            subjectTitle: linkedSubjectNode.title,
            predicate: "advisor_to",
            objectId: advisedObject.objectId,
            ...(advisedObject.objectTitle ? { objectTitle: advisedObject.objectTitle } : {}),
            objectRef: advisedObject.objectRef,
            file: node.file,
            line: link.line,
            evidence,
            confidence: "inferred-pattern",
            method: advisedObject.method,
          });
        }
      }
    }
  }
  return relations.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.subjectTitle.localeCompare(b.subjectTitle));
}


function buildEntityProfiles(nodes: CompiledCorpusNode[], entities: CompiledCorpusEntity[], relations: CompiledCorpusRelation[], labels: Map<string, Set<string>>): CompiledCorpusEntityProfile[] {
  const byKey = new Map(nodes.map((node) => [node.key, node]));
  const entitiesByNodeKey = new Map(entities.map((entity) => [entity.nodeKey, entity]));
  const groups = new Map<string, CompiledCorpusNode[]>();
  for (const entity of entities) {
    const node = byKey.get(entity.nodeKey);
    if (!node) continue;
    const entityId = node.id || `label:${normalizeLabel(node.title)}`;
    groups.set(entityId, [...(groups.get(entityId) || []), node]);
  }

  const profiles: CompiledCorpusEntityProfile[] = [];
  for (const [entityId, groupNodes] of groups) {
    const primary = [...groupNodes].sort((a, b) => a.title.length - b.title.length || a.title.localeCompare(b.title) || a.file.localeCompare(b.file))[0]!;
    const labelSet = new Set<string>();
    for (const node of groupNodes) for (const label of nodeLabels(node)) labelSet.add(label);
    const normalizedLabels = Array.from(labelSet).map((label) => normalizeLabel(label)).filter(Boolean);
    const nodeKeySet = new Set(groupNodes.map((node) => node.key));
    const mentions = new Map<string, CompiledCorpusEntityProfile["mentions"][number]>();
    const backlinks = new Map<string, CompiledCorpusBacklink>();

    for (const node of groupNodes) {
      for (const backlink of node.backlinks) backlinks.set(`${backlink.sourceKey}:${backlink.line}:${backlink.linkType}`, backlink);
    }
    for (const source of nodes) {
      if (nodeKeySet.has(source.key)) continue;
      for (const link of source.links) {
        if (link.type !== "wiki") continue;
        const label = normalizeLabel(link.target);
        if (!normalizedLabels.includes(label)) continue;
        mentions.set(`${source.key}:${link.line}:${label}`, { sourceKey: source.key, sourceTitle: source.title, file: source.file, line: link.line, label: link.target });
      }
    }

    const factBuckets = new Map<string, Map<string, Array<{ sourceKey: string; file: string; line: number }>>>();
    for (const node of groupNodes) {
      for (const [key, rawValue] of Object.entries(node.effectiveProperties || node.properties)) {
        if (["ID", "ROAM_ALIASES", "ORG2_ENTITY_TYPE", "CELORGA_ENTITY_TYPE", "ENTITY_TYPE"].includes(key)) continue;
        const value = String(rawValue || "").trim();
        if (!value) continue;
        const values = factBuckets.get(key) || new Map();
        values.set(value, [...(values.get(value) || []), { sourceKey: node.key, file: node.file, line: node.sourceRange.startLine }]);
        factBuckets.set(key, values);
      }
    }

    const facts: CompiledCorpusEntityProfile["facts"] = [];
    const reviewNeeded: CompiledCorpusEntityProfile["reviewNeeded"] = [];
    for (const [key, values] of Array.from(factBuckets.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
      const sortedValues = Array.from(values.keys()).sort((a, b) => a.localeCompare(b));
      if (sortedValues.length > 1) reviewNeeded.push({ type: "conflicting-fact", key, values: sortedValues, message: `Conflicting values for ${key}: ${sortedValues.join(" vs ")}` });
      for (const value of sortedValues) facts.push({ key, value, provenance: (values.get(value) || []).sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line) });
    }
    for (const label of normalizedLabels) {
      const candidates = Array.from(labels.get(label) || []);
      if (candidates.length > 1) reviewNeeded.push({ type: "ambiguous-alias", labels: [label], message: `Alias/title '${label}' resolves to multiple entity ids: ${candidates.sort().join(", ")}` });
    }

    profiles.push({
      entityId,
      canonicalName: primary.title,
      type: entitiesByNodeKey.get(primary.key)?.entityType || primary.entityType || "unknown",
      aliases: Array.from(labelSet).filter((label) => normalizeLabel(label) !== normalizeLabel(primary.title)).sort((a, b) => a.localeCompare(b)),
      nodeKeys: Array.from(nodeKeySet).sort(),
      backlinks: Array.from(backlinks.values()).sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
      mentions: Array.from(mentions.values()).sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
      relations: relations.filter((relation) => nodeKeySet.has(relation.subjectKey) || (relation.objectId && relation.objectId === primary.id)).sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
      facts,
      reviewNeeded,
    });
  }
  return profiles.sort((a, b) => a.canonicalName.localeCompare(b.canonicalName) || a.entityId.localeCompare(b.entityId));
}

function buildLookupIndex(nodes: CompiledCorpusNode[]): CompiledCorpusLookupIndex {
  const index: CompiledCorpusLookupIndex = { ids: {}, titles: {}, tags: {}, dates: {}, files: {} };
  const add = (bucket: Record<string, string[]>, key: string, value: string) => { const normalized = normalizeLabel(key); if (!normalized) return; (bucket[normalized] ||= []).push(value); };
  for (const node of nodes) {
    if (node.id) add(index.ids, node.id, node.key);
    add(index.titles, node.title, node.key);
    add(index.files, node.file, node.key);
    for (const tag of node.tags) add(index.tags, tag, node.key);
    for (const plan of node.planning) for (const match of plan.raw.matchAll(/\d{4}-\d{2}-\d{2}/g)) add(index.dates, match[0] || "", node.key);
  }
  for (const bucket of Object.values(index)) for (const key of Object.keys(bucket)) bucket[key] = Array.from(new Set(bucket[key])).sort();
  return index;
}

function fileFingerprint(filePath: string, rootDir: string): IncrementalCorpusFileFingerprint {
  const stat = fs.statSync(filePath);
  return { file: relativePath(rootDir, filePath), absolutePath: filePath, size: stat.size, mtimeMs: stat.mtimeMs, todoConfiguration: todoConfigurationKey(filePath), sha256: "" };
}

function incrementalCorpusBinaryCachePath(cacheFile: string): string {
  return `${cacheFile}.v8`;
}

function readIncrementalCorpusCache(cacheFile: string): IncrementalCorpusCache {
  const binaryPath = incrementalCorpusBinaryCachePath(cacheFile);
  try {
    const binaryStat = fs.statSync(binaryPath);
    const jsonStat = fs.statSync(cacheFile);
    if (binaryStat.mtimeMs >= jsonStat.mtimeMs) {
      return v8.deserialize(fs.readFileSync(binaryPath)) as IncrementalCorpusCache;
    }
  } catch {
    // The JSON representation remains the portable and inspectable fallback.
  }
  return JSON.parse(fs.readFileSync(cacheFile, "utf8")) as IncrementalCorpusCache;
}

function writeIncrementalCorpusCache(cacheFile: string, cache: IncrementalCorpusCache): void {
  fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
  const binaryPath = incrementalCorpusBinaryCachePath(cacheFile);
  const jsonTmpPath = `${cacheFile}.${process.pid}.tmp`;
  const binaryTmpPath = `${binaryPath}.${process.pid}.tmp`;
  fs.writeFileSync(jsonTmpPath, JSON.stringify(cache) + "\n", "utf8");
  fs.writeFileSync(binaryTmpPath, v8.serialize(cache));
  fs.renameSync(jsonTmpPath, cacheFile);
  fs.renameSync(binaryTmpPath, binaryPath);
}

function corpusFragment(
  corpus: CompiledCorpus,
  fingerprint: IncrementalCorpusFileFingerprint,
  checkboxProgress?: CheckboxProgress,
): IncrementalCorpusFragment {
  const file = corpus.files.find((entry) => entry.file === fingerprint.file);
  if (!file) throw new Error(`compiled corpus did not contain ${fingerprint.file}`);
  const progress = checkboxProgress || checkboxProgressForFile(fingerprint.absolutePath);
  return {
    fingerprint,
    file,
    nodes: corpus.nodes
      .filter((node) => node.file === fingerprint.file)
      .map((node) => ({ ...node, backlinks: [] })),
    clocks: corpus.clocks.filter((clock) => clock.file === fingerprint.file),
    clockIssues: corpus.clockIssues.filter((issue) => issue.file === fingerprint.file),
    checkboxProgress: progress,
    checkboxIssues: corpus.checkboxIssues.filter((issue) => issue.file === fingerprint.file),
  };
}

function withIndexState(corpus: CompiledCorpus, state: CompiledCorpusIndexState): CompiledCorpus {
  return { ...corpus, indexState: state };
}

function checkboxProgressForFile(filePath: string): CheckboxProgress {
  const lines = normalizeText(fs.readFileSync(filePath, "utf8")).split("\n");
  return extractCheckboxProgress(lines, 0, lines.length);
}

function cachedFragments(
  cache: IncrementalCorpusCache,
  fingerprints: IncrementalCorpusFileFingerprint[],
): Map<string, IncrementalCorpusFragment> {
  const filesByName = new Map(cache.corpus.files.map((file) => [file.file, file]));
  const nodesByFile = new Map<string, CompiledCorpusNode[]>();
  const clocksByFile = new Map<string, OrgClockInterval[]>();
  const clockIssuesByFile = new Map<string, OrgClockIssue[]>();
  const checkboxIssuesByFile = new Map<string, CompiledCorpus["checkboxIssues"]>();
  for (const node of cache.corpus.nodes) {
    const nodes = nodesByFile.get(node.file) || [];
    nodes.push({ ...node, backlinks: [] });
    nodesByFile.set(node.file, nodes);
  }
  for (const clock of cache.corpus.clocks) {
    const clocks = clocksByFile.get(clock.file) || [];
    clocks.push(clock);
    clocksByFile.set(clock.file, clocks);
  }
  for (const issue of cache.corpus.clockIssues) {
    const issues = clockIssuesByFile.get(issue.file) || [];
    issues.push(issue);
    clockIssuesByFile.set(issue.file, issues);
  }
  for (const issue of cache.corpus.checkboxIssues) {
    const issues = checkboxIssuesByFile.get(issue.file) || [];
    issues.push(issue);
    checkboxIssuesByFile.set(issue.file, issues);
  }
  return new Map(fingerprints.map((fingerprint) => {
    const file = filesByName.get(fingerprint.file);
    const checkboxProgress = cache.checkboxProgressByFile[fingerprint.file];
    if (!file || !checkboxProgress) throw new Error(`incremental cache is missing ${fingerprint.file}`);
    return [fingerprint.absolutePath, {
      fingerprint,
      file,
      nodes: nodesByFile.get(fingerprint.file) || [],
      clocks: clocksByFile.get(fingerprint.file) || [],
      clockIssues: clockIssuesByFile.get(fingerprint.file) || [],
      checkboxProgress,
      checkboxIssues: checkboxIssuesByFile.get(fingerprint.file) || [],
    }];
  }));
}

function assembleIncrementalCorpus(
  rootDir: string,
  fragments: IncrementalCorpusFragment[],
  generatedAt: string | undefined,
  indexState: CompiledCorpusIndexState,
): CompiledCorpus {
  const checkboxProgress: CheckboxProgress = {
    total: 0,
    checked: 0,
    unchecked: 0,
    percent: 0,
    cookies: [],
  };
  for (const fragment of fragments) {
    checkboxProgress.total += fragment.checkboxProgress.total;
    checkboxProgress.checked += fragment.checkboxProgress.checked;
    checkboxProgress.unchecked += fragment.checkboxProgress.unchecked;
  }
  return finalizeCompiledCorpus({
    rootDir,
    corpusFiles: fragments.map((fragment) => fragment.file),
    sourceNodes: fragments.flatMap((fragment) => fragment.nodes),
    clocks: fragments.flatMap((fragment) => fragment.clocks),
    clockIssues: fragments.flatMap((fragment) => fragment.clockIssues)
      .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
    checkboxProgress,
    checkboxIssues: fragments.flatMap((fragment) => fragment.checkboxIssues)
      .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line),
    generatedAt,
    indexState,
  });
}

export function compileCorpusIncremental(files: string[], opts: { rootDir?: string; cacheFile: string; generatedAt?: string }): CompiledCorpus {
  const rootDir = path.resolve(opts.rootDir || process.cwd());
  const sortedFiles = Array.from(new Set(files.map((file) => path.resolve(file)))).sort();
  const cacheFile = path.resolve(opts.cacheFile);
  const current = sortedFiles.map((filePath) => fileFingerprint(filePath, rootDir));
  let cache: IncrementalCorpusCache | null = null;
  let reason: string | undefined;
  try {
    if (fs.existsSync(cacheFile)) {
      const parsed = readIncrementalCorpusCache(cacheFile);
      if (
        parsed.schemaVersion === "org2-incremental-corpus-cache/v6"
        && parsed.rootDir === rootDir
        && Array.isArray(parsed.files)
        && parsed.checkboxProgressByFile
        && parsed.corpus
      ) cache = parsed;
      else reason = "cache schema or rootDir mismatch";
    }
  } catch (err) { reason = `cache unreadable: ${err instanceof Error ? err.message : String(err)}`; }
  const same = cache
    && cache.files.length === current.length
    && current.every((entry, index) => {
      const cached = cache!.files[index];
      return cached
        && cached.file === entry.file
        && cached.absolutePath === entry.absolutePath
        && cached.size === entry.size
        && (cached.todoConfiguration ?? "[]") === entry.todoConfiguration
        && cached.mtimeMs === entry.mtimeMs;
    });
  if (same) {
    return withIndexState(cache!.corpus, {
      mode: "incremental",
      status: "fresh",
      cacheFile,
      reusedFiles: current.length,
      parsedFiles: 0,
      deletedFiles: 0,
    });
  }

  const deletedFiles = cache
    ? cache.files.filter((entry) => !current.some((now) => now.absolutePath === entry.absolutePath)).length
    : 0;
  let result: CompiledCorpus;
  let checkboxProgressByFile: Record<string, CheckboxProgress>;
  let parsedFiles: number;
  let reusedFiles: number;

  if (!cache) {
    const corpus = compileCorpus(sortedFiles, { rootDir, generatedAt: opts.generatedAt });
    parsedFiles = current.length;
    reusedFiles = 0;
    checkboxProgressByFile = Object.fromEntries(
      current.map((fingerprint) => [fingerprint.file, checkboxProgressForFile(fingerprint.absolutePath)]),
    );
    result = withIndexState(corpus, {
      mode: "incremental",
      status: reason ? "stale" : "fresh",
      cacheFile,
      reusedFiles,
      parsedFiles,
      deletedFiles,
      ...(reason ? { reason } : {}),
    });
  } else {
    const previousFingerprints = cache.files.filter((fingerprint) => (
      current.some((entry) => entry.absolutePath === fingerprint.absolutePath)
    ));
    const reusableFragments = cachedFragments(cache, previousFingerprints);
    parsedFiles = 0;
    reusedFiles = 0;
    const fragments = current.map((fingerprint) => {
      const cached = reusableFragments.get(fingerprint.absolutePath);
      if (
        cached
        && cached.fingerprint.file === fingerprint.file
        && cached.fingerprint.size === fingerprint.size
        && (cached.fingerprint.todoConfiguration ?? "[]") === fingerprint.todoConfiguration
        && cached.fingerprint.mtimeMs === fingerprint.mtimeMs
      ) {
        reusedFiles += 1;
        return cached;
      }
      parsedFiles += 1;
      return corpusFragment(
        compileCorpus([fingerprint.absolutePath], { rootDir, generatedAt: opts.generatedAt }),
        fingerprint,
      );
    });
    checkboxProgressByFile = Object.fromEntries(
      fragments.map((fragment) => [fragment.fingerprint.file, fragment.checkboxProgress]),
    );
    result = assembleIncrementalCorpus(rootDir, fragments, opts.generatedAt, {
      mode: "incremental",
      status: reason ? "stale" : "fresh",
      cacheFile,
      reusedFiles,
      parsedFiles,
      deletedFiles,
      ...(reason ? { reason } : {}),
    });
  }

  try {
    writeIncrementalCorpusCache(cacheFile, {
      schemaVersion: "org2-incremental-corpus-cache/v6",
      rootDir,
      files: current,
      checkboxProgressByFile,
      corpus: result,
    });
  } catch (err) {
    result = {
      ...result,
      indexState: {
        ...result.indexState!,
        status: "stale",
        reason: `cache write failed: ${err instanceof Error ? err.message : String(err)}`,
      },
    };
  }
  return result;
}

export function renderCompiledCorpus(corpus: CompiledCorpus, format: "json" | "jsonl" = "json"): string {
  if (format === "jsonl") {
    const header = { schemaVersion: corpus.schemaVersion, generatedBy: corpus.generatedBy, artifact: corpus.artifact, rootDir: corpus.rootDir, stats: corpus.stats, entities: corpus.entities, entityProfiles: corpus.entityProfiles, relations: corpus.relations, index: corpus.index, indexState: corpus.indexState };
    return [header, ...corpus.nodes].map((entry) => JSON.stringify(entry)).join("\n") + "\n";
  }
  return JSON.stringify(corpus, null, 2) + "\n";
}
