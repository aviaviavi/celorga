/**
 * Explainable agent activity.
 *
 * Every thread, durable run, and workflow gets a structured explanation of why
 * it is working or needs attention, which host and runtime reported that, how
 * recently, how much the reader should trust it, and the exact approval or
 * question that blocks it. Explanations are derived only from structured
 * records: host presence files, chat transcript metadata, run event logs, and
 * workflow trigger state. Nothing here scrapes terminal output or a screen.
 *
 * The same snapshots feed the local event stream and the race-free waits in
 * `activityEvents.ts`.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  currentAgentRunApprovalBoundary,
  listAgentRuns,
  type AgentRun,
  type AgentRunApproval,
} from "./agentRun.js";
import { listWorkflows, workflowScheduleOccurrence, workflowScheduleTrigger, workflowTriggerEligibility, type AgentWorkflow } from "./agentWorkflow.js";
import { automationHostRef } from "./automationHost.js";
import { aiChatInboxDirectory } from "./aiChatOperationJournal.js";
import {
  findOpenClawThread,
  isOpenClawThreadSettled,
  loadOpenClawThreadState,
  openClawDateMilliseconds,
  openClawTranscriptStorePath,
  type OpenClawChatMessageRecord,
  type OpenClawChatThreadRecord,
  type OpenClawThreadState,
} from "./openClawThreadState.js";
import { schemaMatches, stateDir } from "./brandNames.js";

export const ACTIVITY_EXPLANATION_SCHEMA = "org2:activity-explanation:v1" as const;
export const ACTIVITY_HOSTS_SCHEMA = "org2:activity-hosts:v1" as const;
export const AI_CHAT_LIVE_HOST_SCHEMA = "org2:ai-chat-live-host:v1" as const;

/** Matches the desktop's heartbeat (45 s) and freshness (150 s) intervals. */
export const ACTIVITY_HOST_HEARTBEAT_SECONDS = 45;
export const ACTIVITY_HOST_FRESHNESS_SECONDS = 150;
/** A host silent for longer than this is stale rather than reconnecting. */
export const ACTIVITY_HOST_STALE_SECONDS = 15 * 60;
/** Queued runs without any event for this long may have lost their dispatcher. */
export const ACTIVITY_RUN_SILENCE_SECONDS = 24 * 3600;
/**
 * A running run with no live turn and no run event for this long cannot be
 * confirmed as executing. `celorga activity trace` uses the same window, so
 * the coordinator, attention digest, and trace agree on when "running" stops
 * being believable.
 */
export const ACTIVITY_RUNNING_QUIET_SECONDS = 15 * 60;
/** Activity lists attention items this recent (older open runs are history). */
export const ACTIVITY_ATTENTION_WINDOW_SECONDS = 7 * 24 * 3600;

export type ActivityHostKind = "desktop" | "server" | "harness";
export type ActivityHostState = "online" | "reconnecting" | "authentication-needed" | "stale" | "offline";
export type ActivityConfidence = "live" | "cached" | "uncertain";
export type ActivitySubjectKind = "thread" | "run" | "workflow";
export type ActivityState =
  | "working"
  | "queued"
  | "needs-you"
  | "your-turn"
  | "failed"
  | "scheduled"
  | "due"
  | "paused"
  | "idle"
  | "settled"
  | "done";

export interface ActivityLiveActivity {
  id?: string;
  kind?: string;
  title?: string;
  detail?: string;
  status?: string;
  updatedAt?: string;
}

export interface ActivityLiveTurn {
  threadID: string;
  userMessageID?: string;
  destinationID?: string;
  destinationName?: string;
  startedAt?: string;
  statusText?: string;
  latestActivity?: ActivityLiveActivity;
  /** The most recent activities (oldest first, at most 20) so traces can spot slow or failing tools. */
  recentActivities?: ActivityLiveActivity[];
}

/** One host's presence file in `.org2/openclaw-chat.store/live/`. */
export interface ActivityHost {
  writerID: string;
  hostRef: string;
  hostName: string;
  hostKind: ActivityHostKind;
  state: ActivityHostState;
  /** Why the host is in this state, in one sentence. */
  stateReason: string;
  isOnline: boolean;
  lastSeenAt: string;
  lastSeenAgeSeconds: number;
  /** `live` while the presence record is fresh; otherwise its turns are a cached last-known view. */
  confidence: ActivityConfidence;
  isAutomationHost: boolean;
  /** Finishing running turns before a restart or update; accepts no new turns. */
  draining: boolean;
  enabledDestinationIDs: string[];
  authenticationNeededDestinationIDs: string[];
  turns: ActivityLiveTurn[];
  file: string;
}

export interface ActivityHostRef {
  hostRef?: string;
  hostName?: string;
  hostKind?: ActivityHostKind;
  hostState?: ActivityHostState;
  runtime?: string;
  destinationID?: string;
  destinationName?: string;
  model?: string;
  actor?: string;
}

export interface ActivitySignal {
  type: "heartbeat" | "transition" | "message" | "trigger-attempt" | "record-update";
  at: string;
  ageSeconds: number;
  detail?: string;
}

export interface ActivityBlocker {
  kind: "approval" | "question" | "delivery-failure" | "artifact-review" | "reply";
  summary: string;
  runId?: string;
  approvalId?: string;
  title?: string;
  action?: string;
  riskClass?: string;
  fingerprint?: string;
  requestedFrom?: string;
  requestedAt?: string;
  artifactId?: string;
  path?: string;
  messageId?: string;
  nextActions?: string[];
  /** A command that resolves or inspects the boundary. Decisions still require a person. */
  command?: string;
}

export interface ActivityEvidence {
  source: "presence" | "transcript" | "run-event" | "run" | "workflow" | "dispatch-lock" | "inbox";
  ref: string;
  at?: string;
  detail: string;
}

export interface ActivityExplanation {
  kind: ActivitySubjectKind;
  id: string;
  title: string;
  state: ActivityState;
  /** True when a person must act. */
  needsAttention: boolean;
  reason: { code: string; summary: string };
  reportedBy: ActivityHostRef;
  lastSignal: ActivitySignal | null;
  confidence: ActivityConfidence;
  confidenceReason: string;
  blocking: ActivityBlocker[];
  related: Array<{ kind: ActivitySubjectKind; id: string; relation: string }>;
  evidence: ActivityEvidence[];
}

export interface ActivityExplainOptions {
  now?: Date;
  thread?: string;
  run?: string;
  workflow?: string;
  /** Include idle, settled, and finished subjects in a full listing. */
  all?: boolean;
  /** Runs already listed by the caller (for example the workspace coordinator), to avoid a second corpus scan. */
  runs?: AgentRun[];
}

export interface ActivityExplainResult {
  schema: typeof ACTIVITY_EXPLANATION_SCHEMA;
  generatedAt: string;
  corpus: string;
  automationHostRef: string;
  hosts: ActivityHost[];
  items: ActivityExplanation[];
  summary: { working: number; needsYou: number; queued: number; scheduled: number; uncertain: number };
}

type JSONRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JSONRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function ageSeconds(now: Date, ms: number): number {
  return Math.max(0, Math.round((now.getTime() - ms) / 1000));
}

