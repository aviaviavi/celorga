import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { HeadlineNode, InlineNode, Node } from "./ast.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { stateDir } from "./brandNames.js";
import { isDefaultIgnoredSyncArtifactPath, isOrgLikeFileName, listOrgLikeFiles } from "./corpusFiles.js";
import {
  listWorkflows,
  recordWorkflowSignals,
  updateWorkflow,
  type AgentWorkflow,
  type RecordWorkflowSignalInput,
  type WorkflowPullRequestEvent,
  type WorkflowPullRequestSignalDetail,
  type WorkflowTodoStateSignalDetail,
  type WorkflowTrigger,
} from "./agentWorkflow.js";

export const ORG2_WORKFLOW_OBSERVE_SCHEMA = "org2:workflow-observe:v1" as const;
export const ORG2_WORKFLOW_POLL_SCHEMA = "org2:workflow-poll:v1" as const;
const TODO_STATE_SNAPSHOT_SCHEMA = "org2:todo-state-snapshot:v1" as const;
const GITHUB_CURSOR_SCHEMA = "org2:github-pull-request-cursors:v1" as const;
const GITHUB_SEEN_LIMIT = 500;
const GITHUB_PAGE_SIZE = 50;
const GITHUB_MAX_PAGES = 5;

// ---------------------------------------------------------------------------
// Path globs

/**
 * Corpus-relative glob: `**` crosses directories, `*` and `?` stay within one
 * segment. A pattern without wildcards also matches files below it.
 */
