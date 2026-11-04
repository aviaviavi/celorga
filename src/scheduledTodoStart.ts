import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { HeadlineNode, Node, PlanningNode, TimestampNode } from "./ast.js";
import {
  addAgentRunComment,
  agentRunPath,
  createAgentRun,
  listAgentRuns,
  saveAgentRun,
  transitionAgentRun,
  type AgentRun,
} from "./agentRun.js";
import { stateDir } from "./brandNames.js";
import { listOrgLikeFiles } from "./corpusFiles.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { splitSourceLines, upsertHeadlinePropertyInLines } from "./sourceLines.js";
import { parseTimestampRepeater } from "./timestampModifiers.js";
import { isTerminalTodoKeyword, updateTodoInText } from "./todo.js";

/**
 * Starting an assigned TODO at its SCHEDULED time.
 *
 * Celorga never decides on its own to start work. A heading opts in with
 * `:AGENT_START: scheduled`, names its worker with `:AGENT_REF:`, has a stable
 * `:ID:`, and carries a `SCHEDULED:` timestamp with a time of day. When that
 * time passes, the automation driver (the Celorga app or headless server)
 * starts one durable run for the occurrence, the same way "Start work" does.
 */
export const AGENT_START_PROPERTY = "AGENT_START";
export const AGENT_START_SCHEDULED = "scheduled";
export const SCHEDULED_TODO_START_KIND = "scheduled-todo-start" as const;
export const SCHEDULED_TODO_START_SCHEMA = "org2:scheduled-todo-start:v1";
const SCAN_CACHE_SCHEMA = "org2:scheduled-todo-start-scan:v1";
const RUN_PROPERTY = "ORG2_RUN_ID";
const LIVE_RUN_STATUSES = new Set<AgentRun["status"]>(["queued", "running", "waiting-approval", "blocked"]);

export type ScheduledTodoHeading = {
  file: string;
  line: number;
  title: string;
  todo?: string;
  terminal: boolean;
  id?: string;
  agentStart: string;
  agentRef?: string;
  goalRef?: string;
  assignee?: string;
  runId?: string;
  scheduled?: string;
};

export type ScheduledTodoStartItem = {
  kind: typeof SCHEDULED_TODO_START_KIND;
  id: string;
  title: string;
  file: string;
  line: number;
  todo: string;
  agentRef: string;
  goalRef?: string;
  assignee?: string;
  scheduled: string;
  scheduledFor: string;
  idempotencyKey: string;
  runId: string;
};

export type ScheduledTodoNotStartable = {
  kind: typeof SCHEDULED_TODO_START_KIND;
  file: string;
  line: number;
  title: string;
  id?: string;
  reason: string;
};

export type ScheduledTodoStartList = {
  due: ScheduledTodoStartItem[];
  skipped: Array<ScheduledTodoStartItem & { reason: string; activeRunId?: string }>;
  notStartable: ScheduledTodoNotStartable[];
};

type ScanCache = {
  schema: string;
  files: Record<string, { mtimeMs: number; size: number; headings: ScheduledTodoHeading[] }>;
};

function propertiesOf(node: HeadlineNode): Record<string, string> {
  const drawer = node.children.find((child) => child.type === "PropertyDrawer");
  if (!drawer || drawer.type !== "PropertyDrawer") return {};
  return Object.fromEntries(drawer.properties.map((property) => [property.key.toUpperCase(), property.value.trim()]));
}

function inlineText(node: HeadlineNode["title"][number]): string {
  if (node.type === "Text") return node.value;
  if (node.type === "Link") return node.descriptionRaw || node.targetRaw;
  if (node.type === "Emphasis") return node.content;
  if (node.type === "Timestamp") return node.raw;
  return "raw" in node ? String(node.raw) : "";
}

