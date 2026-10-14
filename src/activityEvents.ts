/**
 * Local activity event stream and race-free waits.
 *
 * Events come from durable, structured records:
 * - run transitions and approval requests/decisions are replayed from each
 *   run's append-only event log, so they carry their original timestamps and
 *   stable IDs (`run:<run>:<event>`);
 * - chat replies and prompts come from committed transcript messages and the
 *   AI chat inbox;
 * - workflow dispatches come from trigger attempt timestamps;
 * - live turn starts/finishes and host connection changes come from host
 *   presence records and are observed while following.
 *
 * Waits evaluate their condition against durable state before they start
 * watching, so a reply or transition that lands between "prompt" and "wait"
 * is never missed.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { agentRunDirectory, parseAgentRunOrg, type AgentRun } from "./agentRun.js";
import { listWorkflows, workflowDirectory, workflowScheduleTrigger, type AgentWorkflow } from "./agentWorkflow.js";
import { aiChatInboxDirectory } from "./aiChatOperationJournal.js";
import {
  explainRun,
  explainThread,
  isHostLive,
  liveHostDirectory,
  loadActivityHosts,
  messageTime,
  pendingInboxMessages,
  type ActivityExplanation,
  type ActivityHost,
  type ActivityHostState,
} from "./activityState.js";
import { automationHostRef } from "./automationHost.js";
import {
  findOpenClawThread,
  loadOpenClawThreadState,
  openClawDateMilliseconds,
  openClawTranscriptStorePath,
  type OpenClawChatThreadRecord,
  type OpenClawThreadState,
} from "./openClawThreadState.js";
import { isOrgRecordFileName, orgRecordPath, schemaMatches, stateDir } from "./brandNames.js";

export const ACTIVITY_EVENT_SCHEMA = "org2:activity-event:v1" as const;
export const ACTIVITY_WAIT_SCHEMA = "org2:activity-wait:v1" as const;

export const ACTIVITY_EVENT_TYPES = [
  "run.created",
  "run.queued",
  "run.running",
  "run.waiting-approval",
  "run.blocked",
  "run.completed",
  "run.failed",
  "run.canceled",
  "approval.requested",
  "approval.decided",
  "thread.prompted",
  "thread.working",
  "thread.reply-received",
  "thread.needs-you",
  "thread.idle",
  "workflow.dispatched",
  "host.online",
  "host.reconnecting",
  "host.authentication-needed",
  "host.stale",
  "host.offline",
] as const;
export type ActivityEventType = (typeof ACTIVITY_EVENT_TYPES)[number];

export interface ActivityEvent {
  schema: typeof ACTIVITY_EVENT_SCHEMA;
  id: string;
  type: ActivityEventType;
  at: string;
  subject: { kind: "run" | "approval" | "thread" | "workflow" | "host"; id: string; title?: string; runId?: string; threadId?: string };
  source: "run-event" | "transcript" | "inbox" | "workflow" | "presence";
  detail?: string;
  data?: Record<string, unknown>;
}

type JSONRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JSONRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizedID(value: string): string {
  return value.trim().toLowerCase();
}

function eventID(...parts: string[]): string {
  return parts.join(":");
}

// MARK: - Incremental durable readers

/** Re-parses only run files whose size or modification time changed. */
export class RunRecordCache {
  private readonly entries = new Map<string, { mtimeMs: number; size: number; run: AgentRun | null }>();
  constructor(private readonly corpusRoot: string) {}

  /** Returns every run plus the IDs whose files changed since the previous call. */
  refresh(): { runs: AgentRun[]; changed: AgentRun[] } {
    const directory = agentRunDirectory(this.corpusRoot);
    let names: string[] = [];
    try {
      names = fs.readdirSync(directory).filter((name) => isOrgRecordFileName(name));
    } catch {
      names = [];
    }
    const seen = new Set<string>();
    const changed: AgentRun[] = [];
    for (const name of names) {
      const file = path.join(directory, name);
      seen.add(file);
      let stat: fs.Stats;
      try { stat = fs.statSync(file); } catch { continue; }
      const cached = this.entries.get(file);
      if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) continue;
      let run: AgentRun | null = null;
      try { run = parseAgentRunOrg(fs.readFileSync(file, "utf8")); } catch { run = null; }
      this.entries.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, run });
      if (run) changed.push(run);
    }
    for (const file of [...this.entries.keys()]) if (!seen.has(file)) this.entries.delete(file);
    return { runs: [...this.entries.values()].flatMap((entry) => (entry.run ? [entry.run] : [])), changed };
  }

  load(id: string): AgentRun | undefined {
    const file = orgRecordPath(agentRunDirectory(this.corpusRoot), id);
    try {
      const stat = fs.statSync(file);
      const cached = this.entries.get(file);
      if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.run ?? undefined;
      const run = parseAgentRunOrg(fs.readFileSync(file, "utf8"));
      this.entries.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, run });
      return run;
    } catch {
      return undefined;
    }
  }
}