export function workflowPathGlobMatches(pattern: string, relativePath: string): boolean {
  const normalizedPattern = pattern.trim().replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/+$/, "");
  const candidate = relativePath.replace(/\\/g, "/").replace(/^\.\//, "");
  if (!normalizedPattern) return false;
  if (!/[*?]/.test(normalizedPattern)) return candidate === normalizedPattern || candidate.startsWith(`${normalizedPattern}/`);
  let source = "";
  for (let index = 0; index < normalizedPattern.length; index += 1) {
    const char = normalizedPattern[index]!;
    if (char === "*" && normalizedPattern[index + 1] === "*") {
      index += 1;
      if (normalizedPattern[index + 1] === "/") { index += 1; source += "(?:.*/)?"; } else source += ".*";
    } else if (char === "*") source += "[^/]*";
    else if (char === "?") source += "[^/]";
    else source += char.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${source}$`).test(candidate);
}

// ---------------------------------------------------------------------------
// TODO-state transition detection

export interface TodoHeadingRecord {
  title: string;
  line: number;
  level: number;
  /** Ancestor titles plus this title; the stable fallback identity. */
  outline: string;
  state?: string;
  id?: string;
  tags: string[];
  properties: Record<string, string>;
}

export interface TodoStateTransition extends WorkflowTodoStateSignalDetail {
  properties: Record<string, string>;
}

function inlineText(node: InlineNode): string {
  switch (node.type) {
    case "Text": return node.value;
    case "Timestamp": return node.raw;
    case "TimestampRange": return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
    case "Emphasis": return `${node.marker}${node.content}${node.marker}`;
    case "Link": return node.descriptionRaw ?? node.targetRaw;
    default: return (node as { raw?: string }).raw ?? "";
  }
}

function headingProperties(headline: HeadlineNode): Record<string, string> {
  const drawer = headline.children.find((child) => child.type === "PropertyDrawer");
  if (!drawer || drawer.type !== "PropertyDrawer") return {};
  return Object.fromEntries(drawer.properties.map((property) => [property.key.toUpperCase(), property.value.trim()]));
}

/** Parses headings with the shared parser, including inherited tags and source lines. */
export function extractTodoHeadings(text: string, sourcePath?: string): TodoHeadingRecord[] {
  const document = parseOrgToCanonicalAst(text, { sourceRanges: true, ...(sourcePath ? { sourcePath } : {}) });
  const output: TodoHeadingRecord[] = [];
  const walk = (nodes: Node[], ancestors: string[], inheritedTags: string[]) => {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = node.title.map(inlineText).join("").replace(/^\s*\[#[A-Za-z0-9]\]\s*/, "").trim();
      const properties = headingProperties(node);
      const tags = [...new Set([...inheritedTags, ...(node.tags || [])])];
      const outline = [...ancestors, title].join("\u001f");
      output.push({
        title,
        line: (node as HeadlineNode & { sourceRange?: { startLine: number } }).sourceRange?.startLine || 1,
        level: node.level,
        outline,
        ...(node.todo ? { state: node.todo } : {}),
        ...(properties.ID ? { id: properties.ID } : {}),
        tags,
        properties,
      });
      walk(node.children, [...ancestors, title], tags);
    }
  };
  walk(document.children, [], []);
  return output;
}

type PreviousHeading = Pick<TodoHeadingRecord, "title" | "outline" | "state" | "id" | "line">;

/**
 * Compares the previous and current headings of one file and returns every
 * heading whose TODO state changed. Headings pair by :ID: first, then by
 * outline path (ancestor titles plus title) in document order, then by title.
 * A heading with no previous counterpart reports `from: null`. `knownIds`
 * supplies states for IDs seen in other files, so a refiled heading with an
 * ID keeps its previous state.
 */
export function detectTodoStateTransitions(
  previous: readonly PreviousHeading[],
  current: readonly TodoHeadingRecord[],
  file: string,
  knownIds: ReadonlyMap<string, string | undefined> = new Map(),
): TodoStateTransition[] {
  const used = new Set<number>();
  const pairs = new Map<number, number>();
  const compatible = (old: PreviousHeading, next: TodoHeadingRecord) => !old.id || !next.id || old.id === next.id;
  const firstUnused = (predicate: (old: PreviousHeading) => boolean): number => previous.findIndex((old, index) => !used.has(index) && predicate(old));
  current.forEach((next, index) => {
    if (!next.id) return;
    const match = firstUnused((old) => old.id === next.id);
    if (match >= 0) { used.add(match); pairs.set(index, match); }
  });
  for (const strategy of [
    (old: PreviousHeading, next: TodoHeadingRecord) => old.outline === next.outline,
    (old: PreviousHeading, next: TodoHeadingRecord) => old.title === next.title,
  ]) {
    current.forEach((next, index) => {
      if (pairs.has(index)) return;
      const match = firstUnused((old) => compatible(old, next) && strategy(old, next));
      if (match >= 0) { used.add(match); pairs.set(index, match); }
    });
  }
  const transitions: TodoStateTransition[] = [];
  current.forEach((next, index) => {
    if (!next.state) return;
    const pairIndex = pairs.get(index);
    let from: string | null;
    if (pairIndex !== undefined) from = previous[pairIndex]!.state ?? null;
    else if (next.id && knownIds.has(next.id)) from = knownIds.get(next.id) ?? null;
    else from = null;
    if (from === next.state) return;
    transitions.push({
      file,
      line: next.line,
      ...(next.id ? { headingId: next.id } : {}),
      title: next.title,
      from,
      to: next.state,
      tags: next.tags,
      properties: next.properties,
    });
  });
  return transitions;
}

/** Convenience form that parses both versions of a file with the shared parser. */
export function detectTodoStateTransitionsInText(previousText: string, currentText: string, file: string, sourcePath?: string): TodoStateTransition[] {
  return detectTodoStateTransitions(extractTodoHeadings(previousText, sourcePath), extractTodoHeadings(currentText, sourcePath), file);
}

/** Whether a transition satisfies a todo-state trigger's states, tags, paths, and property filters. */
export function todoStateTriggerMatches(trigger: WorkflowTrigger, transition: TodoStateTransition): boolean {
  if (trigger.type !== "todo-state" || !trigger.enabled) return false;
  if (!(trigger.states || []).includes(transition.to)) return false;
  if (trigger.tags?.length && !trigger.tags.some((tag) => transition.tags.includes(tag))) return false;
  if (trigger.paths?.length && !trigger.paths.some((pattern) => workflowPathGlobMatches(pattern, transition.file))) return false;
  if (trigger.property) {
    const equals = trigger.property.indexOf("=");
    const name = (equals < 0 ? trigger.property : trigger.property.slice(0, equals)).trim().toUpperCase();
    const value = transition.properties[name];
    if (value === undefined || !value.trim()) return false;
    if (equals >= 0 && value.trim() !== trigger.property.slice(equals + 1).trim()) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// TODO-state observation over the corpus

interface TodoSnapshotFile {
  mtimeMs: number;
  size: number;
  sha256: string;
  headings: PreviousHeading[];
}

interface TodoSnapshot {
  schema: typeof TODO_STATE_SNAPSHOT_SCHEMA;
  observedAt?: string;
  /** Triggers that saw the recorded state; only they may fire on the next change. */
  triggers: string[];
  files: Record<string, TodoSnapshotFile>;
}

export function todoStateSnapshotPath(corpus: string): string {
  return stateDir(path.resolve(corpus), "workflow-triggers", "todo-state-snapshot.json");
}

function readJsonState<T>(file: string, fallback: T): { value: T; revision: string | null } {
  if (!fs.existsSync(file)) return { value: fallback, revision: null };
  const snapshot = readGuardedFile(file);
  try { return { value: JSON.parse(snapshot.content) as T, revision: snapshot.revision }; }
  catch { return { value: fallback, revision: snapshot.revision }; }
}

function writeJsonState(file: string, value: unknown, revision: string | null): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  guardedWriteFile(file, `${JSON.stringify(value, null, 2)}\n`, { expectedRevision: revision });
}

function sha256(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function activeTriggers(corpus: string, type: WorkflowTrigger["type"], workflowId?: string): Array<{ workflow: AgentWorkflow; trigger: WorkflowTrigger; key: string }> {
  return listWorkflows(corpus)
    .filter((workflow) => workflow.state === "active" && (!workflowId || workflow.id === workflowId))
    .flatMap((workflow) => workflow.triggers
      .filter((trigger) => trigger.enabled && trigger.type === type)
      .map((trigger) => ({ workflow, trigger, key: `${workflow.id}/${trigger.id}` })));
}

export interface WorkflowSignalProposal {
  workflowId: string;
  triggerId: string;
  signal: RecordWorkflowSignalInput & { id: string; at: string };
}

export interface WorkflowObserveResult {
  schema: typeof ORG2_WORKFLOW_OBSERVE_SCHEMA;
  now: string;
  applied: boolean;
  status: "ok" | "idle";
  message: string;
  scanned: number;
  changed: string[];
  baselined: string[];
  newTriggers: string[];
  transitions: TodoStateTransition[];
  signals: WorkflowSignalProposal[];
  recorded: number;
}

function corpusRelative(corpus: string, file: string): string | null {
  const absolute = path.resolve(corpus, file);
  const relative = path.relative(corpus, absolute);
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return null;
  return relative.split(path.sep).join("/");
}

/**
 * Detects TODO-state transitions since the last observation and proposes a
 * signal for every active todo-state trigger whose filters match. Preview by
 * default; `apply` records signals in the workflow files and advances the
 * snapshot under the corpus state directory.
 */
export function observeTodoStateTransitions(corpusRoot: string, options: { changed?: string[]; apply?: boolean; now?: string } = {}): WorkflowObserveResult {
  const corpus = path.resolve(corpusRoot);
  const now = new Date(options.now || Date.now());
  if (Number.isNaN(now.getTime())) throw new Error(`invalid timestamp: ${options.now}`);
  const nowIso = now.toISOString();
  const triggers = activeTriggers(corpus, "todo-state");
  const base = { schema: ORG2_WORKFLOW_OBSERVE_SCHEMA, now: nowIso, applied: false, scanned: 0, changed: [], baselined: [], newTriggers: [], transitions: [], signals: [], recorded: 0 };
  if (!triggers.length) return { ...base, status: "idle", message: "No active workflow has a todo-state trigger." };

  const snapshotFile = todoStateSnapshotPath(corpus);
  const loaded = readJsonState<TodoSnapshot>(snapshotFile, { schema: TODO_STATE_SNAPSHOT_SCHEMA, triggers: [], files: {} });
  const snapshot: TodoSnapshot = {
    schema: TODO_STATE_SNAPSHOT_SCHEMA,
    triggers: Array.isArray(loaded.value.triggers) ? loaded.value.triggers : [],
    files: loaded.value.files && typeof loaded.value.files === "object" ? loaded.value.files : {},
  };
  const firstObservation = loaded.revision === null;
  const priorTriggers = new Set(snapshot.triggers);
  const newTriggers = triggers.map((item) => item.key).filter((key) => !priorTriggers.has(key));
  // A newly active trigger has not seen the current state, so this pass covers
  // the whole corpus as its baseline rather than trusting a partial file list.
  const fullScan = !options.changed?.length || newTriggers.length > 0 || firstObservation;
  const candidates = fullScan
    ? listOrgLikeFiles(corpus, true).map((file) => corpusRelative(corpus, file)).filter((item): item is string => Boolean(item))
    : [...new Set(options.changed!.map((file) => corpusRelative(corpus, file)).filter((item): item is string =>
      Boolean(item) && isOrgLikeFileName(path.basename(item!)) && !isDefaultIgnoredSyncArtifactPath(item!)))];
  const knownIds = new Map<string, string | undefined>();
  for (const entry of Object.values(snapshot.files)) {
    for (const heading of entry.headings || []) if (heading.id && !knownIds.has(heading.id)) knownIds.set(heading.id, heading.state);
  }

  const changed: string[] = [];
  const baselined: string[] = [];
  const transitions: TodoStateTransition[] = [];
  const nextFiles: Record<string, TodoSnapshotFile> = { ...snapshot.files };
  const fileRevisions = new Map<string, string>();
  const present = new Set<string>();
  let scanned = 0;
  for (const relative of candidates) {
    const absolute = path.join(corpus, relative);
    let stat: fs.Stats;
    try { stat = fs.statSync(absolute); } catch { if (nextFiles[relative]) { delete nextFiles[relative]; changed.push(relative); } continue; }
    if (!stat.isFile()) continue;
    present.add(relative);
    const previous = snapshot.files[relative];
    if (previous && previous.mtimeMs === stat.mtimeMs && previous.size === stat.size) continue;
    scanned += 1;
    const text = fs.readFileSync(absolute, "utf8");
    const digest = sha256(text);
    if (previous && previous.sha256 === digest) { nextFiles[relative] = { ...previous, mtimeMs: stat.mtimeMs, size: stat.size }; continue; }
    let headings: TodoHeadingRecord[];
    try { headings = extractTodoHeadings(text, absolute); } catch { continue; }
    changed.push(relative);
    fileRevisions.set(relative, digest);
    nextFiles[relative] = {
      mtimeMs: stat.mtimeMs,
      size: stat.size,
      sha256: digest,
      // Only headings with a TODO state matter as a previous state; a heading
      // without one pairs the same way as a new heading (from: null).
      headings: headings.filter((heading) => heading.state).map(({ title, outline, state, id, line }) => ({ title, outline, line, state, ...(id ? { id } : {}) })),
    };
    if (firstObservation) { baselined.push(relative); continue; }
    transitions.push(...detectTodoStateTransitions(previous?.headings || [], headings, relative, knownIds));
  }
  if (fullScan) {
    for (const relative of Object.keys(nextFiles)) if (!present.has(relative)) { delete nextFiles[relative]; changed.push(relative); }
  }

  const signals: WorkflowSignalProposal[] = [];
  for (const transition of transitions) {
    for (const { workflow, trigger, key } of triggers) {
      if (!priorTriggers.has(key) || !todoStateTriggerMatches(trigger, transition)) continue;
      const { properties: _properties, ...detail } = transition;
      const id = `todo-state-${sha256([workflow.id, trigger.id, transition.file, transition.headingId || "", transition.title, transition.from || "", transition.to, fileRevisions.get(transition.file) || ""].join("\u0000")).slice(0, 20)}`;
      signals.push({
        workflowId: workflow.id,
        triggerId: trigger.id,
        signal: { id, type: "todo-state", at: nowIso, paths: [transition.file], triggerId: trigger.id, source: "todo-state", todoState: detail },
      });
    }
  }

  let recorded = 0;
  if (options.apply) {
    recorded = recordSignalProposals(corpus, signals, nowIso);
    writeJsonState(snapshotFile, {
      schema: TODO_STATE_SNAPSHOT_SCHEMA,
      observedAt: nowIso,
      triggers: triggers.map((item) => item.key).sort(),
      files: nextFiles,
    } satisfies TodoSnapshot, loaded.revision);
  }
  const message = firstObservation
    ? `Recorded a baseline of ${baselined.length} file${baselined.length === 1 ? "" : "s"}; later TODO-state changes will fire.`
    : `${transitions.length} TODO-state change${transitions.length === 1 ? "" : "s"}; ${signals.length} matching signal${signals.length === 1 ? "" : "s"}.`;
  return { ...base, applied: options.apply === true, status: "ok", message, scanned, changed, baselined, newTriggers, transitions, signals, recorded };
}

function recordSignalProposals(corpus: string, proposals: WorkflowSignalProposal[], now: string): number {
  const byWorkflow = new Map<string, WorkflowSignalProposal[]>();
  for (const proposal of proposals) byWorkflow.set(proposal.workflowId, [...(byWorkflow.get(proposal.workflowId) || []), proposal]);
  let recorded = 0;
  for (const [workflowId, items] of byWorkflow) {
    updateWorkflow(corpus, workflowId, (workflow) => {
      const before = workflow.signals?.length || 0;
      const updated = recordWorkflowSignals(workflow, items.map((item) => item.signal));
      recorded += (updated.signals?.length || 0) - before;
      return updated;
    }, now);
  }
  return recorded;
}

// ---------------------------------------------------------------------------
// GitHub pull-request polling through the user's `gh` CLI

export interface GhResult {
  status: number | null;
  stdout: string;
  stderr: string;
  missing?: boolean;
}

/** Runs `gh` with arguments. Injected in tests; the default uses the user's installed CLI and its existing auth. */
export type GhRunner = (args: string[]) => GhResult;

function findGhExecutable(): string {
  const directories = [...(process.env.PATH || "").split(path.delimiter), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"];
  for (const directory of directories) {
    if (!directory) continue;
    const candidate = path.join(directory, "gh");
    try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch {}
  }
  return "gh";
}

export const defaultGhRunner: GhRunner = (args) => {
  const result = spawnSync(findGhExecutable(), args, {
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1", NO_COLOR: "1" },
  });
  const code = (result.error as NodeJS.ErrnoException | undefined)?.code;
  return { status: result.status, stdout: result.stdout || "", stderr: result.stderr || (result.error ? String(result.error.message) : ""), ...(code === "ENOENT" ? { missing: true } : {}) };
};

export class GhUnavailableError extends Error {
  constructor(readonly status: "gh-missing" | "gh-unauthenticated", message: string) { super(message); }
}

interface GithubPull {
  number: number;
  title?: string;
  html_url?: string;
  user?: { login?: string };
  head?: { sha?: string };
  created_at?: string;
  updated_at?: string;
  closed_at?: string | null;
  merged_at?: string | null;
}

interface GithubCursor {
  repo: string;
  since: string;
  heads: Record<string, string>;
  seen: string[];
  polledAt: string;
}

interface GithubCursorFile {
  schema: typeof GITHUB_CURSOR_SCHEMA;
  triggers: Record<string, GithubCursor>;
}

export function githubCursorPath(corpus: string): string {
  return stateDir(path.resolve(corpus), "workflow-triggers", "github-cursors.json");
}

export interface WorkflowPollTriggerResult {
  workflowId: string;
  triggerId: string;
  repo: string;
  status: "baselined" | "ok" | "error";
  message?: string;
  since?: string;
  signalCount: number;
}

export interface WorkflowPollResult {
  schema: typeof ORG2_WORKFLOW_POLL_SCHEMA;
  source: "github";
  now: string;
  applied: boolean;
  status: "ok" | "idle" | "partial" | "gh-missing" | "gh-unauthenticated";
  message: string;
  triggers: WorkflowPollTriggerResult[];
  signals: WorkflowSignalProposal[];
  recorded: number;
}

function time(value: string | null | undefined): number {
  const parsed = value ? new Date(value).getTime() : Number.NaN;
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}

/**
 * Polls GitHub pull-request activity for every active pull-request trigger.
 * The first poll of a trigger records a cursor without signals. Later polls
 * propose one signal per new activity item that passes the trigger's event,
 * number, and author filters. Preview by default; `apply` records signals and
 * advances cursors. Tokens are never read or stored: `gh` owns authentication.
 */
export function pollGithubPullRequests(corpusRoot: string, options: { apply?: boolean; now?: string; workflowId?: string; gh?: GhRunner } = {}): WorkflowPollResult {
  const corpus = path.resolve(corpusRoot);
  const now = new Date(options.now || Date.now());
  if (Number.isNaN(now.getTime())) throw new Error(`invalid timestamp: ${options.now}`);
  const nowIso = now.toISOString();
  const triggers = activeTriggers(corpus, "pull-request", options.workflowId);
  const base = { schema: ORG2_WORKFLOW_POLL_SCHEMA, source: "github" as const, now: nowIso, applied: false, triggers: [], signals: [], recorded: 0 };
  if (!triggers.length) return { ...base, status: "idle", message: "No active workflow has a pull-request trigger." };

  const runner = options.gh || defaultGhRunner;
  const cache = new Map<string, unknown>();
  const api = <T>(endpoint: string): T => {
    if (cache.has(endpoint)) return cache.get(endpoint) as T;
    const result = runner(["api", "-H", "Accept: application/vnd.github+json", endpoint]);
    if (result.missing) throw new GhUnavailableError("gh-missing", "GitHub CLI (gh) is not installed or not on PATH. Install it and run `gh auth login` to enable pull-request triggers.");
    if (result.status !== 0) {
      if (result.status === 4 || /gh auth login|HTTP 401|not logged in|authentication/i.test(result.stderr)) {
        throw new GhUnavailableError("gh-unauthenticated", "GitHub CLI (gh) is not authenticated. Run `gh auth login` to enable pull-request triggers.");
      }
      throw new Error(`gh api ${endpoint} failed: ${result.stderr.trim().split("\n")[0] || `exit ${result.status}`}`);
    }
    let parsed: unknown;
    try { parsed = JSON.parse(result.stdout || "null"); } catch { throw new Error(`gh api ${endpoint} returned invalid JSON`); }
    cache.set(endpoint, parsed);
    return parsed as T;
  };

  const cursorFile = githubCursorPath(corpus);
  const loaded = readJsonState<GithubCursorFile>(cursorFile, { schema: GITHUB_CURSOR_SCHEMA, triggers: {} });
  const cursors: Record<string, GithubCursor> = { ...(loaded.value.triggers || {}) };
  const results: WorkflowPollTriggerResult[] = [];
  const signals: WorkflowSignalProposal[] = [];

  for (const { workflow, trigger, key } of triggers) {
    const repo = trigger.repo!;
    const cursor = cursors[key];
    try {
      if (!cursor || cursor.repo !== repo) {
        const pulls = api<GithubPull[]>(`repos/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=${GITHUB_PAGE_SIZE}`);
        const latest = pulls.reduce((max, pull) => Math.max(max, time(pull.updated_at) || 0), 0);
        cursors[key] = {
          repo,
          since: latest ? new Date(latest).toISOString() : nowIso,
          heads: Object.fromEntries(pulls.filter((pull) => pull.head?.sha).map((pull) => [String(pull.number), pull.head!.sha!])),
          seen: [],
          polledAt: nowIso,
        };
        results.push({ workflowId: workflow.id, triggerId: trigger.id, repo, status: "baselined", since: cursors[key]!.since, signalCount: 0, message: "Recorded a starting cursor; later pull-request activity will fire." });
        continue;
      }
      const since = time(cursor.since);
      const pulls: GithubPull[] = [];
      for (let page = 1; page <= GITHUB_MAX_PAGES; page += 1) {
        const batch = api<GithubPull[]>(`repos/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=${GITHUB_PAGE_SIZE}&page=${page}`);
        pulls.push(...batch.filter((pull) => time(pull.updated_at) >= since));
        if (batch.length < GITHUB_PAGE_SIZE || batch.some((pull) => time(pull.updated_at) < since)) break;
      }
      const wants = (event: WorkflowPullRequestEvent) => !trigger.events?.length || trigger.events.includes(event);
      const heads = { ...cursor.heads };
      const seen = new Set(cursor.seen);
      const fresh: WorkflowPullRequestSignalDetail[] = [];
      let latest = since;
      const sinceIso = new Date(since).toISOString();
      for (const pull of pulls) {
        latest = Math.max(latest, time(pull.updated_at) || 0);
        const previousHead = heads[String(pull.number)];
        if (pull.head?.sha) heads[String(pull.number)] = pull.head.sha;
        if (trigger.number !== undefined && pull.number !== trigger.number) continue;
        if (trigger.author && pull.user?.login?.toLowerCase() !== trigger.author.toLowerCase()) continue;
        const common = {
          repo,
          number: pull.number,
          ...(pull.title ? { title: pull.title } : {}),
          ...(pull.html_url ? { url: pull.html_url } : {}),
          ...(pull.user?.login ? { author: pull.user.login } : {}),
        };
        const add = (event: WorkflowPullRequestEvent, key: string, extra: { actor?: string; occurredAt?: string; url?: string } = {}) => {
          if (!wants(event) || seen.has(key)) return;
          seen.add(key);
          fresh.push({ ...common, event, key, ...Object.fromEntries(Object.entries(extra).filter(([, value]) => value)) });
        };
        if (time(pull.created_at) >= since) add("opened", `${repo}#${pull.number}:opened`, { actor: pull.user?.login, occurredAt: pull.created_at });
        else if (previousHead && pull.head?.sha && previousHead !== pull.head.sha) add("commit", `${repo}#${pull.number}:commit:${pull.head.sha}`, { occurredAt: pull.updated_at });
        if (pull.merged_at && time(pull.merged_at) >= since) add("merged", `${repo}#${pull.number}:merged`, { occurredAt: pull.merged_at });
        else if (pull.closed_at && time(pull.closed_at) >= since) add("closed", `${repo}#${pull.number}:closed:${pull.closed_at}`, { occurredAt: pull.closed_at });
        if (wants("review")) {
          const reviews = api<Array<{ id: number; state?: string; submitted_at?: string; user?: { login?: string }; html_url?: string }>>(`repos/${repo}/pulls/${pull.number}/reviews?per_page=100`);
          for (const review of reviews) {
            if (review.state === "PENDING" || !(time(review.submitted_at) >= since)) continue;
            add("review", `${repo}#${pull.number}:review:${review.id}`, { actor: review.user?.login, occurredAt: review.submitted_at, url: review.html_url });
          }
        }
        if (wants("comment")) {
          const query = `since=${encodeURIComponent(sinceIso)}&per_page=100`;
          const comments = [
            ...api<Array<{ id: number; created_at?: string; user?: { login?: string }; html_url?: string }>>(`repos/${repo}/issues/${pull.number}/comments?${query}`),
            ...api<Array<{ id: number; created_at?: string; user?: { login?: string }; html_url?: string }>>(`repos/${repo}/pulls/${pull.number}/comments?${query}`),
          ];
          for (const comment of comments) {
            if (!(time(comment.created_at) >= since)) continue;
            add("comment", `${repo}#${pull.number}:comment:${comment.id}`, { actor: comment.user?.login, occurredAt: comment.created_at, url: comment.html_url });
          }
        }
      }
      for (const detail of fresh) {
        signals.push({
          workflowId: workflow.id,
          triggerId: trigger.id,
          signal: {
            id: `pull-request-${sha256([workflow.id, trigger.id, detail.key].join("\u0000")).slice(0, 20)}`,
            type: "pull-request",
            at: nowIso,
            paths: [],
            triggerId: trigger.id,
            source: "github",
            pullRequest: detail,
          },
        });
      }
      cursors[key] = { repo, since: new Date(latest).toISOString(), heads, seen: [...seen].slice(-GITHUB_SEEN_LIMIT), polledAt: nowIso };
      results.push({ workflowId: workflow.id, triggerId: trigger.id, repo, status: "ok", since: cursors[key]!.since, signalCount: fresh.length });
    } catch (error) {
      if (error instanceof GhUnavailableError) {
        return { ...base, status: error.status, message: error.message, triggers: results };
      }
      results.push({ workflowId: workflow.id, triggerId: trigger.id, repo, status: "error", message: (error as Error).message, signalCount: 0 });
    }
  }

  let recorded = 0;
  if (options.apply) {
    recorded = recordSignalProposals(corpus, signals, nowIso);
    writeJsonState(cursorFile, { schema: GITHUB_CURSOR_SCHEMA, triggers: cursors } satisfies GithubCursorFile, loaded.revision);
  }
  const failed = results.filter((item) => item.status === "error").length;
  return {
    ...base,
    applied: options.apply === true,
    status: failed ? "partial" : "ok",
    message: failed
      ? `${failed} pull-request trigger${failed === 1 ? "" : "s"} could not be polled.`
      : `${signals.length} pull-request signal${signals.length === 1 ? "" : "s"} from ${results.length} trigger${results.length === 1 ? "" : "s"}.`,
    triggers: results,
    signals,
    recorded,
  };
}