/** Headings in `text` that carry `:AGENT_START:`; everything else is ignored. */
export function extractAgentStartHeadings(text: string, relativeFile: string, sourcePath?: string): ScheduledTodoHeading[] {
  if (!/^\s*:AGENT_START:/im.test(text)) return [];
  const document = parseOrgToCanonicalAst(text, { sourceRanges: true, ...(sourcePath ? { sourcePath } : {}) });
  const output: ScheduledTodoHeading[] = [];
  const walk = (nodes: Node[]) => {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const properties = propertiesOf(node);
      if (properties[AGENT_START_PROPERTY] !== undefined) {
        const planning = node.children.find((child): child is PlanningNode => child.type === "Planning" && child.kind === "SCHEDULED");
        const runKey = ["CELORGA_RUN_ID", RUN_PROPERTY].find((key) => properties[key]);
        const todo = node.todo;
        output.push({
          file: relativeFile,
          line: (node as HeadlineNode & { sourceRange?: { startLine: number } }).sourceRange?.startLine ?? 1,
          title: node.title.map(inlineText).join("").replace(/^\s*\[#[A-Za-z0-9]\]\s*/, "").trim(),
          ...(todo ? { todo } : {}),
          terminal: todo ? (node.todoTerminal ?? isTerminalTodoKeyword(todo)) : false,
          ...(properties.ID ? { id: properties.ID } : {}),
          agentStart: properties[AGENT_START_PROPERTY] ?? "",
          ...(properties.AGENT_REF ? { agentRef: properties.AGENT_REF } : {}),
          ...(properties.GOAL_REF ? { goalRef: properties.GOAL_REF } : {}),
          ...(properties.ASSIGNEE ? { assignee: properties.ASSIGNEE } : {}),
          ...(runKey ? { runId: properties[runKey] } : {}),
          ...(planning ? { scheduled: planning.timestamp ? timestampRaw(planning.timestamp) : planning.raw.replace(/^SCHEDULED:\s*/i, "") } : {}),
        });
      }
      walk(node.children);
    }
  };
  walk(document.children);
  return output;
}

function timestampRaw(timestamp: PlanningNode["timestamp"]): string {
  if (!timestamp) return "";
  return timestamp.type === "TimestampRange" ? timestamp.start.raw : (timestamp as TimestampNode).raw;
}

function scanCachePath(corpus: string): string {
  return stateDir(corpus, "scheduled-todo-starts", "scan-v1.json");
}

/**
 * Scans the corpus for opted-in headings. Unchanged files reuse a disposable
 * machine-local cache keyed by modification time and size.
 */
export function scanAgentStartHeadings(corpusRoot: string): ScheduledTodoHeading[] {
  const corpus = path.resolve(corpusRoot);
  const cacheFile = scanCachePath(corpus);
  let cache: ScanCache = { schema: SCAN_CACHE_SCHEMA, files: {} };
  try {
    const loaded = JSON.parse(fs.readFileSync(cacheFile, "utf8")) as ScanCache;
    if (loaded?.schema === SCAN_CACHE_SCHEMA && loaded.files && typeof loaded.files === "object") cache = loaded;
  } catch { /* A missing or unreadable cache is rebuilt. */ }
  const next: ScanCache = { schema: SCAN_CACHE_SCHEMA, files: {} };
  let dirty = false;
  const headings: ScheduledTodoHeading[] = [];
  for (const absolute of listOrgLikeFiles(corpus, true)) {
    const relative = path.relative(corpus, absolute).split(path.sep).join("/");
    if (!relative || relative.startsWith("..") || relative.startsWith("workflows/")) continue;
    let stat: fs.Stats;
    try { stat = fs.statSync(absolute); } catch { continue; }
    const cached = cache.files[relative];
    let found: ScheduledTodoHeading[];
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
      found = cached.headings;
    } else {
      dirty = true;
      try { found = extractAgentStartHeadings(fs.readFileSync(absolute, "utf8"), relative, absolute); } catch { found = []; }
    }
    next.files[relative] = { mtimeMs: stat.mtimeMs, size: stat.size, headings: found };
    headings.push(...found);
  }
  if (dirty || Object.keys(cache.files).length !== Object.keys(next.files).length) {
    try {
      fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
      const temporary = `${cacheFile}.${process.pid}.tmp`;
      fs.writeFileSync(temporary, `${JSON.stringify(next)}\n`);
      fs.renameSync(temporary, cacheFile);
    } catch { /* The cache only saves work; scanning stays correct without it. */ }
  }
  return headings;
}

type ParsedScheduled = { base: Date; repeater?: { value: number; unit: "d" | "w" | "m" | "y" } };

/** Parses an active Org timestamp that has a time of day, in local time. */
export function parseScheduledTimestamp(raw: string): ParsedScheduled | null {
  const match = /^<(\d{4})-(\d{2})-(\d{2})(?:\s+[^\s\d>]+)?\s+(\d{1,2}):(\d{2})(?:-\d{1,2}:\d{2})?([^>]*)>/.exec(String(raw || "").trim());
  if (!match) return null;
  const [year, month, day, hour, minute] = match.slice(1, 6).map((part) => Number(part));
  if (hour! > 23 || minute! > 59) return null;
  const base = new Date(year!, month! - 1, day!, hour!, minute!, 0, 0);
  if (Number.isNaN(base.getTime()) || base.getDate() !== day) return null;
  const repeater = parseTimestampRepeater(match[6] || "");
  return repeater ? { base, repeater: { value: repeater.value, unit: repeater.unit as "d" | "w" | "m" | "y" } } : { base };
}