/** A cheap fingerprint of the chat store's commit pointers. */
function threadStoreFingerprint(corpusRoot: string): string {
  const store = openClawTranscriptStorePath(corpusRoot);
  const parts: string[] = [];
  for (const candidate of [store, path.join(store, "heads"), path.join(store, "manifests"), path.join(path.dirname(store), "openclaw-chat.json")]) {
    try {
      const stat = fs.statSync(candidate);
      parts.push(`${candidate}:${stat.mtimeMs}:${stat.size}`);
      if (stat.isDirectory()) {
        for (const name of fs.readdirSync(candidate)) {
          if (name === "threads" || name === "live") continue;
          try {
            const child = fs.statSync(path.join(candidate, name));
            if (child.isFile()) parts.push(`${name}:${child.mtimeMs}:${child.size}`);
          } catch { /* raced with a writer */ }
        }
      }
    } catch {
      parts.push(`${candidate}:missing`);
    }
  }
  return crypto.createHash("sha256").update(parts.join("\n")).digest("hex");
}

function directoryFingerprint(directory: string): string {
  try {
    const names = fs.readdirSync(directory).sort();
    return crypto.createHash("sha256").update(names.map((name) => {
      try {
        const stat = fs.statSync(path.join(directory, name));
        return `${name}:${stat.mtimeMs}:${stat.size}`;
      } catch {
        return `${name}:gone`;
      }
    }).join("\n")).digest("hex");
  } catch {
    return "missing";
  }
}

// MARK: - Event derivation

const RUN_STATUS_EVENTS: Record<string, ActivityEventType> = {
  queued: "run.queued",
  running: "run.running",
  "waiting-approval": "run.waiting-approval",
  blocked: "run.blocked",
  completed: "run.completed",
  failed: "run.failed",
  canceled: "run.canceled",
};

export function runActivityEvents(run: AgentRun, sinceMs = Number.NEGATIVE_INFINITY): ActivityEvent[] {
  const title = run.title?.trim() || run.goal;
  const events: ActivityEvent[] = [];
  for (const event of run.events) {
    const at = Date.parse(event.at);
    if (!Number.isFinite(at) || at <= sinceMs) continue;
    const common = { schema: ACTIVITY_EVENT_SCHEMA, at: new Date(at).toISOString(), source: "run-event" as const };
    if (event.type === "created") {
      events.push({ ...common, id: eventID("run", run.id, event.id), type: "run.created", subject: { kind: "run", id: run.id, title }, ...(event.actor ? { data: { actor: event.actor } } : {}) });
    } else if (event.type === "status-changed") {
      const to = String(event.data?.to ?? "");
      const type = RUN_STATUS_EVENTS[to];
      if (!type) continue;
      events.push({
        ...common,
        id: eventID("run", run.id, event.id),
        type,
        subject: { kind: "run", id: run.id, title },
        ...(event.detail ? { detail: event.detail } : {}),
        data: { from: event.data?.from ?? null, to, ...(event.actor ? { actor: event.actor } : {}), ...(to === "blocked" && run.blockedReason ? { reason: run.blockedReason } : {}) },
      });
    } else if (event.type === "approval-requested" || event.type === "approval-decided") {
      const approvalId = String(event.data?.approvalId ?? "");
      const approval = run.approvals.find((item) => item.id === approvalId);
      events.push({
        ...common,
        id: eventID("run", run.id, event.id),
        type: event.type === "approval-requested" ? "approval.requested" : "approval.decided",
        subject: { kind: "approval", id: approvalId, title: approval?.title, runId: run.id },
        ...(event.detail ? { detail: event.detail } : {}),
        data: {
          ...(approval ? { action: approval.action, riskClass: approval.riskClass, fingerprint: approval.fingerprint } : {}),
          ...(event.type === "approval-decided" ? { decision: event.data?.decision ?? approval?.status } : {}),
          ...(event.actor ? { actor: event.actor } : {}),
        },
      });
    }
  }
  return events;
}

