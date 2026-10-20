import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { compileCorpus, type CompiledCorpusNode } from "./corpusCompile.js";
import { loadConfig, resolveFilesFromDir } from "./config.js";
import { configFilePath, schemaMatches } from "./brandNames.js";
import { guardedContentRevision, guardedWriteFile, readGuardedFile, GuardedFileConflictError } from "./guardedFile.js";
import { updatePlanningInText } from "./planning.js";
import { isTerminalTodoKeyword } from "./todo.js";
import { computeSubtreeRange, findHeadingAtOrAbove, findPlanningBlockEnd, splitSourceLines } from "./sourceLines.js";

/**
 * Reusable interactive workspace views.
 *
 * A view is one plain JSON file under views/ID.org2-interactive-view.json, next
 * to saved property views. It holds the view's query (kind, horizon), the
 * person's remembered choices (order, exclusions, available time, estimates),
 * and the history of guarded actions taken from the view. This is the single
 * state store for the "Interactive AI responses" proposal: a chat answer that
 * shows a plan embeds a refresh of a saved view rather than keeping its own
 * state. Org files remain canonical; refresh always recompiles them.
 *
 * Controls in the sandboxed HTML can only send bridge intents (see
 * parseViewBridgeIntent). An intent may update remembered choices or request a
 * preview. Applying a preview is never a frame capability: the host or CLI
 * applies it with the preview fingerprint and the source revision, and every
 * write is revision guarded.
 */

export const INTERACTIVE_VIEW_SCHEMA = "org2:interactive-view:v1" as const;
export const VIEW_BRIDGE_MESSAGE_TYPE = "org2-view-intent" as const;
const suffix = ".org2-interactive-view.json";
const MAX_KEYS = 500;
const MAX_HISTORY = 50;

export type InteractiveViewKind = "daily-plan";
export interface InteractiveViewState {
  availableMinutes: number;
  order: string[];
  excluded: string[];
  estimates: Record<string, number>;
}
export interface InteractiveViewAction {
  id: string;
  kind: "schedule";
  at: string;
  actor: string;
  task: string;
  file: string;
  headingLine: number;
  date: string;
  /** Exact planning-block lines before and after the edit. Undo restores `before` only when `after` is still current. */
  before: string[];
  after: string[];
  revisionAfter: string;
  undoneAt?: string;
}
export interface InteractiveViewDefinition {
  schema: typeof INTERACTIVE_VIEW_SCHEMA;
  id: string;
  title: string;
  kind: InteractiveViewKind;
  /** Days after the plan date whose deadlines count as due. */
  deadlineHorizonDays: number;
  state: InteractiveViewState;
  history: InteractiveViewAction[];
}

function record(value: unknown): value is Record<string, unknown> { return Boolean(value && typeof value === "object" && !Array.isArray(value)); }
function viewID(value: unknown): string {
  if (typeof value !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/.test(value)) throw new Error("View ID must contain 1–100 letters, numbers, underscores or hyphens");
  return value;
}
function taskKey(value: unknown): string {
  if (typeof value !== "string" || !value || value.length > 1024 || /[\r\n\0]/.test(value)) throw new Error("Task keys must be single-line strings");
  if (!/^(id:[A-Za-z0-9._:-]+|file:[^:]+::.+)$/.test(value)) throw new Error(`Invalid task key: ${value}`);
  return value;
}
function minutes(value: unknown, label: string): number {
  if (!Number.isInteger(value) || Number(value) < 0 || Number(value) > 24 * 60) throw new Error(`${label} must be whole minutes between 0 and 1440`);
  return Number(value);
}
function isoDate(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(value + "T00:00:00Z"))) throw new Error("Dates must be YYYY-MM-DD");
  return value;
}
function keyList(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || value.length > MAX_KEYS) throw new Error(`${label} must be a list of at most ${MAX_KEYS} task keys`);
  return [...new Set(value.map(taskKey))];
}
function parseState(value: unknown): InteractiveViewState {
  if (!record(value)) throw new Error("View state must be an object");
  const estimates = value.estimates === undefined ? {} : value.estimates;
  if (!record(estimates) || Object.keys(estimates).length > MAX_KEYS) throw new Error("Estimates must map task keys to minutes");
  return {
    availableMinutes: minutes(value.availableMinutes ?? 480, "Available time"),
    order: keyList(value.order ?? [], "Order"),
    excluded: keyList(value.excluded ?? [], "Excluded"),
    estimates: Object.fromEntries(Object.entries(estimates).map(([k, v]) => [taskKey(k), minutes(v, "Estimate")])),
  };
}