function addRepeats(base: Date, repeater: NonNullable<ParsedScheduled["repeater"]>, count: number): Date {
  const date = new Date(base.getTime());
  const amount = repeater.value * count;
  if (repeater.unit === "d") date.setDate(date.getDate() + amount);
  else if (repeater.unit === "w") date.setDate(date.getDate() + amount * 7);
  else if (repeater.unit === "m") date.setMonth(date.getMonth() + amount);
  else date.setFullYear(date.getFullYear() + amount);
  return date;
}

/**
 * The occurrence to start: the scheduled time itself, or for a repeater the
 * latest occurrence at or before `now`, so missed occurrences start once.
 * Returns null while the scheduled time is still in the future.
 */
export function latestScheduledOccurrence(scheduled: ParsedScheduled, now: Date): Date | null {
  if (scheduled.base.getTime() > now.getTime()) return null;
  const repeater = scheduled.repeater;
  if (!repeater) return scheduled.base;
  const approximateDays = { d: 1, w: 7, m: 30.4375, y: 365.25 }[repeater.unit] * repeater.value;
  let count = Math.max(0, Math.floor((now.getTime() - scheduled.base.getTime()) / (approximateDays * 86_400_000)));
  while (count > 0 && addRepeats(scheduled.base, repeater, count).getTime() > now.getTime()) count -= 1;
  while (addRepeats(scheduled.base, repeater, count + 1).getTime() <= now.getTime()) count += 1;
  return addRepeats(scheduled.base, repeater, count);
}

export function scheduledTodoIdempotencyKey(id: string, scheduledFor: string): string {
  return `scheduled-start:${id}:${scheduledFor}`;
}

/** The durable run ID for one occurrence; creating it twice fails atomically. */
export function scheduledTodoRunId(idempotencyKey: string): string {
  return `scheduled-start-${crypto.createHash("sha256").update(idempotencyKey).digest("hex").slice(0, 24)}`;
}

/** Classifies opted-in headings into due, skipped, and not startable at `now`. */
export function classifyScheduledTodoStarts(
  headings: readonly ScheduledTodoHeading[],
  runs: readonly AgentRun[],
  nowRaw?: string,
): ScheduledTodoStartList {
  const now = new Date(nowRaw || Date.now());
  if (Number.isNaN(now.getTime())) throw new Error(`invalid timestamp: ${nowRaw}`);
  const runsById = new Map(runs.map((run) => [run.id, run]));
  const result: ScheduledTodoStartList = { due: [], skipped: [], notStartable: [] };
  for (const heading of headings) {
    // A heading without a TODO keyword, or a closed one, is not a task to start.
    if (!heading.todo || heading.terminal) continue;
    const base = { kind: SCHEDULED_TODO_START_KIND, file: heading.file, line: heading.line, title: heading.title, ...(heading.id ? { id: heading.id } : {}) };
    const refuse = (reason: string) => { result.notStartable.push({ ...base, reason }); };
    if (heading.agentStart.trim().toLowerCase() !== AGENT_START_SCHEDULED) {
      refuse(`:AGENT_START: ${heading.agentStart || "(empty)"} is not supported; use :AGENT_START: scheduled`);
      continue;
    }
    if (!heading.agentRef) { refuse("Add :AGENT_REF: to name who starts this TODO."); continue; }
    if (!heading.scheduled) { refuse("Add a SCHEDULED timestamp with a time of day."); continue; }
    const parsed = parseScheduledTimestamp(heading.scheduled);
    if (!parsed) { refuse(`SCHEDULED ${heading.scheduled} has no time of day; add one, such as <2026-11-05 Thu 09:00>.`); continue; }
    if (!heading.id) { refuse("Add an :ID: so the scheduled start can be recorded exactly once."); continue; }
    const occurrence = latestScheduledOccurrence(parsed, now);
    if (!occurrence) continue;
    const scheduledFor = occurrence.toISOString();
    const idempotencyKey = scheduledTodoIdempotencyKey(heading.id, scheduledFor);
    const item: ScheduledTodoStartItem = {
      kind: SCHEDULED_TODO_START_KIND,
      id: heading.id,
      title: heading.title,
      file: heading.file,
      line: heading.line,
      todo: heading.todo,
      agentRef: heading.agentRef,
      ...(heading.goalRef ? { goalRef: heading.goalRef } : {}),
      ...(heading.assignee ? { assignee: heading.assignee } : {}),
      scheduled: heading.scheduled,
      scheduledFor,
      idempotencyKey,
      runId: scheduledTodoRunId(idempotencyKey),
    };
    const existing = runsById.get(item.runId);
    if (existing) {
      result.skipped.push({ ...item, reason: `occurrence already started as run ${existing.id}`, activeRunId: existing.id });
      continue;
    }
    const linked = heading.runId ? runsById.get(heading.runId) : undefined;
    if (linked && LIVE_RUN_STATUSES.has(linked.status)) {
      result.skipped.push({ ...item, reason: `heading already has ${linked.status} run ${linked.id}`, activeRunId: linked.id });
      continue;
    }
    const live = runs.find((run) => run.logicalWorkId === `scheduled-start:${heading.id}` && LIVE_RUN_STATUSES.has(run.status));
    if (live) {
      result.skipped.push({ ...item, reason: `earlier scheduled start ${live.id} is ${live.status}`, activeRunId: live.id });
      continue;
    }
    result.due.push(item);
  }
  const order = (a: { file: string; line: number }, b: { file: string; line: number }) => a.file.localeCompare(b.file) || a.line - b.line;
  result.due.sort(order);
  result.skipped.sort(order);
  result.notStartable.sort(order);
  return result;
}