export function threadMessageEvents(thread: OpenClawChatThreadRecord, sinceMs = Number.NEGATIVE_INFINITY): ActivityEvent[] {
  const events: ActivityEvent[] = [];
  for (const message of thread.messages ?? []) {
    const at = messageTime(message);
    if (!Number.isFinite(at) || at <= sinceMs || !message.id) continue;
    if (message.role !== "assistant" && message.role !== "user") continue;
    if (message.role === "user" && message.isRoomDispatchCopy === true) continue;
    events.push({
      schema: ACTIVITY_EVENT_SCHEMA,
      id: eventID("thread", normalizedID(thread.id), "message", normalizedID(String(message.id))),
      type: message.role === "assistant" ? "thread.reply-received" : "thread.prompted",
      at: new Date(at).toISOString(),
      subject: { kind: "thread", id: thread.id, title: typeof thread.title === "string" ? thread.title : undefined },
      source: "transcript",
      data: {
        messageId: message.id,
        ...(typeof message.authorLabel === "string" ? { author: message.authorLabel } : {}),
        ...(typeof message.deliveryStatus === "string" ? { deliveryStatus: message.deliveryStatus } : {}),
      },
    });
  }
  return events;
}

function inboxEvents(corpusRoot: string, sinceMs: number): ActivityEvent[] {
  return pendingInboxMessages(corpusRoot).filter((message) => !message.isSend).flatMap((message) => {
    const at = Date.parse(message.createdAt);
    if (!Number.isFinite(at) || at <= sinceMs) return [];
    return [{
      schema: ACTIVITY_EVENT_SCHEMA,
      id: eventID("thread", normalizedID(message.threadID), "message", normalizedID(message.id)),
      type: "thread.reply-received" as const,
      at: new Date(at).toISOString(),
      subject: { kind: "thread" as const, id: message.threadID },
      source: "inbox" as const,
      data: { messageId: message.id, ...(message.authorLabel ? { author: message.authorLabel } : {}), ...(message.source ? { reference: message.source } : {}), pendingImport: true },
    }];
  });
}

function workflowEvents(workflow: AgentWorkflow, sinceMs: number): ActivityEvent[] {
  return workflow.triggers.flatMap((trigger) => {
    const raw = trigger.lastAttemptAt ?? trigger.lastRunAt;
    const at = Date.parse(raw ?? "");
    if (!Number.isFinite(at) || at <= sinceMs) return [];
    return [{
      schema: ACTIVITY_EVENT_SCHEMA,
      id: eventID("workflow", workflow.id, trigger.id, new Date(at).toISOString()),
      type: "workflow.dispatched" as const,
      at: new Date(at).toISOString(),
      subject: { kind: "workflow" as const, id: workflow.id, title: workflow.title },
      source: "workflow" as const,
      data: { triggerId: trigger.id, triggerType: trigger.type, ...(trigger.schedule ? { schedule: trigger.schedule } : {}) },
    }];
  });
}

function hostEvent(host: ActivityHost, at: Date): ActivityEvent {
  return {
    schema: ACTIVITY_EVENT_SCHEMA,
    id: eventID("host", host.hostRef, host.state, host.lastSeenAt),
    type: `host.${host.state}` as ActivityEventType,
    at: at.toISOString(),
    subject: { kind: "host", id: host.hostRef, title: host.hostName },
    source: "presence",
    detail: host.stateReason,
    data: { hostKind: host.hostKind, lastSeenAt: host.lastSeenAt, activeTurns: host.turns.length },
  };
}

function liveTurnEvent(type: "thread.working" | "thread.idle", threadID: string, host: ActivityHost, at: Date, detail?: string): ActivityEvent {
  return {
    schema: ACTIVITY_EVENT_SCHEMA,
    id: eventID("thread", normalizedID(threadID), type === "thread.working" ? "turn-started" : "turn-finished", at.toISOString()),
    type,
    at: at.toISOString(),
    subject: { kind: "thread", id: threadID },
    source: "presence",
    ...(detail ? { detail } : {}),
    data: { hostRef: host.hostRef, hostName: host.hostName },
  };
}

// MARK: - Filtering

export interface ActivityEventFilter {
  types?: string[];
  runId?: string;
  threadId?: string;
  workflowId?: string;
}

export function matchesActivityEventFilter(event: ActivityEvent, filter: ActivityEventFilter): boolean {
  if (filter.types?.length && !filter.types.some((pattern) => pattern === event.type
      || (pattern.endsWith(".*") && event.type.startsWith(pattern.slice(0, -1)))
      || (pattern.endsWith("*") && event.type.startsWith(pattern.slice(0, -1))))) {
    return false;
  }
  if (filter.runId && event.subject.id !== filter.runId && event.subject.runId !== filter.runId) return false;
  if (filter.threadId && normalizedID(event.subject.threadId ?? (event.subject.kind === "thread" ? event.subject.id : "")) !== normalizedID(filter.threadId)) return false;
  if (filter.workflowId && !(event.subject.kind === "workflow" && event.subject.id === filter.workflowId)) return false;
  return true;
}