export function describeAge(seconds: number): string {
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 48 * 3600) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86_400)} d ago`;
}

function signal(type: ActivitySignal["type"], ms: number, now: Date, detail?: string): ActivitySignal | null {
  if (!Number.isFinite(ms)) return null;
  return { type, at: iso(ms), ageSeconds: ageSeconds(now, ms), ...(detail ? { detail } : {}) };
}

function normalizedID(value: string): string {
  return value.trim().toLowerCase();
}

// MARK: - Hosts

export function liveHostDirectory(corpusRoot: string): string {
  return path.join(openClawTranscriptStorePath(corpusRoot), "live");
}

export function classifyHostState(
  record: { isOnline: boolean; updatedAtMs: number; authenticationNeededDestinationIDs: string[] },
  now: Date,
): { state: ActivityHostState; reason: string } {
  const age = ageSeconds(now, record.updatedAtMs);
  if (!record.isOnline) {
    return { state: "offline", reason: `Signed off cleanly ${describeAge(age)}` };
  }
  // A clock far in the future is not evidence that the host is alive.
  if (record.updatedAtMs > now.getTime() + 300_000) {
    return { state: "stale", reason: "Presence timestamp is in the future; clocks disagree" };
  }
  if (age <= ACTIVITY_HOST_FRESHNESS_SECONDS) {
    if (record.authenticationNeededDestinationIDs.length > 0) {
      return {
        state: "authentication-needed",
        reason: `Online, but ${record.authenticationNeededDestinationIDs.length} destination(s) need sign-in`,
      };
    }
    return { state: "online", reason: `Heartbeat ${describeAge(age)}` };
  }
  if (age <= ACTIVITY_HOST_STALE_SECONDS) {
    return { state: "reconnecting", reason: `Missed heartbeats; last seen ${describeAge(age)}` };
  }
  return { state: "stale", reason: `No heartbeat since ${describeAge(age)}; the host may be asleep, stopped, or not syncing` };
}

function hostMatchesAutomationRef(hostRef: string, hostKind: string, automationRef: string): boolean {
  if (automationRef === hostRef) return true;
  return automationRef === "desktop" && hostKind === "desktop";
}

export function loadActivityHosts(corpusRoot: string, now = new Date()): ActivityHost[] {
  const directory = liveHostDirectory(corpusRoot);
  let names: string[] = [];
  try {
    names = fs.readdirSync(directory).filter((name) => name.endsWith(".json") && !name.startsWith(".") && !name.includes(".sync-conflict-"));
  } catch {
    return [];
  }
  const automationRef = automationHostRefSafe(corpusRoot);
  const hosts: ActivityHost[] = [];
  for (const name of names.sort()) {
    const file = path.join(directory, name);
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.size > 4 * 1024 * 1024) continue;
      const raw = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
      if (!isRecord(raw) || !schemaMatches(raw.schema, AI_CHAT_LIVE_HOST_SCHEMA)) continue;
      const hostRef = str(raw.hostRef);
      const writerID = str(raw.writerID);
      const updatedAtMs = Date.parse(String(raw.updatedAt ?? ""));
      if (!hostRef || !writerID || !Number.isFinite(updatedAtMs)) continue;
      const hostKind: ActivityHostKind = raw.hostKind === "server" ? "server" : "desktop";
      const authenticationNeededDestinationIDs = Array.isArray(raw.authenticationNeededDestinationIDs)
        ? raw.authenticationNeededDestinationIDs.filter((item): item is string => typeof item === "string")
        : [];
      const isOnline = raw.isOnline !== false;
      const classified = classifyHostState({ isOnline, updatedAtMs, authenticationNeededDestinationIDs }, now);
      const draining = raw.isDraining === true && (classified.state === "online" || classified.state === "authentication-needed");
      if (draining) classified.reason = `Draining before a restart or update: finishing running turns and accepting no new ones (${classified.reason.toLowerCase()})`;
      const turns: ActivityLiveTurn[] = (Array.isArray(raw.turns) ? raw.turns : []).flatMap((turn) => {
        if (!isRecord(turn) || !str(turn.threadID)) return [];
        const activities = Array.isArray(turn.activities) ? turn.activities.filter(isRecord) : [];
        const latest = activities.at(-1);
        const summarize = (activity: JSONRecord): ActivityLiveActivity => ({
          ...(str(activity.id) ? { id: String(activity.id) } : {}),
          ...(str(activity.kind) ? { kind: String(activity.kind) } : {}),
          ...(str(activity.title) ? { title: String(activity.title).slice(0, 200) } : {}),
          ...(str(activity.detail) ? { detail: String(activity.detail).slice(0, 400) } : {}),
          ...(str(activity.status) ? { status: String(activity.status) } : {}),
          ...(str(activity.updatedAt) ? { updatedAt: String(activity.updatedAt) } : {}),
        });
        return [{
          threadID: String(turn.threadID),
          ...(str(turn.userMessageID) ? { userMessageID: String(turn.userMessageID) } : {}),
          ...(str(turn.destinationID) ? { destinationID: String(turn.destinationID) } : {}),
          ...(str(turn.destinationName) ? { destinationName: String(turn.destinationName) } : {}),
          ...(str(turn.startedAt) ? { startedAt: String(turn.startedAt) } : {}),
          ...(str(turn.statusText) ? { statusText: String(turn.statusText) } : {}),
          ...(latest ? { latestActivity: summarize(latest), recentActivities: activities.slice(-20).map(summarize) } : {}),
        }];
      });
      hosts.push({
        writerID,
        hostRef,
        hostName: str(raw.hostName) ?? hostRef,
        hostKind,
        state: classified.state,
        stateReason: classified.reason,
        isOnline,
        lastSeenAt: iso(updatedAtMs),
        lastSeenAgeSeconds: ageSeconds(now, updatedAtMs),
        confidence: classified.state === "online" || classified.state === "authentication-needed" ? "live" : "cached",
        isAutomationHost: hostMatchesAutomationRef(hostRef, hostKind, automationRef),
        draining,
        enabledDestinationIDs: Array.isArray(raw.enabledDestinationIDs)
          ? raw.enabledDestinationIDs.filter((item): item is string => typeof item === "string").sort()
          : [],
        authenticationNeededDestinationIDs,
        // A host that signed off has no turns; a silent one keeps its last-known turns as cached state.
        turns: isOnline ? turns : [],
        file,
      });
    } catch {
      // Presence is advisory and safe to lose; skip unreadable records.
    }
  }
  return hosts.sort((lhs, rhs) => {
    const rank = (host: ActivityHost) => ["online", "authentication-needed", "reconnecting", "stale", "offline"].indexOf(host.state);
    return rank(lhs) - rank(rhs) || lhs.hostName.localeCompare(rhs.hostName);
  });
}

function automationHostRefSafe(corpusRoot: string): string {
  try {
    return automationHostRef(corpusRoot);
  } catch {
    return "desktop";
  }
}

export function isHostLive(host: ActivityHost | undefined): boolean {
  return host?.state === "online" || host?.state === "authentication-needed";
}

/** Online hosts other than `host` that have `destinationID` enabled and could take over a conversation. */
export function failoverHosts(hosts: ActivityHost[], host: ActivityHost, destinationIDs?: string[]): ActivityHost[] {
  const wanted = destinationIDs?.length ? destinationIDs : host.enabledDestinationIDs;
  return hosts.filter((candidate) => candidate.hostRef !== host.hostRef
    && isHostLive(candidate)
    && !candidate.draining
    && wanted.some((id) => candidate.enabledDestinationIDs.includes(id)));
}

export interface ActivityHostsResult {
  schema: typeof ACTIVITY_HOSTS_SCHEMA;
  generatedAt: string;
  automationHostRef: string;
  hosts: Array<ActivityHost & { failoverHostRefs: string[]; needsYouThreadCount: number }>;
}

export function activityHosts(corpusRoot: string, now = new Date(), threadState?: OpenClawThreadState): ActivityHostsResult {
  const hosts = loadActivityHosts(corpusRoot, now);
  const state = threadState ?? safeThreadState(corpusRoot);
  const needsYouByHost = new Map<string, number>();
  for (const thread of state?.threads ?? []) {
    if (isOpenClawThreadSettled(thread) || thread.storedLatestDeliveryNeedsAttention !== true) continue;
    const hostRef = str(thread.executionHostRef) ?? str((thread as JSONRecord).lastExecutionHostRef);
    if (hostRef) needsYouByHost.set(hostRef, (needsYouByHost.get(hostRef) ?? 0) + 1);
  }
  return {
    schema: ACTIVITY_HOSTS_SCHEMA,
    generatedAt: now.toISOString(),
    automationHostRef: automationHostRefSafe(corpusRoot),
    hosts: hosts.map((host) => ({
      ...host,
      failoverHostRefs: failoverHosts(hosts, host).map((candidate) => candidate.hostRef),
      needsYouThreadCount: needsYouByHost.get(host.hostRef) ?? 0,
    })),
  };
}

function safeThreadState(corpusRoot: string, hydrateThreadID?: string): OpenClawThreadState | null {
  try {
    return loadOpenClawThreadState(corpusRoot, hydrateThreadID ? { hydrateThreadID } : {});
  } catch {
    return null;
  }
}

// MARK: - Threads

interface LiveTurnMatch {
  host: ActivityHost;
  turn: ActivityLiveTurn;
}

function liveTurnsByThread(hosts: ActivityHost[]): Map<string, LiveTurnMatch> {
  const result = new Map<string, LiveTurnMatch>();
  for (const host of hosts) {
    for (const turn of host.turns) {
      const key = normalizedID(turn.threadID);
      const existing = result.get(key);
      // Prefer a live host's report over a cached one.
      if (!existing || (isHostLive(host) && !isHostLive(existing.host))) result.set(key, { host, turn });
    }
  }
  return result;
}

const THREAD_COMMENT_PATTERN = /AI chat thread:?\s+([0-9A-Fa-f-]{36})/u;

/** The AI chat thread a run reports through, from its "AI chat thread <id>" comments. */
export function linkedThreadID(run: AgentRun): string | undefined {
  for (const comment of [...run.comments].reverse()) {
    const match = THREAD_COMMENT_PATTERN.exec(comment.body);
    if (match) return normalizedID(match[1]!);
  }
  return undefined;
}

interface MessageProvenance {
  executionHostRef?: string;
  executionHostName?: string;
  receivedByHostRef?: string;
  receivedByHostName?: string;
  acceptedAt?: number | string;
  originClient?: string;
}

function provenance(message: OpenClawChatMessageRecord | undefined): MessageProvenance {
  const raw = message && isRecord(message.provenance) ? message.provenance : {};
  return {
    ...(str(raw.executionHostRef) ? { executionHostRef: String(raw.executionHostRef) } : {}),
    ...(str(raw.executionHostName) ? { executionHostName: String(raw.executionHostName) } : {}),
    ...(str(raw.receivedByHostRef) ? { receivedByHostRef: String(raw.receivedByHostRef) } : {}),
    ...(str(raw.receivedByHostName) ? { receivedByHostName: String(raw.receivedByHostName) } : {}),
    ...(typeof raw.acceptedAt === "number" || typeof raw.acceptedAt === "string" ? { acceptedAt: raw.acceptedAt } : {}),
    ...(str(raw.originClient) ? { originClient: String(raw.originClient) } : {}),
  };
}

export function messageTime(message: OpenClawChatMessageRecord | undefined): number {
  const raw = message?.createdAt;
  return typeof raw === "number" || typeof raw === "string" ? openClawDateMilliseconds(raw) : Number.NaN;
}

export interface PendingInboxMessage {
  isSend: boolean;
  id: string;
  threadID: string;
  createdAt: string;
  authorLabel?: string;
  source?: string;
  file: string;
}

/** Pending background posts and explicit user sends, kept distinct from replies. */
export function pendingInboxMessages(corpusRoot: string, threadID?: string): PendingInboxMessage[] {
  const directory = aiChatInboxDirectory(corpusRoot);
  let names: string[] = [];
  try {
    names = fs.readdirSync(directory).filter((name) => name.endsWith(".json"));
  } catch {
    return [];
  }
  const wanted = threadID ? normalizedID(threadID) : undefined;
  return names.flatMap((name) => {
    const file = path.join(directory, name);
    try {
      const raw = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
      if (!isRecord(raw) || !str(raw.threadID) || !str(raw.id)) return [];
      if (wanted && normalizedID(String(raw.threadID)) !== wanted) return [];
      return [{
        isSend: schemaMatches(raw.schema, "org2:ai-chat-send-message:v1"),
        id: String(raw.id),
        threadID: String(raw.threadID),
        createdAt: str(raw.createdAt) ?? new Date(fs.statSync(file).mtimeMs).toISOString(),
        ...(str(raw.authorLabel) ? { authorLabel: String(raw.authorLabel) } : {}),
        ...(str(raw.source) ? { source: String(raw.source) } : {}),
        file,
      }];
    } catch {
      return [];
    }
  });
}

interface ThreadContext {
  now: Date;
  hosts: ActivityHost[];
  hostsByRef: Map<string, ActivityHost>;
  liveTurns: Map<string, LiveTurnMatch>;
  runsByThread: Map<string, AgentRun[]>;
  inboxByThread: Map<string, PendingInboxMessage[]>;
}

function runtimeLabel(thread: OpenClawChatThreadRecord): string | undefined {
  return str(thread.runtime) ?? str(thread.roomAudience);
}

export function explainThread(thread: OpenClawChatThreadRecord, context: ThreadContext): ActivityExplanation {
  const { now } = context;
  const id = thread.id;
  const key = normalizedID(id);
  const title = str(thread.title) ?? "Untitled chat";
  const messages = Array.isArray(thread.messages) ? thread.messages : [];
  const latest = messages.at(-1);
  const latestUser = [...messages].reverse().find((message) => message.role === "user");
  const latestAssistant = [...messages].reverse().find((message) => message.role === "assistant");
  const userProvenance = provenance(latestUser);
  const updatedAtMs = openClawDateMilliseconds(thread.updatedAt);
  const evidence: ActivityEvidence[] = [];
  const related: ActivityExplanation["related"] = [];
  const blocking: ActivityBlocker[] = [];
  const live = context.liveTurns.get(key);
  const executionHost = userProvenance.executionHostRef ? context.hostsByRef.get(userProvenance.executionHostRef) : undefined;
  const destinationID = live?.turn.destinationID ?? str(latestUser?.targetDestinationID) ?? str(thread.destinationID);
  const reportedBy: ActivityHostRef = {
    ...(live ? { hostRef: live.host.hostRef, hostName: live.host.hostName, hostKind: live.host.hostKind, hostState: live.host.state }
      : userProvenance.executionHostRef ? {
        hostRef: userProvenance.executionHostRef,
        hostName: executionHost?.hostName ?? userProvenance.executionHostName,
        ...(executionHost ? { hostKind: executionHost.hostKind, hostState: executionHost.state } : {}),
      } : {}),
    ...(runtimeLabel(thread) ? { runtime: runtimeLabel(thread) } : {}),
    ...(destinationID ? { destinationID } : {}),
    ...(live?.turn.destinationName ? { destinationName: live.turn.destinationName } : {}),
    ...(str(thread.model) ? { model: String(thread.model) } : {}),
  };
  evidence.push({
    source: "transcript",
    ref: `thread:${id}`,
    at: Number.isFinite(updatedAtMs) ? iso(updatedAtMs) : undefined,
    detail: `${thread.storedMessageCount ?? messages.length} message(s); latest delivery ${thread.storedHasUnresolvedLatestDelivery ? "unresolved" : "resolved"}${thread.storedLatestDeliveryNeedsAttention ? ", needs attention" : ""}`,
  });

  // Durable work linked to this conversation can block it on a decision.
  for (const run of context.runsByThread.get(key) ?? []) {
    related.push({ kind: "run", id: run.id, relation: "linked-run" });
    if (run.status === "waiting-approval" || run.status === "blocked") {
      blocking.push(...runBlockers(run));
    }
  }

  const result = (
    state: ActivityState,
    code: string,
    summary: string,
    confidence: ActivityConfidence,
    confidenceReason: string,
    lastSignal: ActivitySignal | null,
  ): ActivityExplanation => ({
    kind: "thread",
    id,
    title,
    state,
    needsAttention: state === "needs-you" || state === "your-turn" || state === "failed",
    reason: { code, summary },
    reportedBy,
    lastSignal,
    confidence,
    confidenceReason,
    blocking,
    related,
    evidence,
  });

  const transcriptSignal = signal("message", updatedAtMs, now);

  if (live) {
    const hostAge = live.host.lastSeenAgeSeconds;
    const activity = live.turn.latestActivity?.title ?? live.turn.statusText;
    evidence.push({
      source: "presence",
      ref: live.host.file,
      at: live.host.lastSeenAt,
      detail: `${live.host.hostName} reports a turn${live.turn.startedAt ? ` started ${live.turn.startedAt}` : ""}${activity ? `; latest activity: ${activity}` : ""}`,
    });
    const via = live.turn.destinationName ? ` via ${live.turn.destinationName}` : "";
    if (isHostLive(live.host)) {
      return result(
        "working",
        "turn-running",
        `Turn running on ${live.host.hostName}${via}${activity ? ` — ${activity}` : ""}`,
        "live",
        `${live.host.hostName} refreshed its presence ${describeAge(hostAge)}`,
        signal("heartbeat", Date.parse(live.host.lastSeenAt), now, activity),
      );
    }
    return result(
      "working",
      "turn-unconfirmed",
      `Last reported running on ${live.host.hostName}${via}, but that host is ${live.host.state}`,
      "uncertain",
      `${live.host.hostName} has not refreshed its presence since ${describeAge(hostAge)}; the turn may have finished or stopped`,
      signal("heartbeat", Date.parse(live.host.lastSeenAt), now),
    );
  }

  if (thread.storedLatestDeliveryNeedsAttention === true || latest?.deliveryStatus === "failed") {
    const failure = str(latest?.sendFailure) ?? "The latest message was not delivered";
    blocking.unshift({
      kind: "delivery-failure",
      summary: failure,
      ...(latest?.id ? { messageId: String(latest.id) } : {}),
    });
    return result(
      "needs-you",
      "delivery-failed",
      `Latest message needs attention: ${failure}`,
      "cached",
      "Read from the committed chat transcript",
      transcriptSignal,
    );
  }

  if (blocking.some((blocker) => blocker.kind === "approval" || blocker.kind === "question")) {
    const first = blocking[0]!;
    return result(
      "needs-you",
      first.kind === "approval" ? "waiting-approval" : "blocked-question",
      first.summary,
      "cached",
      "Read from the linked run's event log",
      transcriptSignal,
    );
  }

  const unresolved = thread.storedHasUnresolvedLatestDelivery === true || latest?.deliveryStatus === "sending";
  if (unresolved) {
    const hostName = executionHost?.hostName ?? userProvenance.executionHostName ?? userProvenance.executionHostRef;
    if (executionHost && isHostLive(executionHost) && executionHost.draining) {
      evidence.push({ source: "presence", ref: executionHost.file, at: executionHost.lastSeenAt, detail: `${executionHost.hostName} is draining for a restart` });
      return result(
        "queued",
        "host-restarting",
        `${hostName} is restarting and accepts no new turns; the sending host will run this message instead`,
        "uncertain",
        executionHost.stateReason,
        transcriptSignal,
      );
    }
    if (executionHost && isHostLive(executionHost)) {
      const acceptedMs = userProvenance.acceptedAt !== undefined ? openClawDateMilliseconds(userProvenance.acceptedAt) : Number.NaN;
      const handoffPending = !Number.isFinite(acceptedMs) || Date.parse(executionHost.lastSeenAt) < acceptedMs + 20_000;
      evidence.push({ source: "presence", ref: executionHost.file, at: executionHost.lastSeenAt, detail: `${executionHost.hostName} is ${executionHost.state} and reports no turn for this thread` });
      return result(
        "queued",
        handoffPending ? "handoff-pending" : "turn-not-reported",
        handoffPending
          ? `Message handed to ${hostName}; waiting for it to accept the turn`
          : `Message is unresolved, but ${hostName} is online and not reporting a turn`,
        "uncertain",
        handoffPending
          ? "The executing host has not refreshed presence since the hand-off"
          : "The reply may still be syncing, or the turn was interrupted",
        transcriptSignal,
      );
    }
    if (executionHost) {
      evidence.push({ source: "presence", ref: executionHost.file, at: executionHost.lastSeenAt, detail: `${executionHost.hostName} is ${executionHost.state}` });
      return result(
        "queued",
        "waiting-for-host",
        `Waiting for ${hostName}, which is ${executionHost.state} (last seen ${describeAge(executionHost.lastSeenAgeSeconds)})`,
        "uncertain",
        executionHost.stateReason,
        transcriptSignal,
      );
    }
    return result(
      "queued",
      "delivery-unresolved",
      hostName ? `Latest message is unresolved on ${hostName}` : "Latest message has not been answered yet",
      "uncertain",
      hostName ? `No presence record from ${hostName} is available` : "No host has reported this turn",
      transcriptSignal,
    );
  }

  const pendingInbox = context.inboxByThread.get(key) ?? [];
  const sends = pendingInbox.filter((message) => message.isSend);
  if (sends.length > 0) {
    const newest = sends.reduce((lhs, rhs) => Date.parse(lhs.createdAt) >= Date.parse(rhs.createdAt) ? lhs : rhs);
    evidence.push({ source: "inbox", ref: newest.file, at: newest.createdAt, detail: `${sends.length} single-agent send request(s) awaiting Celorga consumption; runtime start unconfirmed` });
    return result("queued", "send-request-queued", "Single-agent send awaits Celorga consumption", "cached", "Read from the AI chat inbox; runtime start unconfirmed", signal("message", Date.parse(newest.createdAt), now));
  }
  const inbox = pendingInbox.filter((message) => !message.isSend);
  if (inbox.length > 0) {
    const newest = inbox.reduce((lhs, rhs) => (Date.parse(lhs.createdAt) >= Date.parse(rhs.createdAt) ? lhs : rhs));
    evidence.push({ source: "inbox", ref: newest.file, at: newest.createdAt, detail: `${inbox.length} background message(s) waiting to be imported${newest.authorLabel ? ` from ${newest.authorLabel}` : ""}` });
    blocking.push({ kind: "reply", summary: `${newest.authorLabel ?? "A background worker"} posted a reply`, messageId: newest.id });
    return result("your-turn", "background-reply", `${newest.authorLabel ?? "A background worker"} reported into this chat`, "cached", "Read from the AI chat inbox", signal("message", Date.parse(newest.createdAt), now));
  }

  // A stopped turn is not idle: its reply, if any, is partial.
  if (latest?.deliveryStatus === "interrupted") {
    if (latest.id) blocking.push({ kind: "reply", summary: "The latest turn was stopped before it finished", messageId: String(latest.id) });
    return result("your-turn", "turn-interrupted", "The latest turn was stopped before it finished; any partial reply is incomplete", "cached", "Read from the committed chat transcript", transcriptSignal);
  }

  if (isOpenClawThreadSettled(thread)) {
    return result("settled", "settled", "Conversation is settled", "cached", "Read from the committed chat transcript", transcriptSignal);
  }

  const unread = typeof thread.unreadMessageCount === "number" ? thread.unreadMessageCount : 0;
  const lastIsAssistant = latest ? latest.role === "assistant" : Boolean(thread.storedLatestAssistantMessageID);
  if (unread > 0 && lastIsAssistant) {
    if (latestAssistant?.id) blocking.push({ kind: "reply", summary: "Unread reply", messageId: String(latestAssistant.id) });
    return result("your-turn", "reply-received", `Agent replied; ${unread} unread message(s)`, "cached", "Read from the committed chat transcript", transcriptSignal);
  }
  return result("idle", "idle", "No turn in progress", "cached", "Read from the committed chat transcript", transcriptSignal);
}

// MARK: - Runs

function approvalBlocker(run: AgentRun, approval: AgentRunApproval): ActivityBlocker {
  return {
    kind: "approval",
    summary: `Approve: ${approval.title}`,
    runId: run.id,
    approvalId: approval.id,
    title: approval.title,
    action: approval.action,
    riskClass: approval.riskClass,
    fingerprint: approval.fingerprint,
    ...(approval.requestedFrom ? { requestedFrom: approval.requestedFrom } : {}),
    requestedAt: approval.requestedAt,
    command: `celorga run approval-decide ${run.id} ${approval.id} --decision approved --fingerprint ${approval.fingerprint} --actor NAME`,
  };
}

function runBlockers(run: AgentRun): ActivityBlocker[] {
  const pending = currentAgentRunApprovalBoundary(run).filter((approval) => approval.status === "pending");
  const allPending = pending.length ? pending : run.approvals.filter((approval) => approval.status === "pending");
  const blockers = allPending.map((approval) => approvalBlocker(run, approval));
  if (run.status === "blocked" && run.blockedReason && blockers.length === 0) {
    blockers.push({
      kind: "question",
      summary: run.blockedReason,
      runId: run.id,
      ...(run.outcome?.nextActions.length ? { nextActions: run.outcome.nextActions } : {}),
      command: `celorga run resume ${run.id} --actor NAME`,
    });
  }
  return blockers;
}

function latestRunTransition(run: AgentRun): AgentRun["events"][number] | undefined {
  return [...run.events].reverse().find((event) => event.type === "status-changed" || event.type === "created");
}

function latestRunEvent(run: AgentRun): AgentRun["events"][number] | undefined {
  return run.events.at(-1);
}

interface RunContext {
  now: Date;
  hostsByRef: Map<string, ActivityHost>;
  hosts: ActivityHost[];
  liveTurns: Map<string, LiveTurnMatch>;
  automationRef: string;
}

function automationHost(hosts: ActivityHost[], automationRef: string): ActivityHost | undefined {
  const matches = hosts.filter((host) => hostMatchesAutomationRef(host.hostRef, host.hostKind, automationRef));
  return matches.find(isHostLive) ?? matches[0];
}

export function explainRun(run: AgentRun, context: RunContext): ActivityExplanation {
  const { now } = context;
  const updatedMs = Date.parse(run.updatedAt);
  const transition = latestRunTransition(run);
  const lastEvent = latestRunEvent(run);
  const threadID = linkedThreadID(run);
  const live = threadID ? context.liveTurns.get(threadID) : undefined;
  const hostRefFromEvent = [...run.events].reverse().map((event) => str(event.data?.hostRef)).find(Boolean);
  const eventHost = hostRefFromEvent ? context.hostsByRef.get(hostRefFromEvent) : undefined;
  const workflowHost = run.workflowId ? automationHost(context.hosts, context.automationRef) : undefined;
  const host = live?.host ?? eventHost ?? (run.status === "queued" ? workflowHost : undefined);
  const reportedBy: ActivityHostRef = {
    ...(host ? { hostRef: host.hostRef, hostName: host.hostName, hostKind: host.hostKind, hostState: host.state }
      : hostRefFromEvent ? { hostRef: hostRefFromEvent } : {}),
    ...(run.provider ? { runtime: run.provider } : {}),
    ...(run.destinationRef ? { destinationID: run.destinationRef } : {}),
    ...(live?.turn.destinationName ? { destinationName: live.turn.destinationName } : {}),
    ...(run.model ? { model: run.model } : {}),
    ...(lastEvent?.actor ? { actor: lastEvent.actor } : {}),
  };
  const evidence: ActivityEvidence[] = [];
  if (transition) {
    evidence.push({
      source: "run-event",
      ref: `run:${run.id}#${transition.id}`,
      at: transition.at,
      detail: transition.type === "created"
        ? `Created${transition.actor ? ` by ${transition.actor}` : ""}`
        : `${String(transition.data?.from ?? "?")} → ${String(transition.data?.to ?? run.status)}${transition.actor ? ` by ${transition.actor}` : ""}${transition.detail ? `: ${transition.detail}` : ""}`,
    });
  }
  if (lastEvent && lastEvent !== transition) {
    evidence.push({ source: "run-event", ref: `run:${run.id}#${lastEvent.id}`, at: lastEvent.at, detail: `${lastEvent.type}${lastEvent.actor ? ` by ${lastEvent.actor}` : ""}${lastEvent.detail ? `: ${lastEvent.detail.slice(0, 200)}` : ""}` });
  }
  const related: ActivityExplanation["related"] = [];
  if (threadID) related.push({ kind: "thread", id: threadID, relation: "linked-thread" });
  if (run.workflowId) related.push({ kind: "workflow", id: run.workflowId, relation: "workflow" });
  if (run.parentRunId) related.push({ kind: "run", id: run.parentRunId, relation: "parent-run" });
  const lastSignal = live && isHostLive(live.host)
    ? signal("heartbeat", Date.parse(live.host.lastSeenAt), now, live.turn.latestActivity?.title)
    : signal("transition", Date.parse(lastEvent?.at ?? run.updatedAt), now, lastEvent?.type);
  const silence = Number.isFinite(updatedMs) ? ageSeconds(now, updatedMs) : 0;
  const blocking = runBlockers(run);
  const title = run.title?.trim() || run.goal;
  const base = { kind: "run" as const, id: run.id, title, reportedBy, lastSignal, related, evidence };
  const make = (
    state: ActivityState,
    code: string,
    summary: string,
    confidence: ActivityConfidence,
    confidenceReason: string,
    blockers: ActivityBlocker[] = blocking,
  ): ActivityExplanation => ({
    ...base,
    state,
    needsAttention: state === "needs-you" || state === "failed",
    reason: { code, summary },
    confidence,
    confidenceReason,
    blocking: blockers,
  });

  switch (run.status) {
    case "waiting-approval": {
      const count = blocking.filter((item) => item.kind === "approval").length;
      return make(
        "needs-you",
        "waiting-approval",
        count === 1 ? `Waiting for your decision: ${blocking[0]!.title}` : `Waiting for ${count} decision(s)`,
        "cached",
        "Pending approvals are recorded in the run's event log",
      );
    }
    case "blocked": {
      const summary = blocking[0]?.kind === "approval"
        ? `Blocked on approval: ${blocking[0].title}`
        : `Blocked: ${run.blockedReason ?? "no reason recorded"}`;
      return make("needs-you", blocking[0]?.kind === "approval" ? "blocked-approval" : "blocked-question", summary, "cached", "Recorded by the run's latest transition");
    }
    case "failed":
      return make("failed", "failed", `Failed: ${run.failure ?? "no failure recorded"}`, "cached", "Recorded by the run's latest transition", []);
    case "canceled":
      return make("done", "canceled", "Canceled", "cached", "Recorded by the run's latest transition", []);
    case "completed": {
      const reviews = run.artifacts.filter((artifact) => artifact.reviewStatus === "review-required");
      if (reviews.length > 0) {
        return make(
          "needs-you",
          "artifact-review",
          `${reviews.length} artifact(s) need review`,
          "cached",
          "Artifact review state is recorded in the run",
          reviews.map((artifact) => ({
            kind: "artifact-review",
            summary: `Review ${artifact.title ?? artifact.path}`,
            runId: run.id,
            artifactId: artifact.id,
            path: artifact.path,
            command: `celorga run artifact-review ${run.id} ${artifact.id} --status reviewed --actor NAME`,
          })),
        );
      }
      return make("done", "completed", run.outcome?.summary ? `Completed: ${run.outcome.summary}` : "Completed", "cached", "Recorded by the run's latest transition", []);
    }
    case "queued": {
      if (run.workflowId) {
        const hostText = workflowHost
          ? `${workflowHost.hostName} (${workflowHost.state})`
          : `automation host ${context.automationRef} (no presence record)`;
        return make(
          "queued",
          "queued-for-automation-host",
          `Queued for ${hostText}`,
          workflowHost && isHostLive(workflowHost) ? "live" : "uncertain",
          workflowHost ? workflowHost.stateReason : "No presence record from the automation host",
          [],
        );
      }
      return make("queued", "queued", "Queued; waiting for an executor to start it", silence > ACTIVITY_RUN_SILENCE_SECONDS ? "uncertain" : "cached", silence > ACTIVITY_RUN_SILENCE_SECONDS ? `Queued without an event for ${describeAge(silence)}` : "Recorded by the run's latest transition", []);
    }
    case "running":
    default: {
      if (live && isHostLive(live.host)) {
        return make("working", "turn-running", `Running on ${live.host.hostName}${live.turn.latestActivity?.title ? ` — ${live.turn.latestActivity.title}` : ""}`, "live", `${live.host.hostName} refreshed its presence ${describeAge(live.host.lastSeenAgeSeconds)}`, []);
      }
      if (live) {
        return make("working", "turn-unconfirmed", `Last reported running on ${live.host.hostName}, which is ${live.host.state}`, "uncertain", live.host.stateReason, []);
      }
      // No host reports a turn for this run. Its status is only a claim; once
      // the run has also been quiet for the trace's window, nothing confirms
      // that an executor is still working on it.
      const lastEventMs = Date.parse(lastEvent?.at ?? run.updatedAt);
      const quiet = Number.isFinite(lastEventMs) ? ageSeconds(now, lastEventMs) : silence;
      if (quiet > ACTIVITY_RUNNING_QUIET_SECONDS) {
        return make(
          "working",
          "silent",
          `Marked running, but no host reports ${threadID ? "a turn for its conversation" : "a turn for it"} and the last run event was ${describeAge(quiet)}`,
          "uncertain",
          threadID
            ? "The executor may have stopped without recording a transition"
            : "This run is not linked to a conversation, so no host presence can confirm its executor; it may have stopped without recording a transition",
          [],
        );
      }
      return make("working", "running", run.workflowId ? `Automation ${run.workflowId} running` : "Run in progress", "cached", "Recorded by the run's latest transition; no live presence links this run to a turn", []);
    }
  }
}