export function listScheduledTodoStarts(corpusRoot: string, options: { now?: string; runs?: AgentRun[] } = {}): ScheduledTodoStartList {
  const corpus = path.resolve(corpusRoot);
  return classifyScheduledTodoStarts(scanAgentStartHeadings(corpus), options.runs ?? listAgentRuns(corpus), options.now);
}

/** The task message for the started run; matches the app's Start work prompt. */
export function scheduledTodoStartPrompt(item: Pick<ScheduledTodoStartItem, "title" | "id" | "file" | "line">, runId: string): string {
  return [
    "Start work on this TODO from my corpus.",
    "",
    `Task: ${item.title}`,
    `Source: [[id:${item.id}][${item.title.replace(/[[\]]/g, "")}]] (${item.file}:${item.line})`,
    `Durable run: ${runId}`,
    "",
    "Read the heading, its notes, and nearby context first. Then do the work. If the task is ambiguous, reply with a short plan and the specific questions you need answered instead of guessing.",
    "",
    "When you finish:",
    `- Add a short outcome note under the heading. Keep its :PROPERTIES: drawer, :ID:, and :${RUN_PROPERTY}: intact.`,
    "- Mark the heading DONE only if the task is actually complete.",
    `- If you can run the Celorga CLI, close the run with \`celorga run complete ${runId} --summary "…"\`, or \`celorga run block ${runId} --reason "…"\` when you need me.`,
  ].join("\n");
}

export type ScheduledTodoStartResult = {
  schema: typeof SCHEDULED_TODO_START_SCHEMA;
  status: "preview" | "started" | "skipped" | "not-due" | "not-startable";
  applied: boolean;
  reason?: string;
  item?: ScheduledTodoStartItem;
  run?: AgentRun;
  runFile?: string;
  heading?: { file: string; line: number; changed: boolean; error?: string };
  prompt?: string;
};

/**
 * Starts the durable run for the due occurrence of the heading with `id`.
 * Preview by default. With `apply`, the run is created with a deterministic
 * ID (so a second start of the same occurrence fails atomically), moved to
 * running, linked to the heading with `:ORG2_RUN_ID:`, and the TODO moves to
 * IN_PROGRESS, as "Start work" does.
 */
