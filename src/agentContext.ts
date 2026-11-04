import { parseIsoCalendarDate } from "./calendarDate.js";
import type { CompiledCorpus, CompiledCorpusEntityProfile, CompiledCorpusNode } from "./corpusCompile.js";
import { isActiveTodoKeyword, terminalTodoStatusFromKeyword } from "./todo.js";
import { brandProperty, withNameAliases } from "./brandNames.js";
import { idLinkTargetId } from "./linkSearch.js";

export type AgentInclude = "backlinks" | "neighbors" | "sources";
export type AgentAction = "context" | "search" | "fetch" | "bundle";

export type AgentContextOptions = {
  action: AgentAction;
  query?: string;
  id?: string;
  limit?: number;
  maxChars?: number;
  include?: AgentInclude[];
  scope?: string;
  since?: string;
  sourceType?: string;
  reviewStatus?: string;
  recencyWeight?: number;
  salienceWeight?: number;
};

type AgentSource = {
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
};

type AgentFreshnessState = "fresh" | "stale" | "expired" | "unknown";
type AgentReviewState = "generated" | "review-required" | "reviewed" | "promoted" | "unknown";

type AgentClaimState = {
  reviewStatus: AgentReviewState;
  claimState: string | null;
  observedAt: string | null;
  validAsOf: string | null;
  staleAfter: string | null;
  expiresAt: string | null;
  freshness: AgentFreshnessState;
};

type AgentContextAttachment = {
  type: "id" | "file" | "url" | "session" | "artifact" | "entity" | "report" | "ticket" | "note" | "other";
  ref: string;
  label?: string;
  line?: number;
  source: "property" | "link";
  target?: {
    key: string;
    kind: "file" | "heading";
    id: string | null;
    title: string;
    file: string;
    sourceRange: { startLine: number; endLine: number };
    citation: string;
  };
};

type AgentThreadMetadata = {
  agent?: string;
  session?: string;
  status?: string;
  transcript?: string;
  storage?: "summary" | "transcript" | "external" | "mixed" | "unknown";
  contextAttachments: AgentContextAttachment[];
};

type AgentRelatedThread = {
  key: string;
  id: string | null;
  title: string;
  agent?: string;
  session?: string;
  status?: string;
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  matchingAttachments: AgentContextAttachment[];
};

type AgentDataLinkKind = "data-link" | "warehouse-query" | "dataset" | "sql-view" | "event-stream" | "timeline-link";

type AgentDataSourceHash = {
  kind: "id" | "file" | "query" | "run" | "url" | "note" | "artifact";
  value: string;
  sha256: string;
};

type AgentDataColumn = {
  name: string;
  type?: string;
};

type AgentDataSortKey = {
  field: string;
  direction?: "asc" | "desc";
};

type AgentDataLinkMetadata = {
  kind: AgentDataLinkKind;
  system?: string;
  engine?: string;
  source?: string;
  path?: string;
  database?: string;
  schema?: string;
  table?: string;
  view?: string;
  columns?: AgentDataColumn[];
  primaryKey?: string[];
  partitionBy?: string[];
  sortBy?: AgentDataSortKey[];
  dimensions?: string[];
  measures?: string[];
  grain?: string;
  filters?: string[];
  groupBy?: string[];
  timeColumn?: string;
  timezone?: string;
  credentialRef?: string;
  configRef?: string;
  refreshRef?: string;
  refreshCommand?: string;
  refreshStatus?: string;
  refreshAfter?: string;
  nextRefresh?: string;
  validationStatus?: string;
  validationAt?: string;
  validationBy?: string;
  validationNote?: string;
  confidence?: string;
  validationRefs?: AgentContextAttachment[];
  dataOwner?: string;
  dataSteward?: string;
  sensitivity?: string;
  visibility?: string;
  accessPolicy?: string;
  retention?: string;
  lineageRefs?: AgentContextAttachment[];
  dataContract?: string;
  schemaVersion?: string;
  qualityStatus?: string;
  qualityScore?: number;
  qualityChecks?: string[];
  qualityNote?: string;
  eventStream?: string;
  timeline?: string;
  eventType?: string;
  entity?: string;
  actor?: string;
  occurredAt?: string;
  capturedAt?: string;
  sourceCursor?: string;
  streamPosition?: string;
  partitionKey?: string;
  correlationId?: string;
  causationId?: string;
  changeId?: string;
  changeHash?: string;
  queryId?: string;
  query?: string;
  queryHash?: string;
  params?: unknown;
  paramsRaw?: string;
  artifact?: string;
  result?: string;
  rowCount?: number;
  resultLimit?: number;
  resultOffset?: number;
  sampleSize?: number;
  sampleRate?: string;
  samplingMethod?: string;
  coverage?: string;
  windowStart?: string;
  windowEnd?: string;
  lastRun?: string;
  watermark?: string;
  dataLatency?: string;
  availability?: string;
  backfillStatus?: string;
  freshness?: string;
  materialized?: string;
  provenance?: AgentContextAttachment[];
  sourceHashes?: AgentDataSourceHash[];
};

type AgentRelatedDataLink = {
  key: string;
  id: string | null;
  title: string;
  kind: AgentDataLinkKind;
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  claimState: AgentClaimState;
  dataLink: AgentDataLinkMetadata;
  matchingAttachments?: AgentContextAttachment[];
};

type AgentPolicyGates = {
  requiresHumanApproval?: boolean;
  allowAgentEdit?: boolean;
  allowExternalSend?: boolean;
};

type AgentWorkflowRun = {
  agent?: string;
  session?: string;
  runId?: string;
  startedAt?: string;
  finishedAt?: string;
  log?: string;
  sourceArtifacts?: AgentContextAttachment[];
};

type AgentHandoffState = {
  summary?: string;
  nextAction?: string;
  links?: AgentContextAttachment[];
};

type AgentCollaborationState = {
  owner?: string;
  assignee?: string;
  agent?: string;
  agentRef?: string;
  goalRef?: string;
  nextAction?: string;
  waitingOn?: string;
  lifecycle?: string;
  policy?: AgentPolicyGates;
  run?: AgentWorkflowRun;
  handoff?: AgentHandoffState;
};

type AgentNode = {
  key: string;
  kind: "file" | "heading";
  id: string | null;
  title: string;
  path: string[];
  file: string;
  sourceRange: { startLine: number; endLine: number };
  citation: string;
  level?: number;
  todo?: string;
  todoTerminal?: boolean;
  tags: string[];
  aliases: string[];
  properties: Record<string, string>;
  snippet: string;
  score?: number;
  matchedTerms?: string[];
  selectionReason?: string[];
  claimState: AgentClaimState;
  collaboration?: AgentCollaborationState;
  thread?: AgentThreadMetadata;
  relatedThreads?: AgentRelatedThread[];
  dataLink?: AgentDataLinkMetadata;
  relatedDataLinks?: AgentRelatedDataLink[];
  sources?: AgentSource[];
  backlinks?: Array<{ sourceKey: string; sourceId: string | null; sourceTitle: string; file: string; line: number; citation: string; linkType: "id" | "wiki" }>;
  neighbors?: Array<{ key: string; id: string | null; title: string; file: string; citation: string; direction: "out" | "in"; linkType: "id" | "wiki" }>;
};

type AgentBacklink = NonNullable<AgentNode["backlinks"]>[number];

type AgentCorpusLookup = {
  nodeByKey: Map<string, CompiledCorpusNode>;
  nodeById: Map<string, CompiledCorpusNode>;
  nodeByTitle: Map<string, CompiledCorpusNode>;
  backlinksByTargetKey: Map<string, AgentBacklink[]>;
};

export type AgentPayload = {
  $schema: "org2:agent-context:v1";
  action: AgentAction;
  query?: string;
  id?: string;
  limit: number;
  maxChars: number;
  filters?: { scope?: string; since?: string; sourceType?: string; reviewStatus?: string };
  ranking?: { recencyWeight: number; salienceWeight: number };
  corpus: { schemaVersion: string; rootDir: string; generatedAt: string; stats: CompiledCorpus["stats"] };
  results: AgentNode[];
  entityProfiles?: CompiledCorpusEntityProfile[];
  context?: { text: string; truncated: boolean; charCount: number; citations: AgentSource[] };
  errors: string[];
};

function normalizeId(raw: string | null | undefined): string {
  return String(raw || "").trim().toLowerCase();
}

function citationFor(node: Pick<CompiledCorpusNode, "file" | "sourceRange">): string {
  const end = node.sourceRange.endLine !== node.sourceRange.startLine ? `-${node.sourceRange.endLine}` : "";
  return `${node.file}:${node.sourceRange.startLine}${end}`;
}

function termsFor(query: string): string[] {
  return Array.from(new Set(String(query || "").toLowerCase().match(/[a-z0-9][a-z0-9_-]{1,}/g) || []));
}

function isOperationalContextFile(file: string): boolean {
  const normalized = file.replace(/\\/g, "/").toLowerCase();
  return normalized.startsWith("agents/")
    || normalized.startsWith("views/")
    || normalized.includes("/agents/")
    || normalized.includes("/views/")
    || normalized.includes("sync-conflict")
    || normalized.includes("generated")
    || normalized.includes("brief");
}

function titlePathFor(corpus: CompiledCorpus, node: CompiledCorpusNode): string[] {
  if (node.kind === "file") return [node.title];
  return corpus.nodes
    .filter((candidate) => candidate.file === node.file && candidate.kind === "heading" && candidate.sourceRange.startLine <= node.sourceRange.startLine && (candidate.level || 0) <= (node.level || 0))
    .sort((a, b) => (a.level || 0) - (b.level || 0) || a.sourceRange.startLine - b.sourceRange.startLine)
    .filter((candidate, index, all) => index === all.length - 1 || (candidate.level || 0) < (all[index + 1]!.level || 0))
    .map((candidate) => candidate.title);
}

function propertyValue(node: CompiledCorpusNode, names: string[]): string {
  for (const name of withNameAliases(names)) {
    const value = (node.effectiveProperties || node.properties)[name.toUpperCase()];
    if (value) return value;
  }
  return "";
}