// MARK: - Workflows

interface DispatchLock {
  file: string;
  pid?: number;
  hostname?: string;
  createdAt: string;
  ageSeconds: number;
}

function readDispatchLock(corpusRoot: string, workflowID: string, now: Date): DispatchLock | undefined {
  const file = stateDir(corpusRoot, "workflow-dispatch-locks", `${workflowID}.lock`);
  try {
    const stat = fs.statSync(file);
    let raw: JSONRecord = {};
    try { raw = JSON.parse(fs.readFileSync(file, "utf8")) as JSONRecord; } catch { /* empty while being written */ }
    return {
      file,
      ...(typeof raw.pid === "number" ? { pid: raw.pid } : {}),
      ...(str(raw.hostname) ? { hostname: String(raw.hostname) } : {}),
      createdAt: iso(stat.mtimeMs),
      ageSeconds: ageSeconds(now, stat.mtimeMs),
    };
  } catch {
    return undefined;
  }
}

export function explainWorkflow(
  corpusRoot: string,
  workflow: AgentWorkflow,
  runs: AgentRun[],
  context: RunContext,
): ActivityExplanation {
  const { now } = context;
  const trigger = workflowScheduleTrigger(workflow);
  const workflowRuns = runs.filter((run) => run.workflowId === workflow.id)
    .sort((lhs, rhs) => Date.parse(rhs.createdAt) - Date.parse(lhs.createdAt));
  const latestRun = workflowRuns[0];
  const host = automationHost(context.hosts, context.automationRef);
  const reportedBy: ActivityHostRef = {
    hostRef: host?.hostRef ?? context.automationRef,
    ...(host ? { hostName: host.hostName, hostKind: host.hostKind, hostState: host.state } : {}),
    ...(workflow.destinationRef ? { destinationID: workflow.destinationRef } : {}),
    ...(workflow.model ? { model: workflow.model } : {}),
  };
  const evidence: ActivityEvidence[] = [{
    source: "workflow",
    ref: `workflow:${workflow.id}`,
    at: workflow.updatedAt,
    detail: `${workflow.state}; ${trigger ? `${trigger.enabled ? "enabled" : "disabled"} ${trigger.type} trigger${trigger.schedule ? ` "${trigger.schedule}"` : ""}` : "no schedule trigger"}`,
  }];
  const related: ActivityExplanation["related"] = latestRun ? [{ kind: "run", id: latestRun.id, relation: "latest-run" }] : [];
  const lastAttemptMs = Date.parse(trigger?.lastAttemptAt ?? trigger?.lastRunAt ?? "");
  const lastSignal = signal("trigger-attempt", lastAttemptMs, now, latestRun ? `run ${latestRun.id} ${latestRun.status}` : undefined)
    ?? signal("record-update", Date.parse(workflow.updatedAt), now);
  const hostConfidence: ActivityConfidence = host && isHostLive(host) ? "live" : "uncertain";
  const hostReason = host ? `${host.hostName}: ${host.stateReason}` : `No presence record from automation host ${context.automationRef}`;
  const make = (
    state: ActivityState,
    code: string,
    summary: string,
    confidence: ActivityConfidence,
    confidenceReason: string,
    blocking: ActivityBlocker[] = [],
  ): ActivityExplanation => ({
    kind: "workflow",
    id: workflow.id,
    title: workflow.title,
    state,
    needsAttention: state === "needs-you" || state === "failed",
    reason: { code, summary },
    reportedBy,
    lastSignal,
    confidence,
    confidenceReason,
    blocking,
    related,
    evidence,
  });

  if (workflow.state !== "active") {
    return make("paused", `workflow-${workflow.state}`, `Workflow is ${workflow.state}`, "cached", "Read from the workflow record");
  }
  if (latestRun && (latestRun.status === "waiting-approval" || latestRun.status === "blocked")) {
    const blockers = runBlockers(latestRun);
    return make("needs-you", "latest-run-blocked", `Latest run ${latestRun.status === "blocked" ? "is blocked" : "is waiting for approval"}: ${blockers[0]?.summary ?? latestRun.blockedReason ?? ""}`.trim(), "cached", "Read from the latest run's event log", blockers);
  }
  if (latestRun && (latestRun.status === "running" || latestRun.status === "queued")) {
    const runExplanation = explainRun(latestRun, context);
    return make(latestRun.status === "running" ? "working" : "queued", `latest-run-${latestRun.status}`, runExplanation.reason.summary, runExplanation.confidence, runExplanation.confidenceReason);
  }
  const lock = readDispatchLock(corpusRoot, workflow.id, now);
  if (lock) {
    evidence.push({ source: "dispatch-lock", ref: lock.file, at: lock.createdAt, detail: `Held${lock.hostname ? ` by ${lock.hostname}` : ""}${lock.pid ? ` (pid ${lock.pid})` : ""}` });
    if (lock.ageSeconds > 600) {
      return make("needs-you", "dispatch-lock-orphaned", `Dispatch lock held for ${describeAge(lock.ageSeconds).replace(/ ago$/u, "")}; new runs cannot start until it is cleared`, "uncertain", "A person must confirm the executor stopped before removing the lock", [{
        kind: "question",
        summary: `Confirm that ${lock.hostname ?? "the dispatching host"} stopped, then remove ${path.relative(corpusRoot, lock.file)}`,
        path: lock.file,
      }]);
    }
    return make("working", "dispatching", `Dispatching${lock.hostname ? ` on ${lock.hostname}` : ""}`, "live", "A dispatch lock was taken moments ago");
  }
  if (!trigger || !trigger.enabled) {
    return make("idle", "manual", trigger ? "Schedule trigger is disabled" : "Runs only when started manually", "cached", "Read from the workflow record");
  }
  let due = false;
  try { due = workflowScheduleOccurrence(workflow, trigger, now.toISOString()) !== null; } catch { due = false; }
  const eligibility = (() => { try { return workflowTriggerEligibility(workflow, trigger.id); } catch { return { eligible: true, reason: "", signalIds: [] }; } })();
  if (due && !eligibility.eligible) {
    return make("scheduled", "gated", `Schedule is due, but ${eligibility.reason}`, "cached", "Event gates are evaluated from recorded workflow signals");
  }
  if (due) {
    const hostText = host ? `${host.hostName} (${host.state})` : `automation host ${context.automationRef}`;
    return make(
      "due",
      host && isHostLive(host) ? "due" : "due-host-unavailable",
      host && isHostLive(host)
        ? `Due now; ${hostText} will dispatch it on its next check`
        : `Due now, but ${hostText} is not online to dispatch it`,
      hostConfidence,
      hostReason,
    );
  }
  const latestText = latestRun ? `; last run ${latestRun.status}${latestRun.status === "failed" && latestRun.failure ? ` (${latestRun.failure})` : ""}` : "";
  return make(
    latestRun?.status === "failed" ? "failed" : "scheduled",
    latestRun?.status === "failed" ? "latest-run-failed" : "scheduled",
    `Scheduled "${trigger.schedule}" on ${host?.hostName ?? context.automationRef}${latestText}`,
    hostConfidence,
    hostReason,
  );
}