export function parseInteractiveView(value: unknown): InteractiveViewDefinition {
  if (!record(value) || !schemaMatches(value.schema, INTERACTIVE_VIEW_SCHEMA)) throw new Error(`Expected ${INTERACTIVE_VIEW_SCHEMA}`);
  const id = viewID(value.id);
  const title = typeof value.title === "string" ? value.title.trim() : "";
  if (!title || title.length > 200 || /[\r\n]/.test(title)) throw new Error("View title must be one line of 1–200 characters");
  if (value.kind !== "daily-plan") throw new Error("View kind must be daily-plan");
  const horizon = value.deadlineHorizonDays ?? 0;
  if (!Number.isInteger(horizon) || Number(horizon) < 0 || Number(horizon) > 30) throw new Error("Deadline horizon must be 0–30 days");
  const history = Array.isArray(value.history) ? value.history.slice(-MAX_HISTORY) as InteractiveViewAction[] : [];
  return { schema: INTERACTIVE_VIEW_SCHEMA, id, title, kind: "daily-plan", deadlineHorizonDays: Number(horizon), state: parseState(value.state ?? {}), history };
}

/** Resolve paths through symlinks and refuse hidden directories, matching property views. */
function inside(root: string, file: string): string {
  const base = fs.realpathSync(root);
  const target = path.resolve(base, file);
  let ancestor = target;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  const resolved = path.resolve(fs.realpathSync(ancestor), path.relative(ancestor, target));
  const relative = path.relative(base, resolved);
  if (!relative || relative === ".." || relative.startsWith(".." + path.sep) || path.isAbsolute(relative) || relative.split(path.sep).some(p => p.startsWith("."))) throw new Error("Interactive views and their sources must stay inside the active corpus, outside hidden directories");
  return resolved;
}
function viewPath(root: string, id: string): string { return inside(root, path.join("views", viewID(id) + suffix)); }
function relativeTo(root: string, file: string): string { return path.relative(fs.realpathSync(root), file).replace(/\\/g, "/"); }
function serialize(view: InteractiveViewDefinition): string { return JSON.stringify(view, null, 2) + "\n"; }

export function loadInteractiveView(root: string, id: string) {
  const file = viewPath(root, id);
  const snapshot = readGuardedFile(file);
  const view = parseInteractiveView(JSON.parse(snapshot.content));
  if (view.id !== id) throw new Error("View ID and filename differ");
  return { view, file: relativeTo(root, file), revision: snapshot.revision };
}

export function listInteractiveViews(root: string) {
  const directory = inside(root, "views");
  const views: Array<{ id: string; title: string; kind: InteractiveViewKind; file: string; revision: string }> = [];
  const diagnostics: Array<{ file: string; message: string }> = [];
  if (fs.existsSync(directory)) for (const name of fs.readdirSync(directory).sort()) {
    if (!name.endsWith(suffix)) continue;
    try { const { view, file, revision } = loadInteractiveView(root, name.slice(0, -suffix.length)); views.push({ id: view.id, title: view.title, kind: view.kind, file, revision }); }
    catch (error) { diagnostics.push({ file: name, message: error instanceof Error ? error.message : String(error) }); }
  }
  return { schema: "org2:interactive-view-list:v1", views, diagnostics };
}

export function createInteractiveView(root: string, input: { id: string; title: string; kind?: string; availableMinutes?: number; deadlineHorizonDays?: number }, options: { apply?: boolean } = {}) {
  const view = parseInteractiveView({ schema: INTERACTIVE_VIEW_SCHEMA, id: input.id, title: input.title, kind: input.kind ?? "daily-plan", deadlineHorizonDays: input.deadlineHorizonDays ?? 0, state: { availableMinutes: input.availableMinutes ?? 480 }, history: [] });
  const file = viewPath(root, view.id);
  if (fs.existsSync(file)) throw new GuardedFileConflictError(`View already exists: ${relativeTo(root, file)}`, { file, expectedRevision: null });
  const content = serialize(view);
  if (options.apply) guardedWriteFile(file, content, { expectedRevision: null });
  return { schema: "org2:interactive-view-save:v1", applied: Boolean(options.apply), baseRevision: null, revision: guardedContentRevision(content), file: relativeTo(root, file), view };
}