function parseSinceCutoff(raw: string | undefined, now = new Date()): Date | null {
  const value = String(raw || "").trim().toLowerCase();
  if (!value) return null;
  const rel = /^(\d+)([dwmy])$/.exec(value);
  if (rel) {
    const amount = Number.parseInt(rel[1] || "0", 10);
    const unit = rel[2] || "d";
    const days = unit === "w" ? amount * 7 : unit === "m" ? amount * 30 : unit === "y" ? amount * 365 : amount;
    return new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function dateForNode(node: CompiledCorpusNode): Date | null {
  const raw = propertyValue(node, ["UPDATED", "DATE", "CREATED", "CLOSED"]) || node.planning.find((p) => p.kind === "CLOSED")?.raw || node.planning[0]?.raw || "";
  const match = String(raw).match(/\d{4}-\d{2}-\d{2}/);
  if (!match) return null;
  return parseIsoCalendarDate(match[0])?.date ?? null;
}

function nodeMatchesFilters(node: CompiledCorpusNode, opts: AgentContextOptions): boolean {
  if (opts.scope) {
    const raw = opts.scope.trim().toLowerCase();
    const [kind, valueRaw] = raw.includes(":") ? raw.split(/:(.*)/s, 2) : ["", raw];
    const value = (valueRaw || "").trim();
    const haystack = [node.title, node.file, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.values(node.effectiveProperties || node.properties)].join("\n").toLowerCase();
    if (kind === "project" && !node.tags.map((t) => t.toLowerCase()).includes(value) && propertyValue(node, ["PROJECT"]).toLowerCase() !== value && !haystack.includes(value)) return false;
    else if (kind === "person" && propertyValue(node, ["PERSON", "PEOPLE"]).toLowerCase() !== value && !haystack.includes(value)) return false;
    else if (kind === "entity" && !haystack.includes(value)) return false;
    else if (!kind && !haystack.includes(value)) return false;
  }
  if (opts.sourceType) {
    const wanted = opts.sourceType.trim().toLowerCase();
    const actual = (propertyValue(node, ["SOURCE_TYPE", "TYPE"]) || node.file.split(".").pop() || "").toLowerCase();
    if (actual !== wanted) return false;
  }
  if (opts.reviewStatus) {
    const actual = propertyValue(node, ["REVIEW_STATUS", "REVIEW", "STATUS"]).toLowerCase();
    if (actual !== opts.reviewStatus.trim().toLowerCase()) return false;
  }
  const cutoff = parseSinceCutoff(opts.since);
  if (cutoff) {
    const nodeDate = dateForNode(node);
    if (!nodeDate || nodeDate < cutoff) return false;
  }
  return true;
}

function parseDateMs(raw: string | null | undefined): number | null {
  const value = String(raw || "").trim();
  if (!value) return null;
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  const dateTime = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  const match = dateOnly || dateTime;
  if (!match) return null;

  const calendarDate = parseIsoCalendarDate(`${match[1]}-${match[2]}-${match[3]}`);
  if (!calendarDate) return null;

  if (!dateTime) return calendarDate.date.getTime();

  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = match[6] === undefined ? 0 : Number(match[6]);
  if (hour > 23 || minute > 59 || second > 59) return null;
  const timezone = String(match[7] || "");
  if (timezone !== "Z") {
    const [, offsetHourRaw, offsetMinuteRaw] = /^([+-]\d{2}):(\d{2})$/.exec(timezone) || [];
    const offsetHour = Number(String(offsetHourRaw || "").slice(1));
    const offsetMinute = Number(offsetMinuteRaw || "");
    if (offsetHour > 23 || offsetMinute > 59) return null;
  }

  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function claimStateFor(node: CompiledCorpusNode, nowMs = Date.now()): AgentClaimState {
  const props = node.effectiveProperties || node.properties || {};
  const reviewStatus = String(brandProperty(props, "ORG2_REVIEW_STATUS") || "unknown").trim().toLowerCase() as AgentReviewState;
  const observedAt = brandProperty(props, "ORG2_OBSERVED_AT") || null;
  const validAsOf = brandProperty(props, "ORG2_VALID_AS_OF") || null;
  const staleAfter = brandProperty(props, "ORG2_STALE_AFTER") || null;
  const expiresAt = brandProperty(props, "ORG2_EXPIRES_AT") || null;
  const expiresMs = parseDateMs(expiresAt);
  const staleMs = parseDateMs(staleAfter);
  const freshness: AgentFreshnessState = expiresMs !== null && expiresMs < nowMs ? "expired" : staleMs !== null && staleMs < nowMs ? "stale" : (observedAt || validAsOf) ? "fresh" : "unknown";
  return {
    reviewStatus: ["generated", "review-required", "reviewed", "promoted"].includes(reviewStatus) ? reviewStatus : "unknown",
    claimState: brandProperty(props, "ORG2_CLAIM_STATE") || null,
    observedAt,
    validAsOf,
    staleAfter,
    expiresAt,
    freshness,
  };
}

function numericProperty(node: CompiledCorpusNode, names: string[]): number | null {
  const raw = propertyValue(node, names);
  if (!raw) return null;
  if (/^(true|yes|pinned|important)$/i.test(raw)) return 1;
  const parsed = parseStrictNumericValue(raw);
  return parsed ?? null;
}

function recencyScoreFor(node: CompiledCorpusNode, nowMs = Date.now()): { score: number; reason: string | null } {
  const date = dateForNode(node);
  if (!date) return { score: 0, reason: null };
  const ageDays = Math.max(0, (nowMs - date.getTime()) / (24 * 60 * 60 * 1000));
  const score = Math.max(0, 3 - Math.log2(1 + ageDays / 14));
  return { score, reason: `dated ${date.toISOString().slice(0, 10)} (${score.toFixed(2)} recency)` };
}

function salienceScoreFor(node: CompiledCorpusNode, opts: AgentContextOptions, lookup: AgentCorpusLookup): { score: number; reasons: string[] } {
  let score = 0;
  const reasons: string[] = [];
  const explicit = numericProperty(node, ["ORG2_SALIENCE", "SALIENCE", "IMPORTANCE", "PRIORITY"]);
  if (explicit !== null) { score += explicit * 3; reasons.push(`explicit salience ${explicit}`); }
  const pinned = numericProperty(node, ["ORG2_PINNED", "PINNED", "IMPORTANT"]);
  if (pinned !== null && pinned > 0) { score += 4; reasons.push("pinned/important metadata"); }
  if ((node.todoTerminal === undefined ? isActiveTodoKeyword(node.todo) : Boolean(node.todo) && !node.todoTerminal)) { score += 2; reasons.push(`active TODO ${node.todo}`); }
  const activePlanning = node.planning.filter((p) => p.kind === "SCHEDULED" || p.kind === "DEADLINE");
  if (activePlanning.length) { score += Math.min(3, activePlanning.length * 1.5); reasons.push("scheduled/deadline planning"); }
  const backlinkCount = inferredBacklinksFor(lookup, node).length;
  if (backlinkCount) { const backlinkScore = Math.min(3, Math.log2(backlinkCount + 1)); score += backlinkScore; reasons.push(`${backlinkCount} backlink/mention${backlinkCount === 1 ? "" : "s"}`); }
  if (opts.scope) {
    const scope = opts.scope.toLowerCase().replace(/^[^:]+:/, "").trim();
    const values = [propertyValue(node, ["PROJECT", "PERSON", "PEOPLE", "ENTITY"]), ...node.tags, ...node.aliases].join(" ").toLowerCase();
    if (scope && values.includes(scope)) { score += 2; reasons.push(`near scoped entity/project '${scope}'`); }
  }
  return { score, reasons };
}

function scoreNode(node: CompiledCorpusNode, terms: string[], opts: AgentContextOptions, lookup: AgentCorpusLookup): { score: number; matchedTerms: string[]; selectionReason: string[] } {
  const haystack = [node.title, node.snippet, node.id || "", ...node.tags, ...node.aliases, ...Object.keys(node.effectiveProperties || node.properties), ...Object.values(node.effectiveProperties || node.properties)].join("\n").toLowerCase();
  const matchedTerms = terms.filter((term) => haystack.includes(term));
  const selectionReason: string[] = matchedTerms.length ? [`matched ${matchedTerms.length} query term${matchedTerms.length === 1 ? "" : "s"}: ${matchedTerms.join(", ")}`] : [];
  const directScope = opts.scope ? opts.scope.toLowerCase().replace(/^[^:]+:/, "").trim() : "";
  const directlyScoped = Boolean(directScope && [
    propertyValue(node, ["PROJECT", "PERSON", "PEOPLE", "ENTITY"]).toLowerCase(),
    node.title.toLowerCase(),
    node.id || "",
    ...node.tags.map((tag) => tag.toLowerCase()),
    ...node.aliases.map((alias) => alias.toLowerCase()),
  ].some((value) => value === directScope || value.includes(directScope)));
  if (terms.length > 0 && matchedTerms.length === 0 && !directlyScoped) return { score: 0, matchedTerms, selectionReason };
  if (directlyScoped && matchedTerms.length === 0) selectionReason.push(`directly scoped to '${directScope}'`);
  let score = matchedTerms.length;
  for (const term of matchedTerms) {
    if (node.title.toLowerCase().includes(term)) { score += 4; selectionReason.push(`title contains '${term}'`); }
    if ((node.id || "").toLowerCase() === term) { score += 10; selectionReason.push(`id exactly matches '${term}'`); }
    if (node.tags.some((tag) => tag.toLowerCase() === term)) { score += 3; selectionReason.push(`tag matches '${term}'`); }
  }
  const claim = claimStateFor(node);
  if (claim.reviewStatus === "reviewed" || claim.reviewStatus === "promoted") { score += 2; selectionReason.push(`${claim.reviewStatus} claim`); }
  if (claim.freshness === "fresh") { score += 1; selectionReason.push("fresh claim"); }
  if (claim.freshness === "stale") { score -= 2; selectionReason.push("penalized stale claim"); }
  if (claim.freshness === "expired") { score -= 4; selectionReason.push("penalized expired claim"); }
  const recencyWeight = Number.isFinite(opts.recencyWeight) ? opts.recencyWeight! : 1;
  const salienceWeight = Number.isFinite(opts.salienceWeight) ? opts.salienceWeight! : 1;
  const recency = recencyScoreFor(node);
  if (recency.score && recencyWeight) { score += recency.score * recencyWeight; if (recency.reason) selectionReason.push(`${recency.reason} × recency weight ${recencyWeight}`); }
  const salience = salienceScoreFor(node, opts, lookup);
  if (salience.score && salienceWeight) selectionReason.push(...salience.reasons.map((reason) => `${reason} × salience weight ${salienceWeight}`));
  score += salience.score * salienceWeight;
  if (isOperationalContextFile(node.file)) {
    score -= 5;
    selectionReason.push("downranked operational/generated file");
  }
  const terminalTodo = node.todoTerminal === undefined ? terminalTodoStatusFromKeyword(node.todo) : node.todoTerminal ? terminalTodoStatusFromKeyword(node.todo) ?? "done" : undefined;
  if (terminalTodo === "canceled") {
    score -= 5;
    selectionReason.push("downranked canceled task");
  } else if (terminalTodo === "done") {
    score -= 3;
    selectionReason.push("downranked completed task");
  }
  return { score, matchedTerms, selectionReason };
}

function findNodeById(corpus: CompiledCorpus, id: string): CompiledCorpusNode | null {
  const needle = normalizeId(id);
  if (!needle) return null;
  return corpus.nodes.find((node) => normalizeId(node.id) === needle || normalizeId(node.key) === needle) || null;
}

function buildAgentCorpusLookup(corpus: CompiledCorpus): AgentCorpusLookup {
  const nodeByKey = new Map(corpus.nodes.map((candidate) => [candidate.key, candidate]));
  const nodesById = new Map<string, CompiledCorpusNode[]>();
  for (const candidate of corpus.nodes) {
    if (!candidate.id) continue;
    const normalizedId = normalizeId(candidate.id);
    const existing = nodesById.get(normalizedId) || [];
    existing.push(candidate);
    nodesById.set(normalizedId, existing);
  }
  const nodeById = new Map(
    Array.from(nodesById, ([id, candidates]) => [id, candidates[candidates.length - 1]!]),
  );
  const nodeByTitle = new Map(
    corpus.nodes.map((candidate) => [candidate.title.trim().toLowerCase(), candidate]),
  );
  const backlinkMapsByTargetKey = new Map<string, Map<string, AgentBacklink>>();
  const candidateScore = (backlink: AgentBacklink): [number, number, number] => {
    const source = nodeByKey.get(backlink.sourceKey);
    if (!source) return [0, 0, 0];
    const start = source.sourceRange.startLine || 0;
    const span = Math.max(1, (source.sourceRange.endLine || start) - start);
    const level = source.level || (source.kind === "heading" ? 1 : 0);
    return [level, start, -span];
  };
  const addBacklink = (targetKey: string, backlink: AgentBacklink) => {
    let out = backlinkMapsByTargetKey.get(targetKey);
    if (!out) {
      out = new Map<string, AgentBacklink>();
      backlinkMapsByTargetKey.set(targetKey, out);
    }
    const key = `${backlink.file}:${backlink.line}`;
    const existing = out.get(key);
    if (!existing) {
      out.set(key, backlink);
      return;
    }
    const left = candidateScore(backlink);
    const right = candidateScore(existing);
    for (let i = 0; i < left.length; i += 1) {
      if (left[i]! === right[i]!) continue;
      if (left[i]! > right[i]!) out.set(key, backlink);
      return;
    }
  };

  for (const target of corpus.nodes) {
    for (const backlink of target.backlinks) {
      addBacklink(target.key, { ...backlink, citation: `${backlink.file}:${backlink.line}` });
    }
  }

  for (const source of corpus.nodes) {
    for (const link of source.links) {
      const targets = nodesById.get(normalizeId(idLinkTargetId(link.target) ?? link.target)) || [];
      for (const target of targets) {
        if (source.key === target.key) continue;
        addBacklink(target.key, {
          sourceKey: source.key,
          sourceId: source.id,
          sourceTitle: source.title,
          file: source.file,
          line: link.line,
          citation: `${source.file}:${link.line}`,
          linkType: "id",
        });
      }
    }
  }

  const backlinksByTargetKey = new Map(
    Array.from(backlinkMapsByTargetKey, ([targetKey, backlinks]) => [
      targetKey,
      Array.from(backlinks.values()).sort((a, b) => a.citation.localeCompare(b.citation)),
    ]),
  );
  return { nodeByKey, nodeById, nodeByTitle, backlinksByTargetKey };
}

function inferredBacklinksFor(lookup: AgentCorpusLookup, node: CompiledCorpusNode): NonNullable<AgentNode["backlinks"]> {
  return lookup.backlinksByTargetKey.get(node.key) || [];
}

function neighborsFor(lookup: AgentCorpusLookup, node: CompiledCorpusNode): AgentNode["neighbors"] {
  const out = new Map<string, NonNullable<AgentNode["neighbors"]>[number]>();
  for (const link of node.links) {
    const idTarget = link.type === "id" || /^id:/i.test(link.target)
      ? lookup.nodeById.get(normalizeId(idLinkTargetId(link.target)))
      : undefined;
    const target = idTarget || (link.type === "wiki" ? lookup.nodeByTitle.get(link.target.trim().toLowerCase()) : undefined);
    if (!target) continue;
    const linkType = idTarget ? "id" : "wiki";
    out.set(`out:${target.key}`, { key: target.key, id: target.id, title: target.title, file: target.file, citation: citationFor(target), direction: "out", linkType });
  }
  for (const backlink of inferredBacklinksFor(lookup, node)) {
    const source = lookup.nodeByKey.get(backlink.sourceKey);
    if (!source) continue;
    out.set(`in:${source.key}`, { key: source.key, id: source.id, title: source.title, file: source.file, citation: citationFor(source), direction: "in", linkType: backlink.linkType });
  }
  return Array.from(out.values()).sort((a, b) => `${a.direction}:${a.file}:${a.citation}`.localeCompare(`${b.direction}:${b.file}:${b.citation}`));
}

function normalizeTypedKind(raw: string | null | undefined): string {
  return String(raw || "").trim().toLowerCase().replace(/_/g, "-");
}

function kindPropertyFor(node: CompiledCorpusNode): string {
  const props = node.properties || {};
  return normalizeTypedKind(props.KIND || brandProperty(props, "ORG2_KIND") || props.TYPE || brandProperty(props, "ORG2_TYPE"));
}

function isAgentThreadNode(node: CompiledCorpusNode): boolean {
  return kindPropertyFor(node) === "agent-thread";
}

function attachmentTypeFor(raw: string): AgentContextAttachment["type"] {
  const type = raw.trim().toLowerCase().replace(/_/g, "-");
  if (type === "id" || type === "file" || type === "url" || type === "session" || type === "artifact" || type === "entity" || type === "report" || type === "ticket" || type === "note") return type;
  return "other";
}

function parseContextAttachmentToken(raw: string, source: AgentContextAttachment["source"]): AgentContextAttachment | null {
  const value = String(raw || "").trim();
  if (!value) return null;
  const match = /^([A-Za-z][A-Za-z0-9_-]*):(.*)$/.exec(value);
  if (!match) return { type: "other", ref: value, source };
  const prefix = String(match[1] || "").trim();
  const refTail = String(match[2] || "").trim();
  if (!refTail) return null;
  const type = attachmentTypeFor(prefix);
  return { type, ref: `${prefix}:${refTail}`, source };
}

function parseContextAttachmentList(raw: string | undefined): AgentContextAttachment[] {
  if (!raw) return [];
  return String(raw)
    .split(/[;,]/)
    .map((token) => parseContextAttachmentToken(token, "property"))
    .filter((item): item is AgentContextAttachment => !!item);
}

function attachmentFromLink(link: CompiledCorpusNode["links"][number]): AgentContextAttachment | null {
  if (link.type === "id" || /^id:/i.test(link.target)) {
    const target = link.target.replace(/^id:/i, "").trim();
    if (!idLinkTargetId(link.target)) return null;
    return { type: "id", ref: `id:${target}`, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  }
  if (link.type === "file") return { type: "file", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  if (link.type === "url") return { type: "url", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  if (link.type === "wiki") return { type: "note", ref: link.target, ...(link.description ? { label: link.description } : {}), line: link.line, source: "link" };
  return null;
}

function mergeAttachments(attachments: AgentContextAttachment[]): AgentContextAttachment[] {
  const byRef = new Map<string, AgentContextAttachment>();
  for (const attachment of attachments) {
    const key = `${attachment.type}\0${attachment.ref.toLowerCase()}`;
    const existing = byRef.get(key);
    if (!existing) {
      byRef.set(key, attachment);
      continue;
    }
    byRef.set(key, {
      ...existing,
      ...(existing.label ? {} : attachment.label ? { label: attachment.label } : {}),
      ...(existing.line !== undefined ? {} : attachment.line !== undefined ? { line: attachment.line } : {}),
    });
  }
  return Array.from(byRef.values()).sort((a, b) => a.type.localeCompare(b.type) || a.ref.localeCompare(b.ref) || (a.line || 0) - (b.line || 0));
}

function normalizeFileRef(raw: string): string {
  return String(raw || "")
    .trim()
    .replace(/^file:/i, "")
    .replace(/^\.\//, "");
}

function refTail(raw: string): string {
  const value = String(raw || "").trim();
  const match = /^[A-Za-z][A-Za-z0-9_-]*:(.*)$/.exec(value);
  return String(match ? match[1] : value).trim();
}

function nodeHasExactLabel(node: CompiledCorpusNode, raw: string): boolean {
  const needle = normalizeLabel(raw);
  if (!needle) return false;
  return normalizeLabel(node.title) === needle || node.aliases.some((alias) => normalizeLabel(alias) === needle);
}

function attachmentTargetFor(corpus: CompiledCorpus, attachment: AgentContextAttachment): AgentContextAttachment["target"] | undefined {
  let target: CompiledCorpusNode | undefined;
  if (attachment.type === "id") {
    const id = idLinkTargetId(attachment.ref) ?? attachment.ref;
    target = corpus.nodes.find((node) => node.id && normalizeId(node.id) === normalizeId(id));
  } else if (attachment.type === "note") {
    const noteTitle = attachment.ref.trim().toLowerCase();
    target = corpus.nodes.find((node) => node.title.trim().toLowerCase() === noteTitle);
  } else if (attachment.type === "file") {
    const wanted = normalizeFileRef(attachment.ref);
    target = corpus.nodes.find((node) => normalizeFileRef(node.file) === wanted) || corpus.nodes.find((node) => normalizeFileRef(node.file).endsWith(`/${wanted}`));
  } else if (attachment.type !== "url" && attachment.type !== "session") {
    const tail = refTail(attachment.ref);
    target = corpus.nodes.find((node) => (node.id && normalizeId(node.id) === normalizeId(tail)) || nodeHasExactLabel(node, tail));
  }
  if (!target) return undefined;
  return {
    key: target.key,
    kind: target.kind,
    id: target.id,
    title: target.title,
    file: target.file,
    sourceRange: target.sourceRange,
    citation: citationFor(target),
  };
}

function resolveAttachmentTargets(corpus: CompiledCorpus, attachments: AgentContextAttachment[]): AgentContextAttachment[] {
  return attachments.map((attachment) => {
    const target = attachmentTargetFor(corpus, attachment);
    return target ? { ...attachment, target } : attachment;
  });
}

function normalizeThreadStorage(raw: string | undefined): AgentThreadMetadata["storage"] | undefined {
  const value = String(raw || "").trim().toLowerCase();
  if (!value) return undefined;
  if (value === "summary" || value === "transcript" || value === "external" || value === "mixed") return value;
  return "unknown";
}

function agentThreadMetadataFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentThreadMetadata | undefined {
  if (!isAgentThreadNode(node)) return undefined;
  const props = node.effectiveProperties || node.properties || {};
  const propertyAttachments = [
    ...parseContextAttachmentList(props.CONTEXT),
    ...parseContextAttachmentList(brandProperty(props, "ORG2_CONTEXT")),
    ...parseContextAttachmentList(props.CONTEXT_ATTACHMENTS),
    ...parseContextAttachmentList(brandProperty(props, "ORG2_CONTEXT_ATTACHMENTS")),
  ];
  const linkAttachments = node.links.map(attachmentFromLink).filter((item): item is AgentContextAttachment => !!item);
  const contextAttachments = resolveAttachmentTargets(corpus, mergeAttachments([...propertyAttachments, ...linkAttachments]));
  return {
    ...(props.AGENT || brandProperty(props, "ORG2_AGENT") ? { agent: props.AGENT || brandProperty(props, "ORG2_AGENT") } : {}),
    ...(props.SESSION || brandProperty(props, "ORG2_SESSION") ? { session: props.SESSION || brandProperty(props, "ORG2_SESSION") } : {}),
    ...(props.STATUS || brandProperty(props, "ORG2_STATUS") ? { status: props.STATUS || brandProperty(props, "ORG2_STATUS") } : {}),
    ...(props.TRANSCRIPT || props.TRANSCRIPT_ARTIFACT || brandProperty(props, "ORG2_TRANSCRIPT") ? { transcript: props.TRANSCRIPT || props.TRANSCRIPT_ARTIFACT || brandProperty(props, "ORG2_TRANSCRIPT") } : {}),
    ...(normalizeThreadStorage(props.STORAGE || props.TRANSCRIPT_STORAGE || brandProperty(props, "ORG2_STORAGE")) ? { storage: normalizeThreadStorage(props.STORAGE || props.TRANSCRIPT_STORAGE || brandProperty(props, "ORG2_STORAGE")) } : {}),
    contextAttachments,
  };
}

function attachmentMatchesNode(node: CompiledCorpusNode, attachment: AgentContextAttachment): boolean {
  if (attachment.target?.key === node.key) return true;
  if (attachment.type === "id" && node.id && normalizeId(idLinkTargetId(attachment.ref) ?? refTail(attachment.ref)) === normalizeId(node.id)) return true;
  if (attachment.type === "file" && node.kind === "file") {
    const wanted = normalizeFileRef(attachment.ref);
    const actual = normalizeFileRef(node.file);
    return actual === wanted || actual.endsWith(`/${wanted}`);
  }
  if (attachment.type === "note" && nodeHasExactLabel(node, attachment.ref)) return true;
  if (attachment.type !== "url" && attachment.type !== "session") {
    const tail = refTail(attachment.ref);
    return Boolean((node.id && normalizeId(tail) === normalizeId(node.id)) || nodeHasExactLabel(node, tail));
  }
  return false;
}

function relatedThreadsFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentRelatedThread[] {
  if (isAgentThreadNode(node)) return [];
  const out: AgentRelatedThread[] = [];
  for (const candidate of corpus.nodes) {
    if (candidate.key === node.key || !isAgentThreadNode(candidate)) continue;
    const thread = agentThreadMetadataFor(corpus, candidate);
    if (!thread) continue;
    const matchingAttachments = thread.contextAttachments.filter((attachment) => attachmentMatchesNode(node, attachment));
    if (matchingAttachments.length === 0) continue;
    out.push({
      key: candidate.key,
      id: candidate.id,
      title: candidate.title,
      ...(thread.agent ? { agent: thread.agent } : {}),
      ...(thread.session ? { session: thread.session } : {}),
      ...(thread.status ? { status: thread.status } : {}),
      file: candidate.file,
      sourceRange: candidate.sourceRange,
      citation: citationFor(candidate),
      matchingAttachments,
    });
  }
  return out.sort((a, b) => a.title.localeCompare(b.title) || a.citation.localeCompare(b.citation));
}

function dataLinkKindFor(node: CompiledCorpusNode): AgentDataLinkKind | null {
  const kind = kindPropertyFor(node);
  if (kind === "data-link" || kind === "warehouse-query" || kind === "dataset" || kind === "sql-view" || kind === "event-stream" || kind === "timeline-link") return kind;
  return null;
}

function parseDataParams(raw: string | undefined): Pick<AgentDataLinkMetadata, "params" | "paramsRaw"> {
  const value = String(raw || "").trim();
  if (!value) return {};
  try {
    return { params: JSON.parse(value) };
  } catch {
    return { paramsRaw: value };
  }
}

function formatDataParams(dataLink: AgentDataLinkMetadata): string | null {
  if (dataLink.params !== undefined) {
    const formatted = JSON.stringify(dataLink.params);
    return formatted === undefined ? null : formatted;
  }
  return dataLink.paramsRaw || null;
}

function parseStrictNumericValue(raw: string): number | null {
  const normalized = String(raw).replace(/,/g, "").trim();
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(normalized)) return null;
  const parsed = Number.parseFloat(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

function numericDataProperty(props: Record<string, string>, names: string[]): number | undefined {
  for (const name of withNameAliases(names)) {
    const raw = props[name];
    if (!raw) continue;
    const parsed = parseStrictNumericValue(raw);
    if (parsed !== null) return parsed;
  }
  return undefined;
}

function stringDataProperty(props: Record<string, string>, names: string[]): string | undefined {
  for (const name of withNameAliases(names)) {
    const value = String(props[name] || "").trim();
    if (value) return value;
  }
  return undefined;
}

function safeCredentialRef(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  if (!value || /^none$/i.test(value)) return undefined;
  return /^(?:env|secret|config|profile):[A-Za-z0-9_.:-]+$/.test(value) ? value : undefined;
}

function safeConfigRef(raw: string | undefined): string | undefined {
  const value = String(raw || "").trim();
  if (!value) return undefined;
  return /^(?:config|profile|env|file):[A-Za-z0-9_./:-]+$/.test(value) ? value : undefined;
}

function parseDataColumns(raw: string | undefined): AgentDataColumn[] {
  if (!raw) return [];
  return String(raw)
    .split(/[,;]+/)
    .map((entry) => {
      const value = entry.trim();
      if (!value) return null;
      const match = /^([A-Za-z_][A-Za-z0-9_.-]*)(?::([A-Za-z][A-Za-z0-9_./()-]*))?$/.exec(value);
      if (!match) return null;
      const type = String(match[2] || "").trim();
      return {
        name: String(match[1] || "").trim(),
        ...(type ? { type } : {}),
      } satisfies AgentDataColumn;
    })
    .filter((entry): entry is AgentDataColumn => !!entry);
}

function parseDataNameList(raw: string | undefined): string[] {
  if (!raw) return [];
  return String(raw)
    .split(/[,;]+/)
    .map((entry) => entry.trim())
    .filter((entry) => /^[A-Za-z_][A-Za-z0-9_.-]*$/.test(entry));
}

function parseDataLabelList(raw: string | undefined): string[] {
  if (!raw) return [];
  return String(raw)
    .split(/[,;]+/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function parseDataClauseList(raw: string | undefined): string[] {
  const value = String(raw || "").trim();
  if (!value) return [];
  return value
    .split(/;+/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function parseDataSortList(raw: string | undefined): AgentDataSortKey[] {
  if (!raw) return [];
  return String(raw)
    .split(/[,;]+/)
    .map((entry) => {
      const value = entry.trim();
      if (!value) return null;
      const match = /^([+-]?)([A-Za-z_][A-Za-z0-9_.-]*)(?:(?::|\s+)(asc|desc))?$/i.exec(value);
      if (!match) return null;
      const prefix = match[1] || "";
      const direction = String(match[3] || "").toLowerCase();
      return {
        field: String(match[2] || "").trim(),
        ...(direction === "asc" || direction === "desc" ? { direction } : prefix === "+" ? { direction: "asc" as const } : prefix === "-" ? { direction: "desc" as const } : {}),
      } satisfies AgentDataSortKey;
    })
    .filter((entry): entry is AgentDataSortKey => !!entry);
}

function parseDataSourceHashes(raw: string | undefined): AgentDataSourceHash[] {
  if (!raw) return [];
  return String(raw)
    .split(/[,;]+/)
    .map((entry) => {
      const match = /^([A-Za-z][A-Za-z0-9_-]*):(\S.+)=sha256:([a-fA-F0-9]{64})$/.exec(entry.trim());
      if (!match) return null;
      const kind = String(match[1] || "").toLowerCase();
      if (kind !== "id" && kind !== "file" && kind !== "query" && kind !== "run" && kind !== "url" && kind !== "note" && kind !== "artifact") return null;
      return { kind, value: String(match[2] || "").trim(), sha256: String(match[3] || "").toLowerCase() } satisfies AgentDataSourceHash;
    })
    .filter((entry): entry is AgentDataSourceHash => !!entry);
}

function dataLinkMetadataFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentDataLinkMetadata | undefined {
  const kind = dataLinkKindFor(node);
  if (!kind) return undefined;
  const props = node.effectiveProperties || node.properties || {};
  const rowCount = numericDataProperty(props, ["ROW_COUNT", "ROWS", "ORG2_ROW_COUNT"]);
  const system = stringDataProperty(props, ["SYSTEM", "SOURCE_SYSTEM", "ORG2_SYSTEM"]);
  const engine = stringDataProperty(props, ["ENGINE", "ORG2_ENGINE"]);
  const source = stringDataProperty(props, ["SOURCE", "DATA_SOURCE", "URI", "URL"]);
  const sourcePath = stringDataProperty(props, ["PATH", "FILE"]);
  const database = stringDataProperty(props, ["DATABASE", "DB", "CATALOG", "ORG2_DATABASE"]);
  const schema = stringDataProperty(props, ["SCHEMA", "NAMESPACE", "ORG2_SCHEMA"]);
  const table = stringDataProperty(props, ["TABLE", "TABLE_NAME", "RELATION", "ORG2_TABLE"]);
  const view = stringDataProperty(props, ["VIEW", "VIEW_NAME", "SQL_VIEW", "ORG2_VIEW"]);
  const columns = parseDataColumns(stringDataProperty(props, ["COLUMNS", "FIELDS", "ORG2_COLUMNS"]));
  const primaryKey = parseDataNameList(stringDataProperty(props, ["PRIMARY_KEY", "PRIMARY_KEYS", "PK", "KEY_COLUMNS", "ORG2_PRIMARY_KEY"]));
  const partitionBy = parseDataNameList(stringDataProperty(props, ["PARTITION_BY", "PARTITION_KEYS", "PARTITIONS", "ORG2_PARTITION_BY"]));
  const sortBy = parseDataSortList(stringDataProperty(props, ["SORT_BY", "ORDER_BY", "ORG2_SORT_BY"]));
  const dimensions = parseDataNameList(stringDataProperty(props, ["DIMENSIONS", "DIMENSION_KEYS", "GROUP_BY", "ORG2_DIMENSIONS"]));
  const measures = parseDataNameList(stringDataProperty(props, ["MEASURES", "METRICS", "ORG2_MEASURES"]));
  const grain = stringDataProperty(props, ["GRAIN", "TIME_GRAIN", "ORG2_GRAIN"]);
  const filters = parseDataClauseList(stringDataProperty(props, ["FILTER", "FILTERS", "FILTER_BY", "WHERE", "WHERE_CLAUSES", "ORG2_FILTERS"]));
  const groupBy = parseDataNameList(stringDataProperty(props, ["GROUP_BY", "GROUP_KEYS", "GROUP_BY_KEYS", "ORG2_GROUP_BY"]));
  const timeColumn = stringDataProperty(props, ["TIME_COLUMN", "TIMESTAMP_COLUMN", "DATE_COLUMN", "ORG2_TIME_COLUMN"]);
  const timezone = stringDataProperty(props, ["TIMEZONE", "TIME_ZONE", "ORG2_TIMEZONE"]);
  const credentialRef = safeCredentialRef(stringDataProperty(props, ["CREDENTIAL_REF", "CREDENTIAL", "CREDENTIALS", "AUTH_REF", "AUTH"]));
  const configRef = safeConfigRef(stringDataProperty(props, ["CONFIG_REF", "CONFIG", "PROFILE"]));
  const refreshRef = stringDataProperty(props, ["REFRESH_REF", "REFRESH_ID", "REFRESH_JOB", "ORG2_REFRESH_REF"]);
  const refreshCommand = stringDataProperty(props, ["REFRESH_COMMAND", "REFRESH_CMD", "ORG2_REFRESH_COMMAND"]);
  const refreshStatus = stringDataProperty(props, ["REFRESH_STATUS", "REFRESH_STATE", "ORG2_REFRESH_STATUS"]);
  const refreshAfter = stringDataProperty(props, ["REFRESH_AFTER", "REFRESH_TTL", "ORG2_REFRESH_AFTER"]);
  const nextRefresh = stringDataProperty(props, ["NEXT_REFRESH", "REFRESH_DUE", "ORG2_NEXT_REFRESH"]);
  const validationStatus = stringDataProperty(props, ["VALIDATION_STATUS", "VALIDATION_STATE", "ORG2_VALIDATION_STATUS"]);
  const validationAt = stringDataProperty(props, ["VALIDATION_AT", "VALIDATED_AT", "ORG2_VALIDATION_AT"]);
  const validationBy = stringDataProperty(props, ["VALIDATION_BY", "VALIDATED_BY", "ORG2_VALIDATION_BY"]);
  const validationNote = stringDataProperty(props, ["VALIDATION_NOTE", "VALIDATION_NOTES", "ORG2_VALIDATION_NOTE"]);
  const confidence = stringDataProperty(props, ["CONFIDENCE", "CONFIDENCE_SCORE", "ORG2_CONFIDENCE"]);
  const validationRefs = resolveAttachmentTargets(corpus, mergeAttachments([
    ...parseContextAttachmentList(stringDataProperty(props, ["VALIDATION_REF", "VALIDATION_REFS", "ORG2_VALIDATION_REFS"])),
  ]));
  const dataOwner = stringDataProperty(props, ["DATA_OWNER", "DATASET_OWNER", "ORG2_DATA_OWNER"]);
  const dataSteward = stringDataProperty(props, ["DATA_STEWARD", "STEWARD", "ORG2_DATA_STEWARD"]);
  const sensitivity = stringDataProperty(props, ["SENSITIVITY", "DATA_SENSITIVITY", "ORG2_SENSITIVITY"]);
  const visibility = stringDataProperty(props, ["VISIBILITY", "DATA_VISIBILITY", "ORG2_VISIBILITY"]);
  const accessPolicy = stringDataProperty(props, ["ACCESS_POLICY", "ACCESS", "DATA_ACCESS", "ORG2_ACCESS_POLICY"]);
  const retention = stringDataProperty(props, ["RETENTION", "RETENTION_POLICY", "DATA_RETENTION", "ORG2_RETENTION"]);
  const lineageRefs = resolveAttachmentTargets(corpus, mergeAttachments([
    ...parseContextAttachmentList(stringDataProperty(props, ["LINEAGE_REF", "LINEAGE_REFS", "DATA_LINEAGE", "UPSTREAM_REF", "UPSTREAM_REFS", "DERIVED_FROM", "ORG2_LINEAGE_REFS"])),
  ]));
  const dataContract = stringDataProperty(props, ["DATA_CONTRACT", "CONTRACT", "CONTRACT_REF", "ORG2_DATA_CONTRACT"]);
  const schemaVersion = stringDataProperty(props, ["SCHEMA_VERSION", "DATA_SCHEMA_VERSION", "ORG2_SCHEMA_VERSION"]);
  const qualityStatus = stringDataProperty(props, ["QUALITY_STATUS", "QUALITY_STATE", "DATA_QUALITY", "ORG2_QUALITY_STATUS"]);
  const qualityScore = numericDataProperty(props, ["QUALITY_SCORE", "DATA_QUALITY_SCORE", "ORG2_QUALITY_SCORE"]);
  const qualityChecks = parseDataLabelList(stringDataProperty(props, ["QUALITY_CHECKS", "DATA_QUALITY_CHECKS", "ORG2_QUALITY_CHECKS"]));
  const qualityNote = stringDataProperty(props, ["QUALITY_NOTE", "QUALITY_NOTES", "DATA_QUALITY_NOTE", "ORG2_QUALITY_NOTE"]);
  const eventStream = stringDataProperty(props, ["EVENT_STREAM", "STREAM", "STREAM_ID"]);
  const timeline = stringDataProperty(props, ["TIMELINE", "TIMELINE_ID"]);
  const eventType = stringDataProperty(props, ["EVENT_TYPE", "EVENT_KIND"]);
  const entity = stringDataProperty(props, ["SUBJECT", "ENTITY", "ENTITY_ID"]);
  const actor = stringDataProperty(props, ["ACTOR", "AUTHOR", "USER"]);
  const occurredAt = stringDataProperty(props, ["OCCURRED_AT", "EVENT_AT", "OBSERVED_AT"]);
  const capturedAt = stringDataProperty(props, ["CAPTURED_AT", "INGESTED_AT", "CREATED_AT"]);
  const sourceCursor = stringDataProperty(props, ["SOURCE_CURSOR", "CURSOR", "OFFSET"]);
  const streamPosition = stringDataProperty(props, ["STREAM_POSITION", "EVENT_SEQUENCE", "SEQUENCE", "SEQ"]);
  const partitionKey = stringDataProperty(props, ["PARTITION_KEY", "EVENT_PARTITION", "PARTITION"]);
  const correlationId = stringDataProperty(props, ["CORRELATION_ID", "TRACE_ID"]);
  const causationId = stringDataProperty(props, ["CAUSATION_ID", "CAUSE_ID", "PARENT_EVENT_ID"]);
  const changeId = stringDataProperty(props, ["CHANGE_ID", "EVENT_ID", "SOURCE_EVENT_ID"]);
  const changeHash = stringDataProperty(props, ["CHANGE_HASH", "EVENT_HASH"]);
  const queryId = stringDataProperty(props, ["QUERY_ID", "SQL_ID", "VIEW_ID"]);
  const query = stringDataProperty(props, ["QUERY", "SQL"]);
  const queryHash = stringDataProperty(props, ["QUERY_HASH", "HASH", "SOURCE_HASH"]);
  const artifact = stringDataProperty(props, ["ARTIFACT", "RESULT_ARTIFACT", "OUTPUT"]);
  const result = stringDataProperty(props, ["RESULT", "RESULTS", "MATERIALIZED_RESULT"]);
  const resultLimit = numericDataProperty(props, ["RESULT_LIMIT", "LIMIT", "ROW_LIMIT", "ORG2_RESULT_LIMIT"]);
  const resultOffset = numericDataProperty(props, ["RESULT_OFFSET", "OFFSET", "ROW_OFFSET", "ORG2_RESULT_OFFSET"]);
  const sampleSize = numericDataProperty(props, ["SAMPLE_SIZE", "SAMPLED_ROWS", "ORG2_SAMPLE_SIZE"]);
  const sampleRate = stringDataProperty(props, ["SAMPLE_RATE", "SAMPLE_PERCENT", "ORG2_SAMPLE_RATE"]);
  const samplingMethod = stringDataProperty(props, ["SAMPLING_METHOD", "SAMPLE_METHOD", "ORG2_SAMPLING_METHOD"]);
  const coverage = stringDataProperty(props, ["COVERAGE", "DATA_COVERAGE", "ORG2_COVERAGE"]);
  const windowStart = stringDataProperty(props, ["WINDOW_START", "START_AT", "FROM", "ORG2_WINDOW_START"]);
  const windowEnd = stringDataProperty(props, ["WINDOW_END", "END_AT", "THROUGH", "TO", "ORG2_WINDOW_END"]);
  const lastRun = stringDataProperty(props, ["LAST_RUN", "RAN_AT", "UPDATED_AT", "ORG2_LAST_RUN"]);
  const watermark = stringDataProperty(props, ["WATERMARK", "DATA_WATERMARK", "MAX_EVENT_AT", "MAX_OBSERVED_AT", "ORG2_WATERMARK"]);
  const dataLatency = stringDataProperty(props, ["DATA_LATENCY", "LATENCY", "LAG", "DATA_LAG", "ORG2_DATA_LATENCY"]);
  const availability = stringDataProperty(props, ["AVAILABILITY", "AVAILABILITY_STATUS", "DATA_AVAILABILITY", "ORG2_AVAILABILITY"]);
  const backfillStatus = stringDataProperty(props, ["BACKFILL_STATUS", "BACKFILL", "ORG2_BACKFILL_STATUS"]);
  const freshness = stringDataProperty(props, ["FRESHNESS", "STATUS"]);
  const materialized = stringDataProperty(props, ["MATERIALIZED", "MATERIALIZATION"]);
  const provenance = resolveAttachmentTargets(corpus, mergeAttachments([
    ...parseContextAttachmentList(stringDataProperty(props, ["ORG2_PROVENANCE", "PROVENANCE"])),
  ]));
  const sourceHashes = parseDataSourceHashes(stringDataProperty(props, ["ORG2_SOURCE_HASHES", "SOURCE_HASHES"]));
  return {
    kind,
    ...(system ? { system } : {}),
    ...(engine ? { engine } : {}),
    ...(source ? { source } : {}),
    ...(sourcePath ? { path: sourcePath } : {}),
    ...(database ? { database } : {}),
    ...(schema ? { schema } : {}),
    ...(table ? { table } : {}),
    ...(view ? { view } : {}),
    ...(columns.length ? { columns } : {}),
    ...(primaryKey.length ? { primaryKey } : {}),
    ...(partitionBy.length ? { partitionBy } : {}),
    ...(sortBy.length ? { sortBy } : {}),
    ...(dimensions.length ? { dimensions } : {}),
    ...(measures.length ? { measures } : {}),
    ...(grain ? { grain } : {}),
    ...(filters.length ? { filters } : {}),
    ...(groupBy.length ? { groupBy } : {}),
    ...(timeColumn ? { timeColumn } : {}),
    ...(timezone ? { timezone } : {}),
    ...(credentialRef ? { credentialRef } : {}),
    ...(configRef ? { configRef } : {}),
    ...(refreshRef ? { refreshRef } : {}),
    ...(refreshCommand ? { refreshCommand } : {}),
    ...(refreshStatus ? { refreshStatus } : {}),
    ...(refreshAfter ? { refreshAfter } : {}),
    ...(nextRefresh ? { nextRefresh } : {}),
    ...(validationStatus ? { validationStatus } : {}),
    ...(validationAt ? { validationAt } : {}),
    ...(validationBy ? { validationBy } : {}),
    ...(validationNote ? { validationNote } : {}),
    ...(confidence ? { confidence } : {}),
    ...(validationRefs.length ? { validationRefs } : {}),
    ...(dataOwner ? { dataOwner } : {}),
    ...(dataSteward ? { dataSteward } : {}),
    ...(sensitivity ? { sensitivity } : {}),
    ...(visibility ? { visibility } : {}),
    ...(accessPolicy ? { accessPolicy } : {}),
    ...(retention ? { retention } : {}),
    ...(lineageRefs.length ? { lineageRefs } : {}),
    ...(dataContract ? { dataContract } : {}),
    ...(schemaVersion ? { schemaVersion } : {}),
    ...(qualityStatus ? { qualityStatus } : {}),
    ...(qualityScore !== undefined ? { qualityScore } : {}),
    ...(qualityChecks.length ? { qualityChecks } : {}),
    ...(qualityNote ? { qualityNote } : {}),
    ...(eventStream ? { eventStream } : {}),
    ...(timeline ? { timeline } : {}),
    ...(eventType ? { eventType } : {}),
    ...(entity ? { entity } : {}),
    ...(actor ? { actor } : {}),
    ...(occurredAt ? { occurredAt } : {}),
    ...(capturedAt ? { capturedAt } : {}),
    ...(sourceCursor ? { sourceCursor } : {}),
    ...(streamPosition ? { streamPosition } : {}),
    ...(partitionKey ? { partitionKey } : {}),
    ...(correlationId ? { correlationId } : {}),
    ...(causationId ? { causationId } : {}),
    ...(changeId ? { changeId } : {}),
    ...(changeHash ? { changeHash } : {}),
    ...(queryId ? { queryId } : {}),
    ...(query ? { query } : {}),
    ...(queryHash ? { queryHash } : {}),
    ...parseDataParams(stringDataProperty(props, ["PARAMS", "PARAMETERS", "ARGS"])),
    ...(artifact ? { artifact } : {}),
    ...(result ? { result } : {}),
    ...(rowCount !== undefined ? { rowCount } : {}),
    ...(resultLimit !== undefined ? { resultLimit } : {}),
    ...(resultOffset !== undefined ? { resultOffset } : {}),
    ...(sampleSize !== undefined ? { sampleSize } : {}),
    ...(sampleRate ? { sampleRate } : {}),
    ...(samplingMethod ? { samplingMethod } : {}),
    ...(coverage ? { coverage } : {}),
    ...(windowStart ? { windowStart } : {}),
    ...(windowEnd ? { windowEnd } : {}),
    ...(lastRun ? { lastRun } : {}),
    ...(watermark ? { watermark } : {}),
    ...(dataLatency ? { dataLatency } : {}),
    ...(availability ? { availability } : {}),
    ...(backfillStatus ? { backfillStatus } : {}),
    ...(freshness ? { freshness } : {}),
    ...(materialized ? { materialized } : {}),
    ...(provenance.length ? { provenance } : {}),
    ...(sourceHashes.length ? { sourceHashes } : {}),
  };
}

function booleanProperty(props: Record<string, string>, names: string[]): boolean | undefined {
  for (const name of withNameAliases(names)) {
    if (!(name in props)) continue;
    const value = String(props[name] || "").trim().toLowerCase();
    if (/^(1|true|yes|y|on|allow|allowed|required)$/i.test(value)) return true;
    if (/^(0|false|no|n|off|deny|denied|blocked|forbid|forbidden)$/i.test(value)) return false;
  }
  return undefined;
}

function policyHasValues(policy: AgentPolicyGates): boolean {
  return Object.values(policy).some((value) => value !== undefined);
}

function runHasValues(run: AgentWorkflowRun): boolean {
  return Object.values(run).some((value) => Array.isArray(value) ? value.length > 0 : value !== undefined);
}

function handoffHasValues(handoff: AgentHandoffState): boolean {
  return Object.values(handoff).some((value) => Array.isArray(value) ? value.length > 0 : Boolean(value));
}

function collaborationStateFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentCollaborationState | undefined {
  const props = node.properties || {};
  const owner = stringDataProperty(props, ["OWNER", "ORG2_OWNER"]);
  const assignee = stringDataProperty(props, ["ASSIGNEE", "ASSIGNED_TO", "ORG2_ASSIGNEE"]);
  const agent = stringDataProperty(props, ["AGENT", "ORG2_AGENT"]);
  const agentRef = stringDataProperty(props, ["AGENT_REF", "ORG2_AGENT_REF"]);
  const goalRef = stringDataProperty(props, ["GOAL_REF", "ORG2_GOAL_REF"]);
  const nextAction = stringDataProperty(props, ["NEXT_ACTION", "NEXT", "ORG2_NEXT_ACTION"]);
  const waitingOn = stringDataProperty(props, ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"]);
  const lifecycle = stringDataProperty(props, ["LIFECYCLE", "WORKFLOW_STATE", "WORKFLOW_STATUS", "STATE", "ORG2_LIFECYCLE"]);
  const policy: AgentPolicyGates = {
    ...(booleanProperty(props, ["REQUIRES_HUMAN_APPROVAL", "HUMAN_APPROVAL_REQUIRED", "ORG2_REQUIRES_HUMAN_APPROVAL"]) !== undefined
      ? { requiresHumanApproval: booleanProperty(props, ["REQUIRES_HUMAN_APPROVAL", "HUMAN_APPROVAL_REQUIRED", "ORG2_REQUIRES_HUMAN_APPROVAL"]) }
      : {}),
    ...(booleanProperty(props, ["ALLOW_AGENT_EDIT", "AGENT_EDIT_ALLOWED", "ORG2_ALLOW_AGENT_EDIT"]) !== undefined
      ? { allowAgentEdit: booleanProperty(props, ["ALLOW_AGENT_EDIT", "AGENT_EDIT_ALLOWED", "ORG2_ALLOW_AGENT_EDIT"]) }
      : {}),
    ...(booleanProperty(props, ["ALLOW_EXTERNAL_SEND", "EXTERNAL_SEND_ALLOWED", "ORG2_ALLOW_EXTERNAL_SEND"]) !== undefined
      ? { allowExternalSend: booleanProperty(props, ["ALLOW_EXTERNAL_SEND", "EXTERNAL_SEND_ALLOWED", "ORG2_ALLOW_EXTERNAL_SEND"]) }
      : {}),
  };
  const sourceArtifacts = resolveAttachmentTargets(
    corpus,
    mergeAttachments([
      ...parseUntypedAttachmentList(props.SOURCE_ARTIFACT, "artifact"),
      ...parseUntypedAttachmentList(props.SOURCE_ARTIFACTS, "artifact"),
      ...parseUntypedAttachmentList(props.SOURCES, "artifact"),
    ]),
  );
  const run: AgentWorkflowRun = {
    ...(agent ? { agent } : {}),
    ...(stringDataProperty(props, ["SESSION", "ORG2_SESSION"]) ? { session: stringDataProperty(props, ["SESSION", "ORG2_SESSION"]) } : {}),
    ...(stringDataProperty(props, ["RUN_ID", "ORG2_RUN_ID"]) ? { runId: stringDataProperty(props, ["RUN_ID", "ORG2_RUN_ID"]) } : {}),
    ...(stringDataProperty(props, ["STARTED_AT", "RUN_STARTED_AT", "ORG2_STARTED_AT"]) ? { startedAt: stringDataProperty(props, ["STARTED_AT", "RUN_STARTED_AT", "ORG2_STARTED_AT"]) } : {}),
    ...(stringDataProperty(props, ["FINISHED_AT", "RUN_FINISHED_AT", "ORG2_FINISHED_AT"]) ? { finishedAt: stringDataProperty(props, ["FINISHED_AT", "RUN_FINISHED_AT", "ORG2_FINISHED_AT"]) } : {}),
    ...(stringDataProperty(props, ["RUN_LOG", "TOOL_LOG", "LOG", "ORG2_RUN_LOG"]) ? { log: stringDataProperty(props, ["RUN_LOG", "TOOL_LOG", "LOG", "ORG2_RUN_LOG"]) } : {}),
    ...(sourceArtifacts.length ? { sourceArtifacts } : {}),
  };
  const handoffLinks = resolveAttachmentTargets(
    corpus,
    mergeAttachments([
      ...parseUntypedAttachmentList(props.HANDOFF_LINK, "other"),
      ...parseUntypedAttachmentList(props.HANDOFF_LINKS, "other"),
    ]),
  );
  const handoff: AgentHandoffState = {
    ...(stringDataProperty(props, ["HANDOFF", "HANDOFF_SUMMARY", "CURRENT_STATE"]) ? { summary: stringDataProperty(props, ["HANDOFF", "HANDOFF_SUMMARY", "CURRENT_STATE"]) } : {}),
    ...(stringDataProperty(props, ["HANDOFF_NEXT_ACTION"]) || nextAction ? { nextAction: stringDataProperty(props, ["HANDOFF_NEXT_ACTION"]) || nextAction } : {}),
    ...(handoffLinks.length ? { links: handoffLinks } : {}),
  };
  const state: AgentCollaborationState = {
    ...(owner ? { owner } : {}),
    ...(assignee ? { assignee } : {}),
    ...(agent ? { agent } : {}),
    ...(agentRef ? { agentRef } : {}),
    ...(goalRef ? { goalRef } : {}),
    ...(nextAction ? { nextAction } : {}),
    ...(waitingOn ? { waitingOn } : {}),
    ...(lifecycle ? { lifecycle } : {}),
    ...(policyHasValues(policy) ? { policy } : {}),
    ...(runHasValues(run) ? { run } : {}),
    ...(handoffHasValues(handoff) ? { handoff } : {}),
  };
  return Object.keys(state).length ? state : undefined;
}

function parseUntypedAttachmentList(raw: string | undefined, defaultType: AgentContextAttachment["type"] = "other"): AgentContextAttachment[] {
  if (!raw) return [];
  return String(raw)
    .split(/[;,]/)
    .map((token) => {
      const value = token.trim();
      if (!value) return null;
      if (/^[A-Za-z][A-Za-z0-9_-]*:/.test(value)) return parseContextAttachmentToken(value, "property");
      return { type: defaultType, ref: defaultType === "other" ? value : `${defaultType}:${value}`, source: "property" };
    })
    .filter((item): item is AgentContextAttachment => !!item);
}

function dataLinkAttachmentsFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentContextAttachment[] {
  if (!dataLinkKindFor(node)) return [];
  const props = node.properties || {};
  const propertyAttachments = [
    ...parseContextAttachmentList(props.CONTEXT),
    ...parseContextAttachmentList(brandProperty(props, "ORG2_CONTEXT")),
    ...parseContextAttachmentList(props.CONTEXT_ATTACHMENTS),
    ...parseContextAttachmentList(brandProperty(props, "ORG2_CONTEXT_ATTACHMENTS")),
    ...parseUntypedAttachmentList(props.TARGET),
    ...parseUntypedAttachmentList(props.TARGETS),
    ...parseUntypedAttachmentList(props.TARGET_ID, "id"),
    ...parseUntypedAttachmentList(props.TARGET_IDS, "id"),
    ...parseUntypedAttachmentList(props.RELATED),
    ...parseUntypedAttachmentList(props.RELATED_TO),
    ...parseUntypedAttachmentList(props.ATTACHED_TO),
    ...parseUntypedAttachmentList(props.REPORT, "report"),
    ...parseUntypedAttachmentList(props.REPORT_ID, "report"),
    ...parseUntypedAttachmentList(props.NOTE, "note"),
    ...parseUntypedAttachmentList(props.NOTE_ID, "note"),
    ...parseUntypedAttachmentList(props.ENTITY, "entity"),
    ...parseUntypedAttachmentList(props.ENTITY_ID, "entity"),
  ];
  const linkAttachments = node.links.map(attachmentFromLink).filter((item): item is AgentContextAttachment => !!item);
  return resolveAttachmentTargets(corpus, mergeAttachments([...propertyAttachments, ...linkAttachments]));
}

function headingSubtreeEndLine(corpus: CompiledCorpus, node: CompiledCorpusNode): number {
  if (node.kind !== "heading") return Number.POSITIVE_INFINITY;
  const nextPeerOrAncestor = corpus.nodes
    .filter((candidate) => candidate.file === node.file && candidate.kind === "heading" && candidate.sourceRange.startLine > node.sourceRange.startLine && (candidate.level || 0) <= (node.level || 0))
    .sort((a, b) => a.sourceRange.startLine - b.sourceRange.startLine)[0];
  return nextPeerOrAncestor ? nextPeerOrAncestor.sourceRange.startLine - 1 : Number.POSITIVE_INFINITY;
}

function isDescendantDataLink(corpus: CompiledCorpus, node: CompiledCorpusNode, candidate: CompiledCorpusNode): boolean {
  if (candidate.key === node.key || candidate.file !== node.file || !dataLinkKindFor(candidate)) return false;
  if (node.kind === "file") return true;
  if (candidate.kind !== "heading") return false;
  const nodeLevel = node.level || 0;
  const candidateLevel = candidate.level || 0;
  return candidate.sourceRange.startLine > node.sourceRange.startLine && candidate.sourceRange.startLine <= headingSubtreeEndLine(corpus, node) && candidateLevel > nodeLevel;
}

function relatedDataLinksFor(corpus: CompiledCorpus, node: CompiledCorpusNode): AgentRelatedDataLink[] {
  if (dataLinkKindFor(node)) return [];
  const out = new Map<string, AgentRelatedDataLink>();
  for (const candidate of corpus.nodes) {
    if (candidate.key === node.key || !dataLinkKindFor(candidate)) continue;
    const descendant = isDescendantDataLink(corpus, node, candidate);
    const matchingAttachments = descendant ? [] : dataLinkAttachmentsFor(corpus, candidate).filter((attachment) => attachmentMatchesNode(node, attachment));
    if (!descendant && matchingAttachments.length === 0) continue;
    const dataLink = dataLinkMetadataFor(corpus, candidate);
    if (!dataLink) continue;
    out.set(candidate.key, {
      key: candidate.key,
      id: candidate.id,
      title: candidate.title,
      kind: dataLink.kind,
      file: candidate.file,
      sourceRange: candidate.sourceRange,
      citation: citationFor(candidate),
      claimState: claimStateFor(candidate),
      dataLink,
      ...(matchingAttachments.length ? { matchingAttachments } : {}),
    });
  }
  return Array.from(out.values()).sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
}

function toAgentNode(corpus: CompiledCorpus, node: CompiledCorpusNode, include: Set<AgentInclude>, lookup: AgentCorpusLookup, score?: { score: number; matchedTerms: string[]; selectionReason?: string[] }): AgentNode {
  const source = { file: node.file, sourceRange: node.sourceRange, citation: citationFor(node) };
  const thread = agentThreadMetadataFor(corpus, node);
  const relatedThreads = relatedThreadsFor(corpus, node);
  const dataLink = dataLinkMetadataFor(corpus, node);
  const relatedDataLinks = relatedDataLinksFor(corpus, node);
  const collaboration = collaborationStateFor(corpus, node);
  return {
    key: node.key,
    kind: node.kind,
    id: node.id,
    title: node.title,
    path: titlePathFor(corpus, node),
    file: node.file,
    sourceRange: node.sourceRange,
    citation: source.citation,
    ...(node.level !== undefined ? { level: node.level } : {}),
    ...(node.todo ? { todo: node.todo } : {}),
    ...(node.todoTerminal !== undefined ? { todoTerminal: node.todoTerminal } : {}),
    tags: node.tags,
    aliases: node.aliases,
    properties: node.effectiveProperties || node.properties,
    snippet: node.snippet,
    ...(score ? { score: score.score, matchedTerms: score.matchedTerms, selectionReason: score.selectionReason || [] } : {}),
    claimState: claimStateFor(node),
    ...(collaboration ? { collaboration } : {}),
    ...(thread ? { thread } : {}),
    ...(relatedThreads.length ? { relatedThreads } : {}),
    ...(dataLink ? { dataLink } : {}),
    ...(relatedDataLinks.length ? { relatedDataLinks } : {}),
    ...(include.has("sources") ? { sources: [source] } : {}),
    ...(include.has("backlinks") ? { backlinks: inferredBacklinksFor(lookup, node) } : {}),
    ...(include.has("neighbors") ? { neighbors: neighborsFor(lookup, node) } : {}),
  };
}


function normalizeLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function profilesForSelection(corpus: CompiledCorpus, selectedNodes: CompiledCorpusNode[], query = ""): CompiledCorpusEntityProfile[] {
  const keys = new Set(selectedNodes.map((node) => node.key));
  const queryLabel = normalizeLabel(query);
  const out = new Map<string, CompiledCorpusEntityProfile>();
  for (const profile of corpus.entityProfiles || []) {
    const labels = [profile.canonicalName, ...profile.aliases].map(normalizeLabel);
    if (profile.nodeKeys.some((key) => keys.has(key)) || (queryLabel && labels.includes(queryLabel))) out.set(profile.entityId, profile);
  }
  return Array.from(out.values()).sort((a, b) => a.canonicalName.localeCompare(b.canonicalName) || a.entityId.localeCompare(b.entityId));
}

function escapeMarkdown(raw: string): string {
  return String(raw || "").replace(/[\`]/g, "\\$&");
}

function uniqueSorted(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || "").trim()).filter(Boolean))).sort((a, b) => a.localeCompare(b));
}

function dateStringForAgentNode(node: AgentNode): string {
  const explicit = String(node.properties.UPDATED || node.properties.DATE || node.properties.CREATED || node.properties.CLOSED || node.claimState.validAsOf || node.claimState.observedAt || "");
  const explicitMatch = explicit.match(/\d{4}-\d{2}-\d{2}/);
  if (explicitMatch) return explicitMatch[0] || "";
  const fileMatch = String(node.file || node.citation || "").match(/(\d{4})[-_](\d{2})[-_](\d{2})/);
  if (fileMatch) return `${fileMatch[1]}-${fileMatch[2]}-${fileMatch[3]}`;
  return "";
}

export function isStaleOpenAgentTodo(node: AgentNode, nowMs = Date.now()): boolean {
  if (!(node.todoTerminal === undefined ? isActiveTodoKeyword(node.todo) : Boolean(node.todo) && !node.todoTerminal)) return false;
  const date = dateStringForAgentNode(node);
  if (!date) return false;
  const parsed = parseIsoCalendarDate(date);
  if (!parsed) return false;
  const ageDays = Math.max(0, (nowMs - parsed.date.getTime()) / (24 * 60 * 60 * 1000));
  return ageDays > 365;
}

export function renderAgentContextPack(payload: AgentPayload, format: "markdown" | "org" = "markdown"): string {
  const isOrg = format === "org";
  const h1 = isOrg ? "*" : "#";
  const h2 = isOrg ? "**" : "##";
  const h3 = isOrg ? "***" : "###";
  const lines: string[] = [];
  const query = payload.query || payload.id || "";
  const results = payload.results || [];
  const timeline = results
    .map((node) => ({ node, date: String(node.properties.UPDATED || node.properties.DATE || node.properties.CREATED || node.properties.CLOSED || node.claimState.validAsOf || node.claimState.observedAt || "") }))
    .filter((item) => /\d{4}-\d{2}-\d{2}/.test(item.date))
    .sort((a, b) => b.date.localeCompare(a.date) || a.node.citation.localeCompare(b.node.citation))
    .slice(0, 8);
  const todos = results.filter((node) => (node.todoTerminal === undefined ? isActiveTodoKeyword(node.todo) : Boolean(node.todo) && !node.todoTerminal) && !isStaleOpenAgentTodo(node));
  const staleTodos = results.filter((node) => isStaleOpenAgentTodo(node));
  const collaborationStates = results
    .filter((node): node is AgentNode & { collaboration: AgentCollaborationState } => Boolean(node.collaboration))
    .sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
  const entityValues = uniqueSorted(results.flatMap((node) => [node.properties.PROJECT, node.properties.PERSON, node.properties.PEOPLE, ...node.tags, ...node.aliases]));
  const backlinkValues = uniqueSorted(results.flatMap((node) => (node.backlinks || []).map((link) => `${link.sourceTitle} (${link.citation})`)));
  const relatedThreads = Array.from(
    results
      .flatMap((node) => node.relatedThreads || [])
      .reduce((byKey, thread) => byKey.set(thread.key, thread), new Map<string, AgentRelatedThread>())
      .values(),
  ).sort((a, b) => a.title.localeCompare(b.title) || a.citation.localeCompare(b.citation));
  const selectedThreads = results
    .filter((node): node is AgentNode & { thread: AgentThreadMetadata } => Boolean(node.thread))
    .sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
  const directDataLinks: AgentRelatedDataLink[] = results
    .filter((node): node is AgentNode & { dataLink: AgentDataLinkMetadata } => Boolean(node.dataLink))
    .map((node) => ({
      key: node.key,
      id: node.id,
      title: node.title,
      kind: node.dataLink.kind,
      file: node.file,
      sourceRange: node.sourceRange,
      citation: node.citation,
      claimState: node.claimState,
      dataLink: node.dataLink,
    }));
  const relatedDataLinks = Array.from(
    [...directDataLinks, ...results.flatMap((node) => node.relatedDataLinks || [])]
      .reduce((byKey, dataLink) => byKey.set(dataLink.key, dataLink), new Map<string, AgentRelatedDataLink>())
      .values(),
  ).sort((a, b) => a.citation.localeCompare(b.citation) || a.title.localeCompare(b.title));
  const profiles = payload.entityProfiles || [];
  const caveats = uniqueSorted([
    ...(payload.errors || []),
    ...(payload.context?.truncated ? [`Context text truncated at ${payload.maxChars} characters/budget.`] : []),
    ...results.filter((node) => node.claimState.freshness === "stale" || node.claimState.freshness === "expired").map((node) => `${node.title} is ${node.claimState.freshness} (${node.citation})`),
    ...(results.length === 0 ? ["No matching notes found for this query."] : []),
  ]);

  lines.push(`${h1} Celorga Context Pack`);
  lines.push("");
  lines.push(`${h2} Objective / query`);
  lines.push(query ? `- ${escapeMarkdown(query)}` : "- (not provided)");
  lines.push(`- Budget: ${payload.maxChars} chars`);
  lines.push(`- Corpus: ${payload.corpus.rootDir}`);
  lines.push("");
  lines.push(`${h2} Top cited notes`);
  if (results.length === 0) lines.push("- None");
  for (const node of results) {
    lines.push(`${h3} ${escapeMarkdown(node.title)}`);
    lines.push(`- Citation: ${node.citation}`);
    if (node.id) lines.push(`- ID: ${node.id}`);
    if (node.todo) lines.push(`- TODO: ${node.todo}`);
    if (node.tags.length) lines.push(`- Tags: ${node.tags.join(", ")}`);
    lines.push(`- Review/freshness: ${node.claimState.reviewStatus} / ${node.claimState.freshness}`);
    if (node.selectionReason?.length) lines.push(`- Selected because: ${node.selectionReason.join("; ")}`);
    lines.push("");
    lines.push(node.snippet || "(no snippet)");
    lines.push("");
  }
  lines.push(`${h2} Recent timeline entries`);
  if (timeline.length === 0) lines.push("- None found");
  for (const item of timeline) lines.push(`- ${item.date.match(/\d{4}-\d{2}-\d{2}/)?.[0] || item.date}: ${item.node.title} (${item.node.citation})`);
  lines.push("");
  lines.push(`${h2} Active TODOs / scheduled items`);
  if (todos.length === 0) lines.push("- None found");
  for (const node of todos) lines.push(`- ${node.todo} ${node.title} (${node.citation})`);
  lines.push("");
  lines.push(`${h2} Possible stale open TODOs`);
  if (staleTodos.length === 0) lines.push("- None found");
  for (const node of staleTodos.slice(0, 8)) lines.push(`- ${node.todo} ${node.title} (${node.citation})`);
  lines.push("");
  lines.push(`${h2} Collaboration state`);
  if (collaborationStates.length === 0) lines.push("- None found");
  for (const node of collaborationStates) {
    const state = node.collaboration;
    const details = [
      state.owner ? `owner: ${state.owner}` : "",
      state.assignee ? `assignee: ${state.assignee}` : "",
      state.agent ? `agent: ${state.agent}` : "",
      state.agentRef ? `agent ref: ${state.agentRef}` : "",
      state.goalRef ? `goal ref: ${state.goalRef}` : "",
      state.lifecycle ? `lifecycle: ${state.lifecycle}` : "",
      state.nextAction ? `next: ${state.nextAction}` : "",
      state.waitingOn ? `waiting on: ${state.waitingOn}` : "",
    ].filter(Boolean);
    lines.push(`- ${node.title} (${node.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
    if (state.policy) {
      const gates = [
        state.policy.requiresHumanApproval !== undefined ? `human approval: ${state.policy.requiresHumanApproval ? "required" : "not required"}` : "",
        state.policy.allowAgentEdit !== undefined ? `agent edit: ${state.policy.allowAgentEdit ? "allowed" : "not allowed"}` : "",
        state.policy.allowExternalSend !== undefined ? `external send: ${state.policy.allowExternalSend ? "allowed" : "not allowed"}` : "",
      ].filter(Boolean);
      if (gates.length) lines.push(`  - Policy: ${gates.join("; ")}`);
    }
    if (state.run) {
      const sourceArtifacts = uniqueSorted((state.run.sourceArtifacts || []).map((attachment) => attachment.ref));
      const runDetails = [
        state.run.session ? `session: ${state.run.session}` : "",
        state.run.runId ? `run: ${state.run.runId}` : "",
        state.run.startedAt ? `started: ${state.run.startedAt}` : "",
        state.run.finishedAt ? `finished: ${state.run.finishedAt}` : "",
        state.run.log ? `log: ${state.run.log}` : "",
        sourceArtifacts.length ? `sources: ${sourceArtifacts.join(", ")}` : "",
      ].filter(Boolean);
      if (runDetails.length) lines.push(`  - Run: ${runDetails.join("; ")}`);
    }
    if (state.handoff) {
      const handoffLinks = uniqueSorted((state.handoff.links || []).map((attachment) => attachment.ref));
      const handoffDetails = [
        state.handoff.summary ? `summary: ${state.handoff.summary}` : "",
        state.handoff.nextAction ? `next: ${state.handoff.nextAction}` : "",
        handoffLinks.length ? `links: ${handoffLinks.join(", ")}` : "",
      ].filter(Boolean);
      if (handoffDetails.length) lines.push(`  - Handoff: ${handoffDetails.join("; ")}`);
    }
  }
  lines.push("");
  lines.push(`${h2} Related entities and backlinks`);
  if (entityValues.length === 0 && backlinkValues.length === 0) lines.push("- None found");
  for (const value of entityValues) lines.push(`- Entity: ${value}`);
  for (const profile of profiles) {
    lines.push(`- Profile: ${profile.canonicalName} (${profile.type})${profile.aliases.length ? `; aliases: ${profile.aliases.join(", ")}` : ""}`);
    if (profile.reviewNeeded.length) lines.push(`  - Review needed: ${profile.reviewNeeded.map((item) => item.message).join("; ")}`);
  }
  for (const value of backlinkValues.slice(0, 12)) lines.push(`- Backlink: ${value}`);
  lines.push("");
  lines.push(`${h2} Selected agent threads`);
  if (selectedThreads.length === 0) lines.push("- None found");
  for (const node of selectedThreads) {
    const thread = node.thread;
    const details = [
      thread.agent ? `agent: ${thread.agent}` : "",
      thread.session ? `session: ${thread.session}` : "",
      thread.status ? `status: ${thread.status}` : "",
      thread.storage ? `storage: ${thread.storage}` : "",
      thread.transcript ? `transcript: ${thread.transcript}` : "",
    ].filter(Boolean);
    lines.push(`- ${node.title} (${node.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
    if (thread.contextAttachments.length === 0) {
      lines.push("  - Context attachments: none");
    } else {
      lines.push("  - Context attachments:");
      for (const attachment of thread.contextAttachments) {
        const target = attachment.target ? ` -> ${attachment.target.title} (${attachment.target.citation})` : "";
        const label = attachment.label ? `; label: ${attachment.label}` : "";
        lines.push(`    - ${attachment.ref}${label}${target}`);
      }
    }
  }
  lines.push("");
  lines.push(`${h2} Related agent threads`);
  if (relatedThreads.length === 0) lines.push("- None found");
  for (const thread of relatedThreads) {
    const details = [
      thread.id ? `id: ${thread.id}` : "",
      thread.agent ? `agent: ${thread.agent}` : "",
      thread.session ? `session: ${thread.session}` : "",
      thread.status ? `status: ${thread.status}` : "",
    ].filter(Boolean);
    const attachments = uniqueSorted(thread.matchingAttachments.map((attachment) => attachment.ref));
    lines.push(`- ${thread.title} (${thread.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
    if (attachments.length) lines.push(`  - Matching attachments: ${attachments.join(", ")}`);
  }
  lines.push("");
  lines.push(`${h2} Related data links`);
  if (relatedDataLinks.length === 0) lines.push("- None found");
  for (const item of relatedDataLinks) {
    const formattedParams = formatDataParams(item.dataLink);
    const details = [
      `kind: ${item.kind}`,
      item.id ? `id: ${item.id}` : "",
      item.claimState.reviewStatus !== "unknown" ? `review: ${item.claimState.reviewStatus}` : "",
      item.claimState.freshness !== "unknown" ? `claim freshness: ${item.claimState.freshness}` : "",
      item.dataLink.system ? `system: ${item.dataLink.system}` : "",
      item.dataLink.engine ? `engine: ${item.dataLink.engine}` : "",
      item.dataLink.database ? `database: ${item.dataLink.database}` : "",
      item.dataLink.schema ? `schema: ${item.dataLink.schema}` : "",
      item.dataLink.table ? `table: ${item.dataLink.table}` : "",
      item.dataLink.view ? `view: ${item.dataLink.view}` : "",
      item.dataLink.columns?.length ? `columns: ${item.dataLink.columns.map((column) => column.type ? `${column.name}:${column.type}` : column.name).join(", ")}` : "",
      item.dataLink.primaryKey?.length ? `primary key: ${item.dataLink.primaryKey.join(", ")}` : "",
      item.dataLink.partitionBy?.length ? `partition by: ${item.dataLink.partitionBy.join(", ")}` : "",
      item.dataLink.sortBy?.length ? `sort by: ${item.dataLink.sortBy.map((sort) => sort.direction ? `${sort.field}:${sort.direction}` : sort.field).join(", ")}` : "",
      item.dataLink.dimensions?.length ? `dimensions: ${item.dataLink.dimensions.join(", ")}` : "",
      item.dataLink.measures?.length ? `measures: ${item.dataLink.measures.join(", ")}` : "",
      item.dataLink.grain ? `grain: ${item.dataLink.grain}` : "",
      item.dataLink.filters?.length ? `filters: ${item.dataLink.filters.join("; ")}` : "",
      item.dataLink.groupBy?.length ? `group by: ${item.dataLink.groupBy.join(", ")}` : "",
      item.dataLink.timeColumn ? `time column: ${item.dataLink.timeColumn}` : "",
      item.dataLink.timezone ? `timezone: ${item.dataLink.timezone}` : "",
      item.dataLink.credentialRef ? `credential: ${item.dataLink.credentialRef}` : "",
      item.dataLink.configRef ? `config: ${item.dataLink.configRef}` : "",
      item.dataLink.refreshRef ? `refresh ref: ${item.dataLink.refreshRef}` : "",
      item.dataLink.refreshCommand ? `refresh command: ${item.dataLink.refreshCommand}` : "",
      item.dataLink.refreshStatus ? `refresh status: ${item.dataLink.refreshStatus}` : "",
      item.dataLink.refreshAfter ? `refresh after: ${item.dataLink.refreshAfter}` : "",
      item.dataLink.nextRefresh ? `next refresh: ${item.dataLink.nextRefresh}` : "",
      item.dataLink.validationStatus ? `validation: ${item.dataLink.validationStatus}` : "",
      item.dataLink.validationAt ? `validated at: ${item.dataLink.validationAt}` : "",
      item.dataLink.validationBy ? `validated by: ${item.dataLink.validationBy}` : "",
      item.dataLink.confidence ? `confidence: ${item.dataLink.confidence}` : "",
      item.dataLink.validationNote ? `validation note: ${item.dataLink.validationNote}` : "",
      item.dataLink.validationRefs?.length ? `validation refs: ${item.dataLink.validationRefs.map((ref) => ref.ref).join(", ")}` : "",
      item.dataLink.dataOwner ? `data owner: ${item.dataLink.dataOwner}` : "",
      item.dataLink.dataSteward ? `data steward: ${item.dataLink.dataSteward}` : "",
      item.dataLink.sensitivity ? `sensitivity: ${item.dataLink.sensitivity}` : "",
      item.dataLink.visibility ? `visibility: ${item.dataLink.visibility}` : "",
      item.dataLink.accessPolicy ? `access: ${item.dataLink.accessPolicy}` : "",
      item.dataLink.retention ? `retention: ${item.dataLink.retention}` : "",
      item.dataLink.lineageRefs?.length ? `lineage: ${item.dataLink.lineageRefs.map((ref) => ref.ref).join(", ")}` : "",
      item.dataLink.dataContract ? `contract: ${item.dataLink.dataContract}` : "",
      item.dataLink.schemaVersion ? `schema version: ${item.dataLink.schemaVersion}` : "",
      item.dataLink.qualityStatus ? `quality: ${item.dataLink.qualityStatus}` : "",
      item.dataLink.qualityScore !== undefined ? `quality score: ${item.dataLink.qualityScore}` : "",
      item.dataLink.qualityChecks?.length ? `quality checks: ${item.dataLink.qualityChecks.join(", ")}` : "",
      item.dataLink.qualityNote ? `quality note: ${item.dataLink.qualityNote}` : "",
      item.dataLink.eventStream ? `stream: ${item.dataLink.eventStream}` : "",
      item.dataLink.timeline ? `timeline: ${item.dataLink.timeline}` : "",
      item.dataLink.eventType ? `event: ${item.dataLink.eventType}` : "",
      item.dataLink.entity ? `entity: ${item.dataLink.entity}` : "",
      item.dataLink.actor ? `actor: ${item.dataLink.actor}` : "",
      item.dataLink.occurredAt ? `occurred: ${item.dataLink.occurredAt}` : "",
      item.dataLink.capturedAt ? `captured: ${item.dataLink.capturedAt}` : "",
      item.dataLink.sourceCursor ? `cursor: ${item.dataLink.sourceCursor}` : "",
      item.dataLink.streamPosition ? `position: ${item.dataLink.streamPosition}` : "",
      item.dataLink.partitionKey ? `partition: ${item.dataLink.partitionKey}` : "",
      item.dataLink.correlationId ? `correlation: ${item.dataLink.correlationId}` : "",
      item.dataLink.causationId ? `causation: ${item.dataLink.causationId}` : "",
      item.dataLink.changeId ? `change: ${item.dataLink.changeId}` : "",
      item.dataLink.changeHash ? `hash: ${item.dataLink.changeHash}` : "",
      item.dataLink.source ? `source: ${item.dataLink.source}` : "",
      item.dataLink.path ? `path: ${item.dataLink.path}` : "",
      item.dataLink.queryId ? `query: ${item.dataLink.queryId}` : "",
      item.dataLink.query ? `query text: ${item.dataLink.query}` : "",
      item.dataLink.queryHash ? `query hash: ${item.dataLink.queryHash}` : "",
      formattedParams ? `params: ${formattedParams}` : "",
      item.dataLink.artifact ? `artifact: ${item.dataLink.artifact}` : "",
      item.dataLink.result ? `result: ${item.dataLink.result}` : "",
      item.dataLink.rowCount !== undefined ? `rows: ${item.dataLink.rowCount}` : "",
      item.dataLink.resultLimit !== undefined ? `limit: ${item.dataLink.resultLimit}` : "",
      item.dataLink.resultOffset !== undefined ? `offset: ${item.dataLink.resultOffset}` : "",
      item.dataLink.sampleSize !== undefined ? `sample size: ${item.dataLink.sampleSize}` : "",
      item.dataLink.sampleRate ? `sample rate: ${item.dataLink.sampleRate}` : "",
      item.dataLink.samplingMethod ? `sampling: ${item.dataLink.samplingMethod}` : "",
      item.dataLink.coverage ? `coverage: ${item.dataLink.coverage}` : "",
      item.dataLink.windowStart ? `window start: ${item.dataLink.windowStart}` : "",
      item.dataLink.windowEnd ? `window end: ${item.dataLink.windowEnd}` : "",
      item.dataLink.lastRun ? `last run: ${item.dataLink.lastRun}` : "",
      item.dataLink.watermark ? `watermark: ${item.dataLink.watermark}` : "",
      item.dataLink.dataLatency ? `data latency: ${item.dataLink.dataLatency}` : "",
      item.dataLink.availability ? `availability: ${item.dataLink.availability}` : "",
      item.dataLink.backfillStatus ? `backfill: ${item.dataLink.backfillStatus}` : "",
      item.dataLink.freshness ? `freshness: ${item.dataLink.freshness}` : "",
      item.dataLink.materialized ? `materialized: ${item.dataLink.materialized}` : "",
      item.dataLink.provenance?.length ? `provenance: ${item.dataLink.provenance.map((ref) => ref.ref).join(", ")}` : "",
      item.dataLink.sourceHashes?.length ? `source hashes: ${item.dataLink.sourceHashes.map((hash) => `${hash.kind}:${hash.value}=sha256:${hash.sha256.slice(0, 12)}`).join(", ")}` : "",
    ].filter(Boolean);
    const attachments = uniqueSorted((item.matchingAttachments || []).map((attachment) => attachment.ref));
    lines.push(`- ${item.title} (${item.citation})${details.length ? `; ${details.join("; ")}` : ""}`);
    if (attachments.length) lines.push(`  - Matching attachments: ${attachments.join(", ")}`);
  }
  lines.push("");
  lines.push(`${h2} Open questions / known uncertainty`);
  if (caveats.length === 0) lines.push("- None surfaced by Celorga; verify any task-specific assumptions before acting.");
  for (const caveat of caveats) lines.push(`- ${caveat}`);
  lines.push("");
  lines.push(`${h2} Suggested next actions`);
  if (results.length === 0) lines.push("- Broaden the query or scope and regenerate the context pack.");
  else {
    lines.push("- Start with the top cited notes above; cite file:line provenance when using facts.");
    lines.push("- Follow backlinks/neighbors for any decision that depends on missing context.");
    lines.push("- Refresh stale/expired claims before relying on them.");
  }
  lines.push("");
  return lines.join("\n");
}

export function buildAgentContextPayload(corpus: CompiledCorpus, opts: AgentContextOptions): AgentPayload {
  const include = new Set(opts.include || []);
  const limit = Math.max(1, Math.min(100, opts.limit || 10));
  const maxChars = Math.max(200, opts.maxChars || 12000);
  const errors: string[] = [];
  const lookup = buildAgentCorpusLookup(corpus);
  let selected: Array<{ node: CompiledCorpusNode; score?: { score: number; matchedTerms: string[]; selectionReason?: string[] } }> = [];

  if (opts.action === "fetch") {
    const node = findNodeById(corpus, opts.id || "");
    if (node) selected = [{ node }];
    else errors.push(`No node found for id/key: ${opts.id || ""}`);
  } else {
    const terms = termsFor(opts.query || "");
    if (terms.length === 0) errors.push("Query must include at least one searchable term.");
    selected = corpus.nodes
      .filter((node) => nodeMatchesFilters(node, opts))
      .map((node) => ({ node, score: scoreNode(node, terms, opts, lookup) }))
      .filter((item) => (item.score?.score || 0) > 0)
      .sort((a, b) => (b.score!.score - a.score!.score) || a.node.file.localeCompare(b.node.file) || a.node.sourceRange.startLine - b.node.sourceRange.startLine)
      .slice(0, limit);
  }

  const results = selected.map((item) => toAgentNode(corpus, item.node, include, lookup, item.score));
  const payload: AgentPayload = {
    $schema: "org2:agent-context:v1",
    action: opts.action,
    ...(opts.query ? { query: opts.query } : {}),
    ...(opts.id ? { id: opts.id } : {}),
    limit,
    maxChars,
    ...((opts.scope || opts.since || opts.sourceType || opts.reviewStatus) ? { filters: { ...(opts.scope ? { scope: opts.scope } : {}), ...(opts.since ? { since: opts.since } : {}), ...(opts.sourceType ? { sourceType: opts.sourceType } : {}), ...(opts.reviewStatus ? { reviewStatus: opts.reviewStatus } : {}) } } : {}),
    ranking: { recencyWeight: Number.isFinite(opts.recencyWeight) ? opts.recencyWeight! : 1, salienceWeight: Number.isFinite(opts.salienceWeight) ? opts.salienceWeight! : 1 },
    corpus: { schemaVersion: corpus.schemaVersion, rootDir: corpus.rootDir, generatedAt: corpus.artifact.generatedAt, stats: corpus.stats },
    results,
    entityProfiles: profilesForSelection(corpus, selected.map((item) => item.node), opts.query || opts.id || ""),
    errors,
  };

  if (opts.action === "context" || opts.action === "bundle") {
    const citations: AgentSource[] = [];
    let text = "";
    let truncated = false;
    for (const result of results) {
      const reasons = result.selectionReason?.length ? `Selected because: ${result.selectionReason.join("; ")}` : "";
      const chunk = [`## ${result.title}`, `Source: ${result.citation}`, `Review: ${result.claimState.reviewStatus}; freshness: ${result.claimState.freshness}`, reasons, result.snippet].filter(Boolean).join("\n") + "\n\n";
      if (text.length + chunk.length > maxChars) {
        truncated = true;
        break;
      }
      text += chunk;
      citations.push({ file: result.file, sourceRange: result.sourceRange, citation: result.citation });
    }
    payload.context = { text: text.trimEnd(), truncated, charCount: text.trimEnd().length, citations };
  }

  return payload;
}