// MARK: - Assembly

function isRecent(now: Date, at: string | undefined, windowSeconds: number): boolean {
  const ms = Date.parse(at ?? "");
  return !Number.isFinite(ms) || now.getTime() - ms <= windowSeconds * 1000;
}

function buildContexts(corpusRoot: string, now: Date, runs: AgentRun[], hosts: ActivityHost[]) {
  const hostsByRef = new Map<string, ActivityHost>();
  for (const host of hosts) {
    const existing = hostsByRef.get(host.hostRef);
    if (!existing || Date.parse(host.lastSeenAt) > Date.parse(existing.lastSeenAt)) hostsByRef.set(host.hostRef, host);
  }
  const liveTurns = liveTurnsByThread(hosts);
  const runsByThread = new Map<string, AgentRun[]>();
  for (const run of runs) {
    const threadID = linkedThreadID(run);
    if (!threadID) continue;
    runsByThread.set(threadID, [...(runsByThread.get(threadID) ?? []), run]);
  }
  const inboxByThread = new Map<string, PendingInboxMessage[]>();
  for (const message of pendingInboxMessages(corpusRoot)) {
    const key = normalizedID(message.threadID);
    inboxByThread.set(key, [...(inboxByThread.get(key) ?? []), message]);
  }
  const automationRef = automationHostRefSafe(corpusRoot);
  return {
    thread: { now, hosts, hostsByRef, liveTurns, runsByThread, inboxByThread } satisfies ThreadContext,
    run: { now, hosts, hostsByRef, liveTurns, automationRef } satisfies RunContext,
  };
}