// MARK: - History and following

export interface ActivityEventHistoryOptions {
  since: Date;
  now?: Date;
  filter?: ActivityEventFilter;
  /** Maximum number of threads to hydrate when replaying chat messages. */
  threadLimit?: number;
}

function safeThreadState(corpusRoot: string): OpenClawThreadState | null {
  try { return loadOpenClawThreadState(corpusRoot); } catch { return null; }
}

function hydratedThread(corpusRoot: string, id: string): OpenClawChatThreadRecord | undefined {
  try {
    return findOpenClawThread(loadOpenClawThreadState(corpusRoot, { hydrateThreadID: id }), id);
  } catch {
    return undefined;
  }
}

/** Replays durable events recorded after `since`, oldest first. */
export function activityEventHistory(corpusRootRaw: string, options: ActivityEventHistoryOptions, runCache?: RunRecordCache): ActivityEvent[] {
  const corpusRoot = path.resolve(corpusRootRaw);
  const sinceMs = options.since.getTime();
  const filter = options.filter ?? {};
  const wants = (prefix: string) => !filter.types?.length || filter.types.some((type) => type.startsWith(prefix) || type === "*");
  const events: ActivityEvent[] = [];
  if (wants("run.") || wants("approval.")) {
    const runs = (runCache ?? new RunRecordCache(corpusRoot)).refresh().runs;
    for (const run of runs) {
      if (filter.runId && run.id !== filter.runId) continue;
      if (Date.parse(run.updatedAt) <= sinceMs) continue;
      events.push(...runActivityEvents(run, sinceMs));
    }
  }
  if (wants("thread.") && !filter.runId && !filter.workflowId) {
    const state = safeThreadState(corpusRoot);
    const candidates = (state?.threads ?? [])
      .filter((thread) => openClawDateMilliseconds(thread.updatedAt) > sinceMs)
      .filter((thread) => !filter.threadId || normalizedID(thread.id) === normalizedID(filter.threadId))
      .sort((lhs, rhs) => openClawDateMilliseconds(rhs.updatedAt) - openClawDateMilliseconds(lhs.updatedAt))
      .slice(0, options.threadLimit ?? 50);
    for (const thread of candidates) {
      const hydrated = hydratedThread(corpusRoot, thread.id) ?? thread;
      events.push(...threadMessageEvents(hydrated, sinceMs));
    }
    events.push(...inboxEvents(corpusRoot, sinceMs));
  }
  if (wants("workflow.") && !filter.runId && !filter.threadId) {
    try {
      for (const workflow of listWorkflows(corpusRoot)) events.push(...workflowEvents(workflow, sinceMs));
    } catch { /* unreadable workflows contribute no events */ }
  }
  return events
    .filter((event) => matchesActivityEventFilter(event, filter))
    .sort((lhs, rhs) => lhs.at.localeCompare(rhs.at) || lhs.id.localeCompare(rhs.id));
}

export interface ActivityEventFollowOptions {
  since?: Date;
  filter?: ActivityEventFilter;
  intervalMs?: number;
  signal?: AbortSignal;
  /** Stop after this many matching events (for tests and one-shot consumers). */
  limit?: number;
  now?: () => Date;
}

function watchPaths(corpusRoot: string): string[] {
  return [
    agentRunDirectory(corpusRoot),
    openClawTranscriptStorePath(corpusRoot),
    liveHostDirectory(corpusRoot),
    aiChatInboxDirectory(corpusRoot),
    workflowDirectory(corpusRoot),
    stateDir(corpusRoot, "workflows"),
  ];
}

/**
 * Wakes `onChange` when any watched directory changes, with a polling floor
 * so synchronization tools that bypass file events are still observed.
 */
function changeTrigger(paths: string[], intervalMs: number, signal?: AbortSignal): { next: () => Promise<void>; close: () => void } {
  let pending: (() => void) | null = null;
  let dirty = false;
  const wake = () => {
    dirty = true;
    if (pending) { const resolve = pending; pending = null; resolve(); }
  };
  const watchers: fs.FSWatcher[] = [];
  for (const candidate of paths) {
    try {
      watchers.push(fs.watch(candidate, { persistent: true }, wake));
    } catch {
      // Missing directories are polled.
    }
  }
  const timer = setInterval(wake, intervalMs);
  const abort = () => wake();
  signal?.addEventListener("abort", abort);
  return {
    next: () => new Promise<void>((resolve) => {
      if (dirty) { dirty = false; resolve(); return; }
      pending = () => { dirty = false; resolve(); };
    }),
    close: () => {
      clearInterval(timer);
      for (const watcher of watchers) watcher.close();
      signal?.removeEventListener("abort", abort);
      if (pending) { const resolve = pending; pending = null; resolve(); }
    },
  };
}