export function startScheduledTodo(corpusRoot: string, options: {
  id: string;
  scheduledFor?: string;
  now?: string;
  apply?: boolean;
  actor?: string;
}): ScheduledTodoStartResult {
  const corpus = path.resolve(corpusRoot);
  const wanted = String(options.id || "").trim().toLowerCase();
  if (!wanted) throw new Error("--id is required");
  const base = { schema: SCHEDULED_TODO_START_SCHEMA, applied: false } as const;
  const list = listScheduledTodoStarts(corpus, { now: options.now });
  const refused = list.notStartable.find((item) => item.id?.toLowerCase() === wanted);
  if (refused) return { ...base, status: "not-startable", reason: refused.reason };
  const skipped = list.skipped.find((item) => item.id.toLowerCase() === wanted);
  const item = list.due.find((candidate) => candidate.id.toLowerCase() === wanted);
  if (!item) {
    return skipped
      ? { ...base, status: "skipped", reason: skipped.reason, item: skipped }
      : { ...base, status: "not-due", reason: `No opted-in TODO with ID ${options.id} is due.` };
  }
  if (options.scheduledFor && new Date(options.scheduledFor).getTime() !== new Date(item.scheduledFor).getTime()) {
    return { ...base, status: "skipped", reason: `The due occurrence is now ${item.scheduledFor}, not ${options.scheduledFor}.`, item };
  }
  const actor = options.actor || "Celorga Automation Scheduler";
  const created = createAgentRun({
    id: item.runId,
    title: `Work: ${item.title}`.slice(0, 120),
    goal: item.title,
    context: [{ ref: `id:${item.id}`, title: item.title, citation: `${item.file}:${item.line}` }],
    owner: "Celorga",
    assignee: item.assignee || item.agentRef,
    agentRef: item.agentRef,
    ...(item.goalRef ? { goalRef: item.goalRef } : {}),
    logicalWorkId: `scheduled-start:${item.id}`,
    attempt: { id: item.runId, number: 1, triggerId: "scheduled", triggerType: SCHEDULED_TODO_START_KIND, scheduledFor: item.scheduledFor },
    now: options.now,
  });
  const run = addAgentRunComment(
    transitionAgentRun(created, "running", { actor, now: options.now }),
    actor,
    `Started at the SCHEDULED time ${item.scheduled} (occurrence ${item.scheduledFor}) because the heading has :${AGENT_START_PROPERTY}: ${AGENT_START_SCHEDULED}.\nIdempotency key: ${item.idempotencyKey}`,
    options.now,
  );
  const prompt = scheduledTodoStartPrompt(item, run.id);
  if (!options.apply) return { ...base, status: "preview", item, run, prompt };

  let runFile: string;
  try {
    runFile = saveAgentRun(corpus, run, { expectedRevision: null });
  } catch (error) {
    // Another driver started this occurrence between the check and the write.
    if (fs.existsSync(agentRunPath(corpus, run.id))) {
      return { ...base, status: "skipped", reason: `occurrence already started as run ${run.id}`, item };
    }
    throw error;
  }
  const heading = linkHeading(corpus, item, run.id);
  return { ...base, applied: true, status: "started", item, run, runFile, heading, prompt };
}

function linkHeading(corpus: string, item: ScheduledTodoStartItem, runId: string): NonNullable<ScheduledTodoStartResult["heading"]> {
  const file = path.join(corpus, item.file);
  try {
    const snapshot = readGuardedFile(file);
    const lines = splitSourceLines(snapshot.content);
    const index = lines.findIndex((line, at) => /^\*+\s/.test(line) && headingHasId(lines, at, item.id));
    if (index < 0) throw new Error(`no heading has :ID: ${item.id} any more; the run still cites it`);
    const runKey = headingProperties(lines, index).CELORGA_RUN_ID !== undefined ? "CELORGA_RUN_ID" : RUN_PROPERTY;
    upsertHeadlinePropertyInLines(lines, index, runKey, runId);
    let text = lines.join("\n");
    if (item.todo === "TODO" || item.todo === "NEXT") {
      try {
        text = updateTodoInText(text, { filePath: file, lineNumber: index + 1, status: "in_progress" }).text;
      } catch { /* Custom keyword sets may not declare IN_PROGRESS; the run still starts. */ }
    }
    guardedWriteFile(file, text, { expectedRevision: snapshot.revision, preserveMode: true });
    return { file: item.file, line: index + 1, changed: true };
  } catch (error) {
    return { file: item.file, line: item.line, changed: false, error: error instanceof Error ? error.message : String(error) };
  }
}

function headingProperties(lines: string[], headingIndex: number): Record<string, string> {
  const properties: Record<string, string> = {};
  let at = headingIndex + 1;
  while (at < lines.length && /^\s*(SCHEDULED|DEADLINE|CLOSED):/.test(lines[at] ?? "")) at += 1;
  if (!/^\s*:PROPERTIES:\s*$/i.test(lines[at] ?? "")) return properties;
  for (at += 1; at < lines.length; at += 1) {
    const line = lines[at] ?? "";
    if (/^\s*:END:\s*$/i.test(line) || /^\*+\s/.test(line)) break;
    const match = /^\s*:([^:\s]+):\s*(.*)$/.exec(line);
    if (match) properties[match[1]!.toUpperCase()] = match[2]!.trim();
  }
  return properties;
}

function headingHasId(lines: string[], headingIndex: number, id: string): boolean {
  return headingProperties(lines, headingIndex).ID?.toLowerCase() === id.toLowerCase();
}