function safeRuns(corpusRoot: string): AgentRun[] {
  try {
    return listAgentRuns(corpusRoot);
  } catch {
    return [];
  }
}

function safeWorkflows(corpusRoot: string): AgentWorkflow[] {
  try {
    return listWorkflows(corpusRoot);
  } catch {
    return [];
  }
}

export function explainActivity(corpusRootRaw: string, options: ActivityExplainOptions = {}): ActivityExplainResult {
  const corpusRoot = path.resolve(corpusRootRaw);
  const now = options.now ?? new Date();
  const hosts = loadActivityHosts(corpusRoot, now);
  const targeted = Boolean(options.thread || options.run || options.workflow);
  const runs = options.runs ?? safeRuns(corpusRoot);
  const contexts = buildContexts(corpusRoot, now, runs, hosts);
  const items: ActivityExplanation[] = [];

  if (options.run) {
    const wanted = options.run;
    const run = runs.find((candidate) => candidate.id === wanted);
    if (!run) throw new Error(`unknown run: ${wanted}`);
    items.push(explainRun(run, contexts.run));
  }
  if (options.workflow) {
    const workflow = safeWorkflows(corpusRoot).find((candidate) => candidate.id === options.workflow);
    if (!workflow) throw new Error(`unknown workflow: ${options.workflow}`);
    items.push(explainWorkflow(corpusRoot, workflow, runs, contexts.run));
  }
  if (options.thread) {
    const state = loadOpenClawThreadState(corpusRoot, { hydrateThreadID: options.thread });
    const thread = findOpenClawThread(state, options.thread);
    if (!thread) throw new Error(`unknown chat thread: ${options.thread}`);
    items.push(explainThread(thread, contexts.thread));
  }

  if (!targeted) {
    const state = safeThreadState(corpusRoot);
    for (const thread of state?.threads ?? []) {
      if (thread.isArchived === true) continue;
      const key = normalizedID(thread.id);
      const interesting = contexts.thread.liveTurns.has(key)
        || thread.storedHasUnresolvedLatestDelivery === true
        || thread.storedLatestDeliveryNeedsAttention === true
        || contexts.thread.inboxByThread.has(key)
        || contexts.thread.runsByThread.get(key)?.some((run) => run.status === "waiting-approval" || run.status === "blocked");
      if (!interesting && !options.all) continue;
      // Unresolved deliveries need message provenance to name the executing host.
      const hydrated = thread.storedHasUnresolvedLatestDelivery === true && !(thread.messages?.length)
        ? findOpenClawThread(safeThreadState(corpusRoot, thread.id) ?? state!, thread.id) ?? thread
        : thread;
      const explanation = explainThread(hydrated, contexts.thread);
      if (!options.all && explanation.state === "queued" && !isRecent(now, explanation.lastSignal?.at, ACTIVITY_ATTENTION_WINDOW_SECONDS)) continue;
      items.push(explanation);
    }
    for (const run of runs) {
      const open = !["completed", "canceled"].includes(run.status)
        || run.artifacts.some((artifact) => artifact.reviewStatus === "review-required");
      if (!options.all && (!open || (run.status === "failed" && !isRecent(now, run.updatedAt, 3 * 24 * 3600)))) continue;
      const explanation = explainRun(run, contexts.run);
      if (!options.all && explanation.state === "done") continue;
      if (!options.all && explanation.confidence !== "live" && !isRecent(now, run.updatedAt, ACTIVITY_ATTENTION_WINDOW_SECONDS)) continue;
      items.push(explanation);
    }
    for (const workflow of safeWorkflows(corpusRoot)) {
      const explanation = explainWorkflow(corpusRoot, workflow, runs, contexts.run);
      if (!options.all && (explanation.state === "paused" || explanation.state === "idle")) continue;
      items.push(explanation);
    }
  }

  const rank = (item: ActivityExplanation) => (item.needsAttention ? 0 : item.state === "working" ? 1 : item.state === "queued" || item.state === "due" ? 2 : 3);
  items.sort((lhs, rhs) => rank(lhs) - rank(rhs)
    || Date.parse(rhs.lastSignal?.at ?? "") - Date.parse(lhs.lastSignal?.at ?? "")
    || lhs.title.localeCompare(rhs.title));

  return {
    schema: ACTIVITY_EXPLANATION_SCHEMA,
    generatedAt: now.toISOString(),
    corpus: corpusRoot,
    automationHostRef: contexts.run.automationRef,
    hosts,
    items,
    summary: {
      working: items.filter((item) => item.state === "working").length,
      needsYou: items.filter((item) => item.needsAttention).length,
      queued: items.filter((item) => item.state === "queued" || item.state === "due").length,
      scheduled: items.filter((item) => item.state === "scheduled").length,
      uncertain: items.filter((item) => item.confidence === "uncertain").length,
    },
  };
}