/** Streams events as they happen. Replays history after `since` first, then follows. */
export async function followActivityEvents(
  corpusRootRaw: string,
  emit: (event: ActivityEvent) => void,
  options: ActivityEventFollowOptions = {},
): Promise<void> {
  const corpusRoot = path.resolve(corpusRootRaw);
  const now = options.now ?? (() => new Date());
  const filter = options.filter ?? {};
  const seen = new Set<string>();
  let emitted = 0;
  const send = (event: ActivityEvent): boolean => {
    if (seen.has(event.id) || !matchesActivityEventFilter(event, filter)) return false;
    seen.add(event.id);
    emit(event);
    emitted += 1;
    return options.limit !== undefined && emitted >= options.limit;
  };
  const runCache = new RunRecordCache(corpusRoot);
  const startedAt = now();
  const since = options.since ?? startedAt;
  for (const event of activityEventHistory(corpusRoot, { since, filter }, runCache)) {
    if (send(event)) return;
  }
  // Baselines for snapshot-derived events.
  const runWatermarks = new Map<string, number>();
  for (const run of runCache.refresh().runs) runWatermarks.set(run.id, Date.parse(run.updatedAt));
  let threadFingerprint = threadStoreFingerprint(corpusRoot);
  let threadUpdatedAt = new Map<string, number>((safeThreadState(corpusRoot)?.threads ?? []).map((thread) => [thread.id, openClawDateMilliseconds(thread.updatedAt)]));
  let hostStates = new Map<string, ActivityHostState>(loadActivityHosts(corpusRoot, now()).map((host) => [host.hostRef, host.state]));
  let liveTurns = new Map<string, ActivityHost>();
  for (const host of loadActivityHosts(corpusRoot, now())) if (isHostLive(host)) for (const turn of host.turns) liveTurns.set(normalizedID(turn.threadID), host);
  let inboxFingerprint = directoryFingerprint(aiChatInboxDirectory(corpusRoot));
  let workflowFingerprint = `${directoryFingerprint(workflowDirectory(corpusRoot))}|${directoryFingerprint(stateDir(corpusRoot, "workflows"))}`;
  const workflowAttempts = new Map<string, number>();
  const trigger = changeTrigger(watchPaths(corpusRoot), options.intervalMs ?? 1000, options.signal);
  try {
    while (!options.signal?.aborted) {
      await trigger.next();
      if (options.signal?.aborted) break;
      const tick = now();
      // Runs: replay new entries from changed event logs.
      for (const run of runCache.refresh().changed) {
        const watermark = runWatermarks.get(run.id) ?? since.getTime();
        for (const event of runActivityEvents(run, Math.min(watermark, Number.POSITIVE_INFINITY) - 1)) {
          if (Date.parse(event.at) < since.getTime()) continue;
          if (send(event)) return;
        }
        runWatermarks.set(run.id, Date.parse(run.updatedAt));
      }
      // Chat transcript commits.
      const fingerprint = threadStoreFingerprint(corpusRoot);
      if (fingerprint !== threadFingerprint) {
        threadFingerprint = fingerprint;
        const state = safeThreadState(corpusRoot);
        const next = new Map<string, number>();
        for (const thread of state?.threads ?? []) {
          const updated = openClawDateMilliseconds(thread.updatedAt);
          next.set(thread.id, updated);
          const previous = threadUpdatedAt.get(thread.id);
          if (previous !== undefined && updated <= previous) continue;
          if (filter.threadId && normalizedID(filter.threadId) !== normalizedID(thread.id)) continue;
          const hydrated = hydratedThread(corpusRoot, thread.id) ?? thread;
          for (const event of threadMessageEvents(hydrated, Math.max(previous ?? since.getTime(), since.getTime()))) {
            if (send(event)) return;
          }
          if (hydrated.storedLatestDeliveryNeedsAttention === true) {
            const event: ActivityEvent = {
              schema: ACTIVITY_EVENT_SCHEMA,
              id: eventID("thread", normalizedID(thread.id), "needs-you", String(updated)),
              type: "thread.needs-you",
              at: new Date(Number.isFinite(updated) ? updated : tick.getTime()).toISOString(),
              subject: { kind: "thread", id: thread.id, title: typeof thread.title === "string" ? thread.title : undefined },
              source: "transcript",
              detail: "Latest message needs attention",
            };
            if (send(event)) return;
          }
        }
        threadUpdatedAt = next;
      }
      // Background replies queued in the inbox.
      const inbox = directoryFingerprint(aiChatInboxDirectory(corpusRoot));
      if (inbox !== inboxFingerprint) {
        inboxFingerprint = inbox;
        for (const event of inboxEvents(corpusRoot, since.getTime())) if (send(event)) return;
      }
      // Presence: host state changes and live turn starts/finishes.
      const hosts = loadActivityHosts(corpusRoot, tick);
      const nextStates = new Map<string, ActivityHostState>();
      const nextTurns = new Map<string, ActivityHost>();
      for (const host of hosts) {
        nextStates.set(host.hostRef, host.state);
        if (hostStates.get(host.hostRef) !== host.state) if (send(hostEvent(host, tick))) return;
        if (isHostLive(host)) for (const turn of host.turns) nextTurns.set(normalizedID(turn.threadID), host);
      }
      for (const [threadID, host] of nextTurns) {
        if (liveTurns.has(threadID)) continue;
        const turn = host.turns.find((item) => normalizedID(item.threadID) === threadID);
        if (send(liveTurnEvent("thread.working", turn?.threadID ?? threadID, host, tick, turn?.destinationName ? `via ${turn.destinationName}` : undefined))) return;
      }
      for (const [threadID, host] of liveTurns) {
        if (nextTurns.has(threadID)) continue;
        if (send(liveTurnEvent("thread.idle", threadID, host, tick))) return;
      }
      hostStates = nextStates;
      liveTurns = nextTurns;
      // Workflow dispatches.
      const workflows = `${directoryFingerprint(workflowDirectory(corpusRoot))}|${directoryFingerprint(stateDir(corpusRoot, "workflows"))}`;
      if (workflows !== workflowFingerprint) {
        workflowFingerprint = workflows;
        try {
          for (const workflow of listWorkflows(corpusRoot)) {
            const trigger = workflowScheduleTrigger(workflow);
            const attempt = Date.parse(trigger?.lastAttemptAt ?? trigger?.lastRunAt ?? "");
            const previous = workflowAttempts.get(workflow.id) ?? since.getTime();
            if (Number.isFinite(attempt) && attempt > previous) {
              for (const event of workflowEvents(workflow, previous)) if (send(event)) return;
            }
            if (Number.isFinite(attempt)) workflowAttempts.set(workflow.id, attempt);
          }
        } catch { /* ignore unreadable workflows */ }
      }
    }
  } finally {
    trigger.close();
  }
}