/** Merge a remembered-choice patch into a saved view. The view revision is mandatory. */
export function updateInteractiveViewState(root: string, id: string, patch: unknown, options: { expectedRevision: string; apply?: boolean }) {
  if (!options.expectedRevision) throw new Error("Saving view choices requires --if-revision from view show or refresh");
  if (!record(patch)) throw new Error("State patch must be an object");
  const allowed = ["availableMinutes", "order", "excluded", "estimates"];
  for (const key of Object.keys(patch)) if (!allowed.includes(key)) throw new Error(`Unsupported view state field: ${key}`);
  const { view, file, revision } = loadInteractiveView(root, id);
  if (revision !== options.expectedRevision) throw new GuardedFileConflictError("View changed after it was read; refresh before saving choices", { file, expectedRevision: options.expectedRevision, actualRevision: revision });
  const next: InteractiveViewDefinition = { ...view, state: parseState({ ...view.state, ...patch }) };
  const content = serialize(next);
  if (options.apply) guardedWriteFile(inside(root, file), content, { expectedRevision: revision, preserveMode: true });
  return { schema: "org2:interactive-view-state:v1", applied: Boolean(options.apply), baseRevision: revision, revision: guardedContentRevision(content), file, state: next.state };
}

export interface DailyPlanItem {
  key: string;
  title: string;
  todo: string;
  priority: string | null;
  scheduled: string | null;
  deadline: string | null;
  reason: "scheduled" | "overdue" | "deadline";
  estimateMinutes: number;
  startOffsetMinutes: number;
  fits: boolean;
  source: { file: string; line: number; id: string | null; link: string; revision: string };
}

function planDate(raw: string | undefined): string | null {
  const match = raw ? /(\d{4}-\d{2}-\d{2})/.exec(raw) : null;
  return match ? match[1] : null;
}
function addDays(date: string, days: number): string {
  const d = new Date(date + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + days); return d.toISOString().slice(0, 10);
}
export function localToday(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}
export function interactiveTaskKey(node: Pick<CompiledCorpusNode, "id" | "file" | "title">): string {
  return node.id ? `id:${node.id}` : `file:${node.file}::${node.title}`;
}

function compileCanonical(root: string) {
  const base = fs.realpathSync(root);
  const configFile = configFilePath(base);
  const config = fs.existsSync(configFile) ? loadConfig(configFile) : {};
  // Views, raw imports, and hidden state are not canonical task sources.
  const files = resolveFilesFromDir(base, ["**/*.org", "**/*.org2"], ["node_modules", "node_modules/**", "raw/**", "views/**", ...(config.ignorePatterns ?? [])], true);
  const revisions = new Map(files.map(file => [path.relative(base, file).replace(/\\/g, "/"), readGuardedFile(file).revision]));
  return { base, corpus: compileCorpus(files, { rootDir: base }), revisions };
}