function oneLine(text: string, limit = 220): string {
  const compact = text.replace(/\s+/gu, " ").trim();
  return compact.length > limit ? `${compact.slice(0, limit - 1)}…` : compact;
}

export function renderActivityExplanationText(result: ActivityExplainResult): string {
  const lines: string[] = [];
  if (result.hosts.length) {
    lines.push("Hosts");
    for (const host of result.hosts) {
      lines.push(`  ${host.hostName} [${host.hostKind}] ${host.state}${host.draining ? " (draining)" : ""} — ${host.stateReason}${host.turns.length ? `; ${host.turns.length} turn(s)${host.confidence === "cached" ? " (cached)" : ""}` : ""}${host.isAutomationHost ? "; automation host" : ""}`);
    }
    lines.push("");
  }
  if (!result.items.length) {
    lines.push("Nothing is working or waiting on you.");
    return lines.join("\n");
  }
  for (const item of result.items) {
    lines.push(`${item.kind} ${item.id}  ${item.title}`);
    lines.push(`  state: ${item.state}${item.needsAttention ? " (needs you)" : ""} — ${oneLine(item.reason.summary)}`);
    const who = [item.reportedBy.hostName ?? item.reportedBy.hostRef, item.reportedBy.runtime, item.reportedBy.destinationName ?? item.reportedBy.destinationID].filter(Boolean).join(" / ");
    if (who) lines.push(`  reported by: ${who}${item.reportedBy.hostState ? ` (${item.reportedBy.hostState})` : ""}`);
    if (item.lastSignal) lines.push(`  last ${item.lastSignal.type}: ${item.lastSignal.at} (${describeAge(item.lastSignal.ageSeconds)})`);
    lines.push(`  confidence: ${item.confidence} — ${item.confidenceReason}`);
    for (const blocker of item.blocking) {
      lines.push(`  blocking ${blocker.kind}: ${oneLine(blocker.summary)}${blocker.approvalId ? ` [${blocker.runId}:${blocker.approvalId}]` : ""}`);
      if (blocker.command) lines.push(`    ${blocker.command}`);
    }
  }
  return lines.join("\n");
}

/** A stable digest of the parts of an explanation that matter for change detection. */
export function explanationSignature(item: ActivityExplanation): string {
  return crypto.createHash("sha256").update(JSON.stringify([
    item.state,
    item.reason.code,
    item.confidence,
    item.blocking.map((blocker) => [blocker.kind, blocker.approvalId ?? blocker.messageId ?? blocker.summary]),
  ])).digest("hex").slice(0, 16);
}