// MARK: - Waits

export const THREAD_WAIT_CONDITIONS = ["reply", "needs-you", "idle", "working"] as const;
export const RUN_WAIT_CONDITIONS = ["approval", "blocked", "needs-you", "running", "completed", "failed", "terminal"] as const;
export type ThreadWaitCondition = (typeof THREAD_WAIT_CONDITIONS)[number];
export type RunWaitCondition = (typeof RUN_WAIT_CONDITIONS)[number] | `status:${string}`;

export interface ActivityWaitResult {
  schema: typeof ACTIVITY_WAIT_SCHEMA;
  subject: { kind: "thread" | "run"; id: string };
  until: string;
  /** `matched`, `unreachable` (the subject can no longer reach the condition), or `timeout`. */
  outcome: "matched" | "unreachable" | "timeout";
  matched: boolean;
  startedAt: string;
  finishedAt: string;
  elapsedSeconds: number;
  /** Reference point used to decide what counts as new (reply waits). */
  baseline?: { messageId?: string; at: string };
  reply?: { messageId: string; at: string; role: string; source: "transcript" | "inbox"; author?: string };
  status?: string;
  explanation?: ActivityExplanation;
}

export interface WaitOptions {
  timeoutSeconds?: number;
  intervalMs?: number;
  signal?: AbortSignal;
  now?: () => Date;
}

async function waitLoop<T>(
  paths: string[],
  options: WaitOptions,
  evaluate: () => T | null,
): Promise<T | null> {
  const first = evaluate();
  if (first !== null) return first;
  const timeoutMs = options.timeoutSeconds !== undefined ? options.timeoutSeconds * 1000 : Number.POSITIVE_INFINITY;
  const controller = new AbortController();
  const timer = Number.isFinite(timeoutMs) ? setTimeout(() => controller.abort(), timeoutMs) : undefined;
  const forward = () => controller.abort();
  options.signal?.addEventListener("abort", forward);
  const trigger = changeTrigger(paths, options.intervalMs ?? 1000, controller.signal);
  try {
    while (!controller.signal.aborted) {
      await trigger.next();
      if (controller.signal.aborted) break;
      const value = evaluate();
      if (value !== null) return value;
    }
    return evaluate();
  } finally {
    if (timer) clearTimeout(timer);
    options.signal?.removeEventListener("abort", forward);
    trigger.close();
  }
}