/** Recompile canonical sources and apply the view's remembered choices. */
export function refreshInteractiveView(root: string, id: string, options: { date?: string } = {}) {
  const { view, file, revision } = loadInteractiveView(root, id);
  const date = isoDate(options.date ?? localToday());
  const deadlineLimit = addDays(date, view.deadlineHorizonDays);
  const { corpus, revisions } = compileCanonical(root);
  const candidates: Array<Omit<DailyPlanItem, "startOffsetMinutes" | "fits">> = [];
  for (const node of corpus.nodes) {
    if (node.kind !== "heading" || !node.todo || (node.todoTerminal ?? isTerminalTodoKeyword(node.todo))) continue;
    const scheduledRaw = node.planning.find(p => p.kind === "SCHEDULED")?.raw;
    const deadlineRaw = node.planning.find(p => p.kind === "DEADLINE")?.raw;
    const scheduled = planDate(scheduledRaw), deadline = planDate(deadlineRaw);
    let reason: DailyPlanItem["reason"] | null = null;
    if (scheduled && scheduled === date) reason = "scheduled";
    else if ((scheduled && scheduled < date) || (deadline && deadline < date)) reason = "overdue";
    else if (deadline && deadline <= deadlineLimit) reason = "deadline";
    if (!reason) continue;
    const key = interactiveTaskKey(node);
    candidates.push({
      key, title: node.title, todo: node.todo, priority: node.priority ?? null, scheduled, deadline, reason,
      estimateMinutes: view.state.estimates[key] ?? node.effort?.minutes ?? 30,
      source: { file: node.file, line: node.sourceRange.startLine, id: node.id, link: node.id ? `id:${node.id}` : `file:${node.file}::${node.sourceRange.startLine}`, revision: revisions.get(node.file)! },
    });
  }
  const rank = new Map(view.state.order.map((key, index) => [key, index]));
  const priorityRank = (p: string | null) => p ? p.charCodeAt(0) : 200;
  candidates.sort((a, b) => {
    const ra = rank.get(a.key), rb = rank.get(b.key);
    if (ra !== undefined || rb !== undefined) return (ra ?? Number.MAX_SAFE_INTEGER) - (rb ?? Number.MAX_SAFE_INTEGER);
    const reasonOrder = { overdue: 0, scheduled: 1, deadline: 2 } as const;
    return reasonOrder[a.reason] - reasonOrder[b.reason] || priorityRank(a.priority) - priorityRank(b.priority) || a.source.file.localeCompare(b.source.file) || a.source.line - b.source.line;
  });
  const excluded = new Set(view.state.excluded);
  let offset = 0;
  const items: DailyPlanItem[] = [];
  const excludedItems: typeof candidates = [];
  for (const candidate of candidates) {
    if (excluded.has(candidate.key)) { excludedItems.push(candidate); continue; }
    items.push({ ...candidate, startOffsetMinutes: offset, fits: offset + candidate.estimateMinutes <= view.state.availableMinutes });
    offset += candidate.estimateMinutes;
  }
  const present = new Set(candidates.map(c => c.key));
  return {
    schema: "org2:interactive-view-refresh:v1", view: { id: view.id, title: view.title, kind: view.kind, file, revision },
    date, state: view.state, plannedMinutes: offset, overflowMinutes: Math.max(0, offset - view.state.availableMinutes),
    items, excluded: excludedItems,
    /** Remembered keys whose task no longer qualifies. They are kept, not silently dropped. */
    staleKeys: [...new Set([...view.state.order, ...view.state.excluded])].filter(key => !present.has(key)),
    history: view.history.map(({ id, kind, at, task, date, undoneAt }) => ({ id, kind, at, task, date, ...(undoneAt ? { undoneAt } : {}) })),
  };
}

function findTask(root: string, key: string) {
  taskKey(key);
  const { corpus, revisions } = compileCanonical(root);
  const matches = corpus.nodes.filter(node => node.kind === "heading" && interactiveTaskKey(node) === key);
  if (matches.length !== 1) throw new Error(matches.length ? `Task key is ambiguous: ${key}` : `Task not found: ${key}`);
  const node = matches[0];
  if (node.file.split("/")[0] === "raw") throw new Error("raw/ sources are read-only");
  return { node, absolute: inside(root, node.file), revision: revisions.get(node.file)! };
}

function planningSlice(text: string, headingLine: number) {
  const lines = splitSourceLines(text);
  const headingIndex = findHeadingAtOrAbove(lines, headingLine);
  const { endExclusive } = computeSubtreeRange(lines, headingIndex);
  const end = findPlanningBlockEnd(lines, headingIndex, endExclusive);
  return { lines, headingIndex, start: headingIndex + 1, end };
}

function fingerprintOf(value: unknown): string { return "sha256:" + crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex"); }

/** Allowlisted, reviewable action that a view control may request. */
export interface InteractiveViewActionRequest { action: "schedule"; task: string; date: string }
export function parseInteractiveViewActionRequest(value: unknown): InteractiveViewActionRequest {
  if (!record(value)) throw new Error("Action must be an object");
  for (const key of Object.keys(value)) if (!["action", "task", "date"].includes(key)) throw new Error(`Unsupported action field: ${key}`);
  if (value.action !== "schedule") throw new Error("Only the schedule action is available from interactive views");
  return { action: "schedule", task: taskKey(value.task), date: isoDate(value.date) };
}

/** Preview the exact source change. Returns a fingerprint that apply must echo. */
export function previewInteractiveViewAction(root: string, viewId: string, request: unknown) {
  const action = parseInteractiveViewActionRequest(request);
  const { revision: viewRevision } = loadInteractiveView(root, viewId);
  const { node, absolute, revision } = findTask(root, action.task);
  const snapshot = readGuardedFile(absolute);
  if (snapshot.revision !== revision) throw new GuardedFileConflictError("Source changed while previewing; refresh the view", { file: absolute, expectedRevision: revision, actualRevision: snapshot.revision });
  const result = updatePlanningInText(snapshot.content, { filePath: node.file, lineNumber: node.sourceRange.startLine, kind: "SCHEDULED", date: action.date });
  const before = planningSlice(snapshot.content, node.sourceRange.startLine);
  const after = planningSlice(result.text, node.sourceRange.startLine);
  const beforeLines = before.lines.slice(before.start, before.end), afterLines = after.lines.slice(after.start, after.end);
  const material = { viewId, action, file: node.file, headingLine: before.headingIndex + 1, sourceRevision: revision, before: beforeLines, after: afterLines };
  return {
    schema: "org2:interactive-view-action-preview:v1", applied: false, viewId, viewRevision, action,
    file: node.file, headingLine: before.headingIndex + 1, title: node.title, sourceRevision: revision, changed: result.changed,
    diff: [...beforeLines.map(line => `-${line}`), ...afterLines.map(line => `+${line}`)],
    fingerprint: fingerprintOf(material),
  };
}

/** Apply a previewed action. Both the fingerprint and the source revision must still match. */
export function applyInteractiveViewAction(root: string, viewId: string, request: unknown, options: { fingerprint: string; sourceRevision: string; actor?: string; now?: Date }) {
  if (!options.fingerprint || !options.sourceRevision) throw new Error("Applying a view action requires the preview --fingerprint and --if-revision");
  const preview = previewInteractiveViewAction(root, viewId, request);
  if (preview.sourceRevision !== options.sourceRevision) throw new GuardedFileConflictError("Source changed after the preview; preview again", { file: preview.file, expectedRevision: options.sourceRevision, actualRevision: preview.sourceRevision });
  if (preview.fingerprint !== options.fingerprint) throw new Error("Preview fingerprint does not match the requested action; preview again");
  const { node, absolute } = findTask(root, preview.action.task);
  const snapshot = readGuardedFile(absolute);
  const result = updatePlanningInText(snapshot.content, { filePath: node.file, lineNumber: node.sourceRange.startLine, kind: "SCHEDULED", date: preview.action.date });
  const written = guardedWriteFile(absolute, result.text, { expectedRevision: options.sourceRevision, preserveMode: true });
  const before = planningSlice(snapshot.content, preview.headingLine), after = planningSlice(result.text, preview.headingLine);
  const entry: InteractiveViewAction = {
    id: crypto.randomUUID(), kind: "schedule", at: (options.now ?? new Date()).toISOString(), actor: options.actor ?? "user",
    task: preview.action.task, file: node.file, headingLine: preview.headingLine, date: preview.action.date,
    before: before.lines.slice(before.start, before.end), after: after.lines.slice(after.start, after.end), revisionAfter: written.revision,
  };
  const history = recordHistory(root, viewId, view => [...view.history, entry].slice(-MAX_HISTORY));
  return { schema: "org2:interactive-view-action:v1", applied: true, viewId, action: preview.action, file: node.file, headingLine: preview.headingLine, revision: written.revision, actionId: entry.id, undo: { actionId: entry.id }, ...history };
}

function recordHistory(root: string, viewId: string, update: (view: InteractiveViewDefinition) => InteractiveViewAction[]) {
  // The canonical source write has already succeeded. A concurrent view edit is
  // reported, not retried blindly, so the caller can refresh and see both.
  try {
    const { view, file, revision } = loadInteractiveView(root, viewId);
    const written = guardedWriteFile(inside(root, file), serialize({ ...view, history: update(view) }), { expectedRevision: revision, preserveMode: true });
    return { viewRevision: written.revision, historyRecorded: true as const };
  } catch (error) {
    return { historyRecorded: false as const, historyWarning: error instanceof Error ? error.message : String(error) };
  }
}

/** Undo exactly one applied action, only if its edited lines are still current. */
export function undoInteractiveViewAction(root: string, viewId: string, actionId: string, options: { apply?: boolean; now?: Date } = {}) {
  const { view } = loadInteractiveView(root, viewId);
  const entry = view.history.find(item => item.id === actionId);
  if (!entry) throw new Error(`Unknown action: ${actionId}`);
  if (entry.undoneAt) throw new Error("Action was already undone");
  const absolute = inside(root, entry.file);
  const snapshot = readGuardedFile(absolute);
  if (snapshot.revision !== entry.revisionAfter) throw new GuardedFileConflictError("Source changed after this action; undo would overwrite newer edits", { file: absolute, expectedRevision: entry.revisionAfter, actualRevision: snapshot.revision });
  const slice = planningSlice(snapshot.content, entry.headingLine);
  const current = slice.lines.slice(slice.start, slice.end);
  if (JSON.stringify(current) !== JSON.stringify(entry.after)) throw new Error("Planning lines differ from the recorded action; refusing to undo");
  const lines = [...slice.lines];
  lines.splice(slice.start, slice.end - slice.start, ...entry.before);
  const text = lines.join("\n");
  const diff = [...entry.after.map(line => `-${line}`), ...entry.before.map(line => `+${line}`)];
  if (!options.apply) return { schema: "org2:interactive-view-undo:v1", applied: false, viewId, actionId, file: entry.file, sourceRevision: snapshot.revision, diff };
  const written = guardedWriteFile(absolute, text, { expectedRevision: snapshot.revision, preserveMode: true });
  const at = (options.now ?? new Date()).toISOString();
  const history = recordHistory(root, viewId, v => v.history.map(item => item.id === actionId ? { ...item, undoneAt: at } : item));
  return { schema: "org2:interactive-view-undo:v1", applied: true, viewId, actionId, file: entry.file, revision: written.revision, diff, ...history };
}

/**
 * Narrow bridge contract for sandboxed view frames.
 *
 * A frame posts `{type: "org2-view-intent", version: 1, viewId, intent, ...}`.
 * Only three intents exist: `set-state` (remember choices), `preview-action`
 * (request a reviewable preview), and `open-source` (navigate to a source task).
 * There is deliberately no apply or undo intent: those require a person to
 * confirm the preview in host chrome outside the sandbox.
 */
export type ViewBridgeIntent =
  | { intent: "set-state"; viewId: string; viewRevision: string; patch: Partial<InteractiveViewState> }
  | { intent: "preview-action"; viewId: string; action: InteractiveViewActionRequest }
  | { intent: "open-source"; viewId: string; task: string };

export function parseViewBridgeIntent(message: unknown, expected: { viewId: string }): ViewBridgeIntent {
  if (!record(message) || message.type !== VIEW_BRIDGE_MESSAGE_TYPE || message.version !== 1) throw new Error("Not an interactive view intent");
  if (JSON.stringify(message).length > 64 * 1024) throw new Error("View intent is too large");
  if (message.viewId !== expected.viewId) throw new Error("View intent targets a different view");
  const common = ["type", "version", "viewId", "intent"];
  const only = (keys: string[]) => { for (const key of Object.keys(message)) if (![...common, ...keys].includes(key)) throw new Error(`Unexpected view intent field: ${key}`); };
  switch (message.intent) {
    case "set-state": {
      only(["viewRevision", "patch"]);
      if (typeof message.viewRevision !== "string" || !/^sha256:[0-9a-f]{64}$/.test(message.viewRevision)) throw new Error("set-state requires the view revision");
      if (!record(message.patch)) throw new Error("set-state requires a patch");
      for (const key of Object.keys(message.patch)) if (!["availableMinutes", "order", "excluded", "estimates"].includes(key)) throw new Error(`Unsupported view state field: ${key}`);
      parseState({ ...message.patch });
      return { intent: "set-state", viewId: expected.viewId, viewRevision: message.viewRevision, patch: message.patch as Partial<InteractiveViewState> };
    }
    case "preview-action":
      only(["action"]);
      return { intent: "preview-action", viewId: expected.viewId, action: parseInteractiveViewActionRequest(message.action) };
    case "open-source":
      only(["task"]);
      return { intent: "open-source", viewId: expected.viewId, task: taskKey(message.task) };
    default:
      throw new Error(`Unsupported view intent: ${String(message.intent)}`);
  }
}

/**
 * Host-side dispatcher for validated intents. It can save choices (guarded by
 * the view revision) and produce previews. It never applies a source change.
 */
export function handleViewBridgeIntent(root: string, message: unknown, expected: { viewId: string }) {
  const intent = parseViewBridgeIntent(message, expected);
  if (intent.intent === "set-state") return updateInteractiveViewState(root, intent.viewId, intent.patch, { expectedRevision: intent.viewRevision, apply: true });
  if (intent.intent === "preview-action") return previewInteractiveViewAction(root, intent.viewId, intent.action);
  const { node } = findTask(root, intent.task);
  return { schema: "org2:interactive-view-open:v1", file: node.file, line: node.sourceRange.startLine, id: node.id };
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/**
 * Render a refreshed view as an Org `html` source block. Celorga already runs
 * such blocks in an opaque-origin sandbox; the embedded data is a snapshot of
 * this refresh, and controls only post bridge intents to the host.
 */
export function renderInteractiveViewOrg(refresh: ReturnType<typeof refreshInteractiveView>): string {
  const data = JSON.stringify({ view: refresh.view, date: refresh.date, state: refresh.state, items: refresh.items, excluded: refresh.excluded.map(i => ({ key: i.key, title: i.title })) }).replace(/</g, "\\u003c");
  const sourceLinks = refresh.items.map(item => `- [[${item.source.link}][${item.title.replace(/[\[\]]/g, "")}]] (${item.source.file}:${item.source.line})`);
  return [
    `#+title: ${refresh.view.title}`,
    `#+celorga_view: ${refresh.view.id}`,
    `#+celorga_view_revision: ${refresh.view.revision}`,
    `#+celorga_view_refreshed: ${refresh.date}`,
    "",
    "* Sources",
    ...sourceLinks,
    "",
    "* Plan",
    "#+begin_src html",
    `<div id="plan" data-view="${escapeHtml(refresh.view.id)}"></div>`,
    "<style>body{font:13px -apple-system,system-ui,sans-serif;margin:0;padding:8px}li{display:flex;gap:6px;align-items:center;padding:3px 0}li.over{opacity:.55}.t{flex:1}button{font:inherit}</style>",
    "<script>",
    `const D=${data};`,
    "const post=(m)=>parent.postMessage(Object.assign({type:'org2-view-intent',version:1,viewId:D.view.id},m),'*');",
    "let order=D.items.map(i=>i.key);",
    "function draw(){const el=document.getElementById('plan');el.textContent='';",
    "const h=document.createElement('div');h.textContent=D.date+' · '+D.state.availableMinutes+' min available';el.appendChild(h);",
    "const ul=document.createElement('ul');ul.style.padding='0';",
    "order.forEach((k,ix)=>{const i=D.items.find(x=>x.key===k);const li=document.createElement('li');if(!i.fits)li.className='over';",
    "const t=document.createElement('span');t.className='t';t.textContent=(i.priority?'['+i.priority+'] ':'')+i.title+' · '+i.estimateMinutes+'m';li.appendChild(t);",
    "const b=(label,fn)=>{const x=document.createElement('button');x.textContent=label;x.onclick=fn;li.appendChild(x);};",
    "b('↑',()=>{if(ix>0){[order[ix-1],order[ix]]=[order[ix],order[ix-1]];post({intent:'set-state',viewRevision:D.view.revision,patch:{order}});draw();}});",
    "b('Skip',()=>post({intent:'set-state',viewRevision:D.view.revision,patch:{excluded:[...D.state.excluded,k]}}));",
    "b('Tomorrow',()=>{const d=new Date(D.date+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+1);post({intent:'preview-action',action:{action:'schedule',task:k,date:d.toISOString().slice(0,10)}});});",
    "b('Open',()=>post({intent:'open-source',task:k}));",
    "ul.appendChild(li);});el.appendChild(ul);}",
    "draw();",
    "</script>",
    "#+end_src",
    "",
  ].join("\n");
}