const TERMINAL_RUN_STATUSES = new Set(["completed", "failed", "canceled"]);

export function runWaitConditionState(run: AgentRun, until: RunWaitCondition, explanation?: ActivityExplanation): "matched" | "pending" | "unreachable" {
  const pendingApproval = run.approvals.some((approval) => approval.status === "pending");
  const terminal = TERMINAL_RUN_STATUSES.has(run.status);
  let matched: boolean;
  switch (until) {
    case "approval": matched = pendingApproval || run.status === "waiting-approval"; break;
    case "blocked": matched = run.status === "blocked"; break;
    case "needs-you": matched = explanation?.needsAttention ?? (run.status === "blocked" || run.status === "waiting-approval"); break;
    case "running": matched = run.status === "running"; break;
    case "completed": matched = run.status === "completed"; break;
    case "failed": matched = run.status === "failed"; break;
    case "terminal": matched = terminal; break;
    default: matched = until.startsWith("status:") && run.status === until.slice("status:".length); break;
  }
  if (matched) return "matched";
  return terminal ? "unreachable" : "pending";
}

export async function waitForRun(corpusRootRaw: string, runId: string, until: RunWaitCondition, options: WaitOptions = {}): Promise<ActivityWaitResult> {
  const corpusRoot = path.resolve(corpusRootRaw);
  const now = options.now ?? (() => new Date());
  const started = now();
  const cache = new RunRecordCache(corpusRoot);
  if (!cache.load(runId)) throw new Error(`run not found: ${runId}`);
  const automationRef = (() => { try { return automationHostRef(corpusRoot); } catch { return "desktop"; } })();
  const explain = (run: AgentRun): ActivityExplanation => {
    const hosts = loadActivityHosts(corpusRoot, now());
    const hostsByRef = new Map(hosts.map((host) => [host.hostRef, host]));
    const liveTurns = new Map<string, { host: ActivityHost; turn: ActivityHost["turns"][number] }>();
    for (const host of hosts) for (const turn of host.turns) liveTurns.set(normalizedID(turn.threadID), { host, turn });
    return explainRun(run, { now: now(), hosts, hostsByRef, liveTurns, automationRef });
  };
  let last: AgentRun | undefined;
  const outcome = await waitLoop([agentRunDirectory(corpusRoot)], options, () => {
    const run = cache.load(runId);
    if (!run) return null;
    last = run;
    const state = runWaitConditionState(run, until, until === "needs-you" ? explain(run) : undefined);
    return state === "pending" ? null : state;
  });
  const finished = now();
  const finalRun = last ?? cache.load(runId);
  return {
    schema: ACTIVITY_WAIT_SCHEMA,
    subject: { kind: "run", id: runId },
    until,
    outcome: outcome ?? "timeout",
    matched: outcome === "matched",
    startedAt: started.toISOString(),
    finishedAt: finished.toISOString(),
    elapsedSeconds: Math.round((finished.getTime() - started.getTime()) / 100) / 10,
    ...(finalRun ? { status: finalRun.status, explanation: explain(finalRun) } : {}),
  };
}

export interface ThreadWaitOptions extends WaitOptions {
  afterMessageId?: string;
  since?: Date;
}

export async function waitForThread(corpusRootRaw: string, threadId: string, until: ThreadWaitCondition, options: ThreadWaitOptions = {}): Promise<ActivityWaitResult> {
  const corpusRoot = path.resolve(corpusRootRaw);
  const now = options.now ?? (() => new Date());
  const started = now();
  const runCache = new RunRecordCache(corpusRoot);
  const load = () => hydratedThread(corpusRoot, threadId);
  const initial = load();
  const initialInbox = pendingInboxMessages(corpusRoot, threadId);
  if (!initial && initialInbox.length === 0) throw new Error(`unknown chat thread: ${threadId}`);

  // Baseline for reply waits: an explicit message or time, otherwise the
  // latest prompt already in the thread. Replies after the baseline count even
  // if they landed before this wait started.
  let baseline: { messageId?: string; at: number } = { at: started.getTime() };
  if (options.afterMessageId) {
    const wanted = normalizedID(options.afterMessageId);
    const message = initial?.messages?.find((item) => item.id && normalizedID(String(item.id)) === wanted);
    const inbox = initialInbox.find((item) => normalizedID(item.id) === wanted);
    const at = message ? messageTime(message) : inbox ? Date.parse(inbox.createdAt) : Number.NaN;
    if (!Number.isFinite(at)) {
      // The prompt may still be syncing; treat it as "now" so only later replies count.
      baseline = { messageId: options.afterMessageId, at: started.getTime() };
    } else {
      baseline = { messageId: options.afterMessageId, at };
    }
  } else if (options.since) {
    baseline = { at: options.since.getTime() };
  } else {
    const prompt = [...(initial?.messages ?? [])].reverse().find((item) => item.role === "user");
    const at = messageTime(prompt);
    if (prompt && Number.isFinite(at)) baseline = { messageId: prompt.id ? String(prompt.id) : undefined, at };
  }

  const explain = (thread: OpenClawChatThreadRecord): ActivityExplanation => {
    const hosts = loadActivityHosts(corpusRoot, now());
    const hostsByRef = new Map(hosts.map((host) => [host.hostRef, host]));
    const liveTurns = new Map<string, { host: ActivityHost; turn: ActivityHost["turns"][number] }>();
    for (const host of hosts) for (const turn of host.turns) {
      const key = normalizedID(turn.threadID);
      if (!liveTurns.has(key) || isHostLive(host)) liveTurns.set(key, { host, turn });
    }
    const runsByThread = new Map<string, AgentRun[]>();
    if (until === "needs-you") {
      for (const run of runCache.refresh().runs) {
        const match = run.comments.map((comment) => /AI chat thread:?\s+([0-9A-Fa-f-]{36})/u.exec(comment.body)).find(Boolean);
        if (match && normalizedID(match[1]!) === normalizedID(thread.id)) runsByThread.set(normalizedID(thread.id), [...(runsByThread.get(normalizedID(thread.id)) ?? []), run]);
      }
    }
    const inboxByThread = new Map([[normalizedID(thread.id), pendingInboxMessages(corpusRoot, thread.id)]]);
    return explainThread(thread, { now: now(), hosts, hostsByRef, liveTurns, runsByThread, inboxByThread });
  };

  let reply: ActivityWaitResult["reply"];
  let lastThread = initial;
  let storeFingerprint = "";
  const outcome = await waitLoop(
    [openClawTranscriptStorePath(corpusRoot), liveHostDirectory(corpusRoot), aiChatInboxDirectory(corpusRoot), agentRunDirectory(corpusRoot)],
    options,
    () => {
      const fingerprint = threadStoreFingerprint(corpusRoot);
      if (fingerprint !== storeFingerprint || !lastThread) {
        storeFingerprint = fingerprint;
        lastThread = load() ?? lastThread;
      }
      if (until === "reply") {
        const message = (lastThread?.messages ?? []).find((item) => item.role === "assistant" && messageTime(item) > baseline.at && item.id);
        if (message) {
          reply = { messageId: String(message.id), at: new Date(messageTime(message)).toISOString(), role: "assistant", source: "transcript", ...(typeof message.authorLabel === "string" ? { author: message.authorLabel } : {}) };
          return "matched" as const;
        }
        const inbox = pendingInboxMessages(corpusRoot, threadId).find((item) => !item.isSend && Date.parse(item.createdAt) > baseline.at);
        if (inbox) {
          reply = { messageId: inbox.id, at: inbox.createdAt, role: "assistant", source: "inbox", ...(inbox.authorLabel ? { author: inbox.authorLabel } : {}) };
          return "matched" as const;
        }
        return null;
      }
      if (!lastThread) return null;
      const explanation = explain(lastThread);
      if (until === "needs-you") return explanation.state === "needs-you" ? "matched" as const : null;
      if (until === "working") return explanation.state === "working" ? "matched" as const : null;
      // idle: no turn running and nothing unresolved.
      return explanation.state !== "working" && explanation.state !== "queued" ? "matched" as const : null;
    },
  );
  const finished = now();
  return {
    schema: ACTIVITY_WAIT_SCHEMA,
    subject: { kind: "thread", id: threadId },
    until,
    outcome: outcome ?? "timeout",
    matched: outcome === "matched",
    startedAt: started.toISOString(),
    finishedAt: finished.toISOString(),
    elapsedSeconds: Math.round((finished.getTime() - started.getTime()) / 100) / 10,
    ...(until === "reply" ? { baseline: { ...(baseline.messageId ? { messageId: baseline.messageId } : {}), at: new Date(baseline.at).toISOString() } } : {}),
    ...(reply ? { reply } : {}),
    ...(lastThread ? { explanation: explain(lastThread) } : {}),
  };
}

/** Exit status for a wait result: 0 matched, 2 unreachable, 124 timed out (like timeout(1)). */
export function waitExitCode(result: ActivityWaitResult): number {
  return result.outcome === "matched" ? 0 : result.outcome === "unreachable" ? 2 : 124;
}

export function isActivityEventRecord(value: unknown): value is ActivityEvent {
  return isRecord(value) && schemaMatches(value.schema, ACTIVITY_EVENT_SCHEMA) && typeof value.type === "string";
}
