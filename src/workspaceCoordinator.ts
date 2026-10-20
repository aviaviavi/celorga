// Workspace coordinator: one read model that answers "what needs me, what is
// stuck, what shipped, and what can continue" across explicitly named corpora
// and every host that publishes presence into them.
//
// The coordinator composes existing durable state; it never invents execution
// state. Explanations come from `explainActivity`, hosts from presence records,
// shipped work from completed run records, and continuation from native
// commands (`thread send`, `run retry`). A continuation offer is re-derived and
// re-guarded at execution time, so a stale offer cannot act on changed state.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  explainActivity,
  isHostLive,
  pendingInboxMessages,
  type ActivityBlocker,
  type ActivityConfidence,
  type ActivityEvidence,
  type ActivityExplanation,
  type ActivityHost,
  type ActivityHostRef,
  type ActivitySignal,
  type ActivityState,
} from "./activityState.js";
import {
  listAgentRuns,
  loadAgentRunSnapshot,
  saveAgentRun,
  transitionAgentRun,
  addAgentRunComment,
  type AgentRun,
  type AgentRunSnapshot,
} from "./agentRun.js";
import { corpusIdentityStatus } from "./corpusIdentity.js";
import { queueAIChatInboxMessage } from "./aiChatInbox.js";
import {
  findOpenClawThread,
  loadOpenClawThreadState,
  type OpenClawChatThreadRecord,
  type OpenClawThreadState,
} from "./openClawThreadState.js";

export const WORKSPACE_COORDINATION_SCHEMA = "org2:workspace-coordination:v1" as const;
export const WORKSPACE_CONTINUATION_SCHEMA = "org2:workspace-continuation:v1" as const;
export const WORKSPACE_COORDINATOR_DEFAULT_SHIPPED_SECONDS = 24 * 3600;
/** A running run must be this quiet before the coordinator offers to nudge it. */
export const WORKSPACE_COORDINATOR_DEFAULT_QUIET_SECONDS = 15 * 60;

export interface CoordinatorCorpus {
  id: string;
  name: string;
  root: string;
  /** False when a lone `--dir` corpus has no portable identity; its id is then path-derived. */
  identityValid: boolean;
}

export interface CoordinatorIssue {
  root: string;
  message: string;
}

export interface CoordinatorEvidence {
  kind: "run-file" | "source-task" | "thread" | "artifact" | "validation" | "outcome" | "presence" | "run-event" | "transcript" | "inbox" | "workflow" | "dispatch-lock";
  ref: string;
  detail: string;
  path?: string;
  line?: number;
  at?: string;
}

export interface CoordinatorItem {
  corpus: { id: string; root: string };
  kind: ActivityExplanation["kind"];
  id: string;
  title: string;
  state: ActivityState;
  reasonCode: string;
  summary: string;
  confidence: ActivityConfidence;
  confidenceReason: string;
  reportedBy: ActivityHostRef;
  lastSignal: ActivitySignal | null;
  blocking: ActivityBlocker[];
  related: ActivityExplanation["related"];
  evidence: CoordinatorEvidence[];
}

export interface CoordinatorShippedItem {
  corpus: { id: string; root: string };
  runId: string;
  title: string;
  completedAt: string;
  summary: string;
  highlights: string[];
  nextActions: string[];
  /** True while any artifact still awaits review; the run is complete, not accepted. */
  reviewPending: boolean;
  validations: { passed: number; failed: number; warning: number; skipped: number };
  assignee?: string;
  evidence: CoordinatorEvidence[];
}

export interface CoordinatorHost {
  corpus: { id: string; root: string };
  hostRef: string;
  hostName: string;
  hostKind: ActivityHost["hostKind"];
  state: ActivityHost["state"];
  stateReason: string;
  confidence: ActivityConfidence;
  draining: boolean;
  isAutomationHost: boolean;
  lastSeenAt: string;
  enabledDestinationIDs: string[];
  activeTurns: Array<{ threadID: string; destinationName?: string; startedAt?: string; latestActivity?: string }>;
  file: string;
}

export interface CoordinatorGuard {
  check: string;
  passed: boolean;
  detail: string;
}

export interface CoordinatorRoute {
  destinationID: string;
  hostRef: string;
  hostName: string;
  /** `last-executor` keeps the conversation on the host whose runtime last ran it. */
  basis: "last-executor" | "failover";
}

export type CoordinatorOfferKind = "thread-send" | "run-retry";

export interface CoordinatorOffer {
  id: string;
  kind: CoordinatorOfferKind;
  allowed: boolean;
  corpus: { id: string; root: string };
  runId: string;
  runTitle: string;
  runStatus: AgentRun["status"];
  runRevision: string;
  threadId?: string;
  route?: CoordinatorRoute;
  idempotencyKey?: string;
  message?: string;
  guards: CoordinatorGuard[];
  /** What executing the offer does and, as importantly, what it does not confirm. */
  effect: string;
  /** The native command the offer delegates to; `workspace continue` runs it with re-checked guards. */
  command: string;
  continueCommand: string;
}

export interface WorkspaceCoordination {
  schema: typeof WORKSPACE_COORDINATION_SCHEMA;
  generatedAt: string;
  shippedSince: string;
  corpora: CoordinatorCorpus[];
  issues: CoordinatorIssue[];
  hosts: CoordinatorHost[];
  needsYou: CoordinatorItem[];
  stuck: CoordinatorItem[];
  working: CoordinatorItem[];
  shipped: CoordinatorShippedItem[];
  continuations: CoordinatorOffer[];
  summary: { corpora: number; hostsOnline: number; hosts: number; needsYou: number; stuck: number; working: number; shipped: number; canContinue: number; guarded: number };
}

export interface WorkspaceCoordinationOptions {
  /** Explicit `--mount` roots. Each requires a valid portable corpus identity. */
  mounts?: string[];
  /** A lone `--dir` corpus, used when no mounts are named. */
  root?: string;
  now?: Date;
  shippedWindowSeconds?: number;
  quietSeconds?: number;
}

function sha(parts: unknown[]): string {
  return crypto.createHash("sha256").update(JSON.stringify(parts)).digest("hex");
}

function normalizedID(value: string): string {
  return value.trim().toLowerCase();
}

function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:@=+,-]+$/u.test(value) ? value : `'${value.replace(/'/gu, `'\\''`)}'`;
}

function resolveCoordinatorCorpora(options: WorkspaceCoordinationOptions): { corpora: CoordinatorCorpus[]; issues: CoordinatorIssue[] } {
  const corpora: CoordinatorCorpus[] = [];
  const issues: CoordinatorIssue[] = [];
  const mounts = options.mounts ?? [];
  if (!mounts.length) {
    const root = path.resolve(options.root ?? process.cwd());
    const status = corpusIdentityStatus(root);
    if (status.valid && status.identity) corpora.push({ id: status.identity.id, name: status.identity.name, root, identityValid: true });
    else corpora.push({ id: `path:${root}`, name: path.basename(root), root, identityValid: false });
    return { corpora, issues };
  }
  // Mounted reads follow federated-workspace rules: identified corpora only,
  // no duplicate roots, and no two roots claiming one corpus ID.
  const seenRoots = new Set<string>();
  const seenIDs = new Map<string, string>();
  for (const mount of mounts) {
    const root = path.resolve(mount);
    if (seenRoots.has(root)) continue;
    seenRoots.add(root);
    const status = corpusIdentityStatus(root);
    if (!status.valid || !status.identity) {
      issues.push({ root, message: status.issues.map((issue) => `${issue.path}: ${issue.message}`).join("; ") || "invalid corpus identity" });
      continue;
    }
    const previous = seenIDs.get(status.identity.id);
    if (previous && previous !== root) {
      issues.push({ root, message: `duplicates corpus id ${status.identity.id} mounted at ${previous}` });
      continue;
    }
    seenIDs.set(status.identity.id, root);
    corpora.push({ id: status.identity.id, name: status.identity.name, root, identityValid: true });
  }
  return { corpora, issues };
}

interface SourceTaskLink {
  file: string;
  relativePath: string;
  line: number;
  heading: string;
  threadId?: string;
  taskId?: string;
}

const RUN_PROPERTY_PATTERN = /^\s*:(?:ORG2_RUN_ID|CELORGA_RUN_ID):\s*(\S+)\s*$/u;
const THREAD_PROPERTY_PATTERN = /^\s*:(?:CELORGA_THREAD_ID|ORG2_THREAD_ID|AI_CHAT_THREAD_ID):\s*([0-9A-Fa-f-]{36})\s*$/u;
const ID_PROPERTY_PATTERN = /^\s*:ID:\s*(\S+)\s*$/u;
const THREAD_COMMENT_PATTERN = /AI chat thread:?\s+([0-9A-Fa-f-]{36})/u;

/**
 * Find the canonical task heading that names this run, but only inside the
 * run's own context references. This keeps the lookup bounded and cited.
 */
function sourceTaskLink(root: string, run: AgentRun, cache: Map<string, string[] | null>): SourceTaskLink | undefined {
  for (const context of run.context) {
    const ref = context.ref.replace(/^file:/u, "").replace(/::.*$/u, "");
    if (!/\.org2?$/iu.test(ref)) continue;
    const file = path.resolve(root, ref);
    const relative = path.relative(root, file);
    if (relative.startsWith("..") || path.isAbsolute(relative)) continue;
    let lines = cache.get(file);
    if (lines === undefined) {
      try {
        const stat = fs.statSync(file);
        lines = stat.isFile() && stat.size <= 8 * 1024 * 1024 ? fs.readFileSync(file, "utf8").split(/\r?\n/u) : null;
      } catch {
        lines = null;
      }
      cache.set(file, lines);
    }
    if (!lines) continue;
    for (let index = 0; index < lines.length; index += 1) {
      const match = RUN_PROPERTY_PATTERN.exec(lines[index]!);
      if (!match || match[1] !== run.id) continue;
      let headingLine = index;
      while (headingLine > 0 && !/^\*+\s/u.test(lines[headingLine]!)) headingLine -= 1;
      if (!/^\*+\s/u.test(lines[headingLine] ?? "")) continue;
      let threadId: string | undefined;
      let taskId: string | undefined;
      for (let cursor = headingLine + 1; cursor < lines.length; cursor += 1) {
        const line = lines[cursor]!;
        if (/^\s*:END:\s*$/u.test(line) || /^\*+\s/u.test(line)) break;
        threadId ??= THREAD_PROPERTY_PATTERN.exec(line)?.[1];
        taskId ??= ID_PROPERTY_PATTERN.exec(line)?.[1];
      }
      return {
        file,
        relativePath: relative,
        line: headingLine + 1,
        heading: lines[headingLine]!.replace(/^\*+\s+/u, "").trim(),
        ...(threadId ? { threadId: normalizedID(threadId) } : {}),
        ...(taskId ? { taskId } : {}),
      };
    }
  }
  return undefined;
}

function commentThreadID(run: AgentRun): string | undefined {
  for (const comment of [...run.comments].reverse()) {
    const match = THREAD_COMMENT_PATTERN.exec(comment.body);
    if (match) return normalizedID(match[1]!);
  }
  return undefined;
}

function activityEvidence(item: ActivityEvidence): CoordinatorEvidence {
  const kind: CoordinatorEvidence["kind"] = item.source === "run" ? "run-event" : item.source;
  return { kind, ref: item.ref, detail: item.detail, ...(item.at ? { at: item.at } : {}) };
}

function runEvidence(snapshot: AgentRunSnapshot, source: SourceTaskLink | undefined): CoordinatorEvidence[] {
  const evidence: CoordinatorEvidence[] = [{
    kind: "run-file",
    ref: `run:${snapshot.run.id}`,
    path: snapshot.file,
    detail: `Durable run record (${snapshot.run.status}, revision ${snapshot.revision.slice(0, 12)})`,
  }];
  if (source) {
    evidence.push({
      kind: "source-task",
      ref: source.taskId ? `id:${source.taskId}` : `file:${source.relativePath}::${source.line}`,
      path: source.file,
      line: source.line,
      detail: source.heading,
    });
  }
  return evidence;
}

interface CorpusReadModel {
  corpus: CoordinatorCorpus;
  hosts: ActivityHost[];
  explanations: ActivityExplanation[];
  /** Revision-bearing snapshots for reported runs only: explained, or shipped in the window. */
  snapshots: AgentRunSnapshot[];
  threadState?: OpenClawThreadState;
  sources: Map<string, SourceTaskLink | undefined>;
  threads: Map<string, OpenClawChatThreadRecord | undefined>;
  /** Newest run per logical identity (logical work ID, else normalized title), to detect superseded runs. */
  newestByIdentity: Map<string, { id: string; updatedAt: string; status: AgentRun["status"] }>;
}

function runIdentity(run: AgentRun): string {
  return run.logicalWorkId ? `work:${run.logicalWorkId}` : `title:${(run.title?.trim() || run.goal).toLowerCase().replace(/\s+/gu, " ").slice(0, 200)}`;
}

function readCorpus(corpus: CoordinatorCorpus, now: Date, sinceMs: number): CorpusReadModel {
  // One run scan feeds both the activity explanations and the shipped view.
  let runs: AgentRun[] = [];
  try { runs = listAgentRuns(corpus.root); } catch { runs = []; }
  const explained = explainActivity(corpus.root, { now, runs });
  const explainedRuns = new Set(explained.items.filter((item) => item.kind === "run").map((item) => item.id));
  const reported = runs.filter((run) => explainedRuns.has(run.id)
    || (run.status === "completed" && Date.parse(run.completedAt ?? run.updatedAt) >= sinceMs));
  const snapshots: AgentRunSnapshot[] = [];
  for (const run of reported) {
    try { snapshots.push(loadAgentRunSnapshot(corpus.root, run.id)); } catch { /* removed or unreadable since listing */ }
  }
  let threadState: OpenClawThreadState | undefined;
  try { threadState = loadOpenClawThreadState(corpus.root); } catch { threadState = undefined; }
  const cache = new Map<string, string[] | null>();
  const sources = new Map<string, SourceTaskLink | undefined>();
  for (const snapshot of snapshots) sources.set(snapshot.run.id, sourceTaskLink(corpus.root, snapshot.run, cache));
  const newestByIdentity = new Map<string, { id: string; updatedAt: string; status: AgentRun["status"] }>();
  for (const run of runs) {
    const key = runIdentity(run);
    const current = newestByIdentity.get(key);
    if (!current || run.updatedAt > current.updatedAt) newestByIdentity.set(key, { id: run.id, updatedAt: run.updatedAt, status: run.status });
  }
  return { corpus, hosts: explained.hosts, explanations: explained.items, snapshots, threadState, sources, threads: new Map(), newestByIdentity };
}

function corpusRef(corpus: CoordinatorCorpus) {
  return { id: corpus.id, root: corpus.root };
}

function toItem(model: CorpusReadModel, explanation: ActivityExplanation): CoordinatorItem {
  const evidence: CoordinatorEvidence[] = [];
  if (explanation.kind === "run") {
    const snapshot = model.snapshots.find((candidate) => candidate.run.id === explanation.id);
    if (snapshot) evidence.push(...runEvidence(snapshot, model.sources.get(snapshot.run.id)));
  }
  if (explanation.kind === "thread") evidence.push({ kind: "thread", ref: `thread:${explanation.id}`, detail: `AI chat ${explanation.title}` });
  evidence.push(...explanation.evidence.map(activityEvidence));
  return {
    corpus: corpusRef(model.corpus),
    kind: explanation.kind,
    id: explanation.id,
    title: explanation.title,
    state: explanation.state,
    reasonCode: explanation.reason.code,
    summary: explanation.reason.summary,
    confidence: explanation.confidence,
    confidenceReason: explanation.confidenceReason,
    reportedBy: explanation.reportedBy,
    lastSignal: explanation.lastSignal,
    blocking: explanation.blocking,
    related: explanation.related,
    evidence,
  };
}

/**
 * Stuck means durable state claims progress that live evidence cannot
 * confirm, or the run failed. A person-owned boundary is "needs you", not stuck.
 */
export function classifyCoordinatorItem(explanation: ActivityExplanation): "needs-you" | "stuck" | "working" | "other" {
  if (explanation.state === "failed") return "stuck";
  if (explanation.needsAttention) return "needs-you";
  if ((explanation.state === "working" || explanation.state === "queued" || explanation.state === "due") && explanation.confidence === "uncertain") return "stuck";
  if (explanation.state === "working") return "working";
  return "other";
}

function shippedItems(model: CorpusReadModel, sinceMs: number): CoordinatorShippedItem[] {
  return model.snapshots.flatMap((snapshot) => {
    const run = snapshot.run;
    if (run.status !== "completed") return [];
    const completedAt = run.completedAt ?? run.updatedAt;
    if (!(Date.parse(completedAt) >= sinceMs)) return [];
    const source = model.sources.get(run.id);
    const evidence = runEvidence(snapshot, source);
    if (run.outcome?.summary) evidence.push({ kind: "outcome", ref: `run:${run.id}#outcome`, detail: run.outcome.summary });
    for (const artifact of run.artifacts) {
      evidence.push({ kind: "artifact", ref: `run:${run.id}#artifact:${artifact.id}`, path: artifact.path, detail: `${artifact.role}${artifact.reviewStatus ? ` (${artifact.reviewStatus})` : ""}${artifact.title ? `: ${artifact.title}` : ""}` });
    }
    for (const validation of run.validations) {
      evidence.push({ kind: "validation", ref: `run:${run.id}#validation:${validation.id}`, at: validation.checkedAt, detail: `${validation.name}: ${validation.status}${validation.detail ? ` — ${validation.detail.slice(0, 200)}` : ""}` });
    }
    const count = (status: string) => run.validations.filter((validation) => validation.status === status).length;
    return [{
      corpus: corpusRef(model.corpus),
      runId: run.id,
      title: run.title?.trim() || run.goal,
      completedAt,
      summary: run.outcome?.summary ?? "Completed without a recorded outcome summary",
      highlights: run.outcome?.highlights ?? [],
      nextActions: run.outcome?.nextActions ?? [],
      reviewPending: run.artifacts.some((artifact) => artifact.reviewStatus === "review-required"),
      validations: { passed: count("passed"), failed: count("failed"), warning: count("warning"), skipped: count("skipped") },
      ...(run.assignee ? { assignee: run.assignee } : {}),
      evidence,
    }];
  }).sort((left, right) => right.completedAt.localeCompare(left.completedAt));
}

function hydratedThread(model: CorpusReadModel, threadId: string): OpenClawChatThreadRecord | undefined {
  const key = normalizedID(threadId);
  if (model.threads.has(key)) return model.threads.get(key);
  let thread: OpenClawChatThreadRecord | undefined;
  // Only threads in the summary listing can be hydrated; skip a full reload for unknown IDs.
  if (model.threadState && !findOpenClawThread(model.threadState, threadId)) thread = undefined;
  else {
    try {
      const state = loadOpenClawThreadState(model.corpus.root, { hydrateThreadID: threadId });
      thread = findOpenClawThread(state, threadId) ?? undefined;
    } catch {
      thread = model.threadState ? findOpenClawThread(model.threadState, threadId) ?? undefined : undefined;
    }
  }
  model.threads.set(key, thread);
  return thread;
}

function lastExecutorHostRef(thread: OpenClawChatThreadRecord): string | undefined {
  for (const message of [...(thread.messages ?? [])].reverse()) {
    const provenance = message.provenance as { executionHostRef?: unknown } | undefined;
    if (provenance && typeof provenance.executionHostRef === "string" && provenance.executionHostRef.trim()) return provenance.executionHostRef;
  }
  return undefined;
}

/** Route like the app: keep the conversation on its last executor; fail over only when that host is unavailable. */
export function routeThreadContinuation(hosts: ActivityHost[], thread: OpenClawChatThreadRecord): { route?: CoordinatorRoute; detail: string } {
  const destinationID = typeof thread.destinationID === "string" && thread.destinationID.trim()
    ? thread.destinationID.trim()
    : `builtin.${String(thread.runtime || "openClaw").toLowerCase()}`;
  const eligible = (host: ActivityHost) => isHostLive(host) && !host.draining
    && host.enabledDestinationIDs.includes(destinationID)
    && !host.authenticationNeededDestinationIDs.includes(destinationID);
  const lastRef = lastExecutorHostRef(thread);
  const last = lastRef ? hosts.find((host) => host.hostRef === lastRef) : undefined;
  if (last && eligible(last)) {
    return { route: { destinationID, hostRef: last.hostRef, hostName: last.hostName, basis: "last-executor" }, detail: `${last.hostName} last ran this conversation and is online with ${destinationID}` };
  }
  const failover = hosts.find(eligible);
  if (failover) {
    const why = lastRef ? `last executor ${last?.hostName ?? lastRef} is ${last ? (last.draining ? "draining" : last.state) : "not reporting presence"}` : "no prior executor recorded";
    return { route: { destinationID, hostRef: failover.hostRef, hostName: failover.hostName, basis: "failover" }, detail: `${failover.hostName} can take ${destinationID}; ${why}` };
  }
  return { detail: `No online, non-draining host has destination ${destinationID} enabled and signed in` };
}

function continuationMessage(run: AgentRun, snapshot: AgentRunSnapshot, explanation: ActivityExplanation | undefined, source: SourceTaskLink | undefined): string {
  const lines = [
    `Continue Celorga run ${run.id}: ${run.title?.trim() || run.goal}`,
    `Coordinator observation: ${explanation?.reason.summary ?? `run is ${run.status}`}.`,
    `Resume from the durable run record ${snapshot.file}${source ? ` and the task at ${source.relativePath}:${source.line}` : ""}.`,
    "Re-check current state before acting, do not repeat external actions already recorded, keep approvals explicit, and record progress, validations, and blockers with celorga run commands.",
  ];
  if (run.status === "failed" && run.failure) lines.splice(2, 0, `Recorded failure: ${run.failure}`);
  return lines.join("\n");
}

function offerID(corpusID: string, kind: CoordinatorOfferKind, run: AgentRunSnapshot, threadId: string | undefined, latestMessageID: string | undefined): string {
  return `co_${sha([corpusID, kind, run.run.id, run.revision, threadId ?? null, latestMessageID ?? null]).slice(0, 20)}`;
}

function continuationOffers(model: CorpusReadModel, now: Date, quietSeconds: number): CoordinatorOffer[] {
  const offers: CoordinatorOffer[] = [];
  const explanations = new Map(model.explanations.filter((item) => item.kind === "run").map((item) => [item.id, item]));
  const corpusFlag = model.corpus.identityValid ? `--mount ${shellQuote(model.corpus.root)}` : `--dir ${shellQuote(model.corpus.root)}`;
  for (const snapshot of model.snapshots) {
    const run = snapshot.run;
    if (!["running", "queued", "failed"].includes(run.status)) continue;
    // Offers follow the activity attention window: only runs the explanation reports.
    const explanation = explanations.get(run.id);
    if (!explanation) continue;
    // A live, confirmed turn is working; offering to continue it would duplicate work.
    if (explanation && explanation.state === "working" && explanation.confidence === "live") continue;
    if (run.status === "queued" && run.workflowId) continue; // owned by the automation host's scheduler
    const source = model.sources.get(run.id);
    const threadId = commentThreadID(run) ?? source?.threadId;
    const pendingApprovals = run.approvals.filter((approval) => approval.status === "pending");
    const lastEventMs = Math.max(...run.events.map((event) => Date.parse(event.at)).filter(Number.isFinite), Date.parse(run.updatedAt) || 0);
    const quietFor = Math.max(0, Math.round((now.getTime() - lastEventMs) / 1000));
    const commonGuards: CoordinatorGuard[] = [
      { check: "open-run", passed: true, detail: `Run is ${run.status} in its durable record` },
      { check: "no-pending-approval", passed: pendingApprovals.length === 0, detail: pendingApprovals.length ? `${pendingApprovals.length} approval(s) pending; a person must decide first` : "No approval is pending" },
    ];
    const title = run.title?.trim() || run.goal;
    const base = { corpus: corpusRef(model.corpus), runId: run.id, runTitle: title, runStatus: run.status, runRevision: snapshot.revision };

    if (threadId) {
      const thread = hydratedThread(model, threadId);
      const guards = [...commonGuards];
      guards.push({ check: "linked-thread", passed: Boolean(thread), detail: thread ? `Linked AI chat ${thread.title ?? thread.id}${source?.threadId === threadId ? ` from ${source.relativePath}:${source.line}` : " from run comment"}` : `Linked thread ${threadId} is not in this corpus's chat store` });
      let route: CoordinatorRoute | undefined;
      let latestMessageID: string | undefined;
      if (thread) {
        latestMessageID = thread.messages?.at(-1)?.id;
        guards.push({ check: "single-agent-thread", passed: thread.isSharedRoom !== true, detail: thread.isSharedRoom === true ? "Shared room: continue with thread post --request-turn instead" : `Single-agent ${thread.runtime ?? "chat"}` });
        guards.push({ check: "not-archived", passed: thread.isArchived !== true, detail: thread.isArchived === true ? "Thread is archived" : "Thread is active" });
        const liveTurn = model.hosts.flatMap((host) => host.turns.map((turn) => ({ host, turn }))).find(({ turn }) => normalizedID(turn.threadID) === normalizedID(thread.id));
        guards.push({
          check: "no-active-turn",
          passed: !liveTurn,
          detail: liveTurn
            ? `${liveTurn.host.hostName} reports a turn for this thread (${liveTurn.host.state}${isHostLive(liveTurn.host) ? "" : "; cannot confirm it stopped"})`
            : "No host reports a turn for this thread",
        });
        const pending = pendingInboxMessages(model.corpus.root, thread.id);
        const unresolved = thread.storedHasUnresolvedLatestDelivery === true;
        guards.push({
          check: "no-undelivered-request",
          passed: pending.length === 0 && !unresolved,
          detail: pending.length ? `${pending.length} inbox request(s) not yet consumed` : unresolved ? "Latest message delivery is unresolved" : "No queued or unresolved request",
        });
        const routed = routeThreadContinuation(model.hosts, thread);
        route = routed.route;
        guards.push({ check: "route", passed: Boolean(route), detail: routed.detail });
      }
      if (run.status === "running") {
        guards.push({ check: "quiet", passed: quietFor >= quietSeconds, detail: `Last run event ${quietFor}s ago; continuation requires ${quietSeconds}s of quiet` });
      }
      const idempotencyKey = `workspace-continue:${run.id}:${snapshot.revision.slice(0, 16)}`;
      const message = continuationMessage(run, snapshot, explanation, source);
      const id = offerID(model.corpus.id, "thread-send", snapshot, thread?.id, latestMessageID);
      offers.push({
        ...base,
        id,
        kind: "thread-send",
        allowed: guards.every((guard) => guard.passed),
        threadId: thread?.id ?? threadId,
        ...(route ? { route } : {}),
        idempotencyKey,
        message,
        guards,
        effect: "Queues one idempotent single-agent send to the linked chat and records a run comment. Celorga must consume it; queuing does not confirm the turn started.",
        command: `celorga thread send ${thread?.id ?? threadId} --message TEXT --idempotency-key ${idempotencyKey} --dir ${shellQuote(model.corpus.root)} --apply`,
        continueCommand: `celorga workspace continue ${id} ${corpusFlag} --apply`,
      });
      continue;
    }

    if (run.status === "failed") {
      const scheduled = Boolean(run.workflowId || run.attempt || run.logicalWorkId);
      const guards = [
        ...commonGuards,
        { check: "no-linked-thread", passed: true, detail: "No linked chat; retry only requeues the run" },
        (() => {
          const newest = model.newestByIdentity.get(runIdentity(run));
          const superseded = newest && newest.id !== run.id;
          return {
            check: "not-superseded",
            passed: !superseded,
            detail: superseded ? `A newer run for the same work exists (${newest!.id}, ${newest!.status})` : "This is the newest run for its work",
          };
        })(),
        {
          check: "has-executor",
          passed: Boolean(run.assignee || run.agentRef || run.destinationRef),
          detail: run.assignee || run.agentRef || run.destinationRef
            ? `Requeued work stays with ${run.assignee ?? run.agentRef ?? run.destinationRef}`
            : "No assignee, agent ref, or destination would pick up a requeued run",
        },
        {
          check: "not-scheduled-attempt",
          passed: !scheduled,
          detail: scheduled
            ? `Attempt of ${run.workflowId ? `workflow ${run.workflowId}` : `logical work ${run.logicalWorkId ?? "?"}`}; its scheduler owns retries and the next trigger creates a new attempt`
            : "Standalone run; no scheduler owns its retries",
        },
      ];
      const id = offerID(model.corpus.id, "run-retry", snapshot, undefined, undefined);
      offers.push({
        ...base,
        id,
        kind: "run-retry",
        allowed: guards.every((guard) => guard.passed),
        guards,
        effect: "Moves the run back to queued under its current revision. No executor is started; an assignee or scheduler must pick it up.",
        command: `celorga run retry ${run.id} --if-revision ${snapshot.revision} --dir ${shellQuote(model.corpus.root)}`,
        continueCommand: `celorga workspace continue ${id} ${corpusFlag} --apply`,
      });
    }
  }
  return offers;
}

export function coordinateWorkspace(options: WorkspaceCoordinationOptions = {}): WorkspaceCoordination {
  const now = options.now ?? new Date();
  const shippedWindow = options.shippedWindowSeconds ?? WORKSPACE_COORDINATOR_DEFAULT_SHIPPED_SECONDS;
  const quietSeconds = options.quietSeconds ?? WORKSPACE_COORDINATOR_DEFAULT_QUIET_SECONDS;
  const sinceMs = now.getTime() - shippedWindow * 1000;
  const { corpora, issues } = resolveCoordinatorCorpora(options);
  const result: WorkspaceCoordination = {
    schema: WORKSPACE_COORDINATION_SCHEMA,
    generatedAt: now.toISOString(),
    shippedSince: new Date(sinceMs).toISOString(),
    corpora,
    issues,
    hosts: [],
    needsYou: [],
    stuck: [],
    working: [],
    shipped: [],
    continuations: [],
    summary: { corpora: 0, hostsOnline: 0, hosts: 0, needsYou: 0, stuck: 0, working: 0, shipped: 0, canContinue: 0, guarded: 0 },
  };
  for (const corpus of corpora) {
    let model: CorpusReadModel;
    try {
      model = readCorpus(corpus, now, sinceMs);
    } catch (error) {
      issues.push({ root: corpus.root, message: error instanceof Error ? error.message : String(error) });
      continue;
    }
    for (const host of model.hosts) {
      result.hosts.push({
        corpus: corpusRef(corpus),
        hostRef: host.hostRef,
        hostName: host.hostName,
        hostKind: host.hostKind,
        state: host.state,
        stateReason: host.stateReason,
        confidence: host.confidence,
        draining: host.draining,
        isAutomationHost: host.isAutomationHost,
        lastSeenAt: host.lastSeenAt,
        enabledDestinationIDs: host.enabledDestinationIDs,
        activeTurns: host.turns.map((turn) => ({
          threadID: turn.threadID,
          ...(turn.destinationName ? { destinationName: turn.destinationName } : {}),
          ...(turn.startedAt ? { startedAt: turn.startedAt } : {}),
          ...(turn.latestActivity?.title ? { latestActivity: turn.latestActivity.title } : {}),
        })),
        file: host.file,
      });
    }
    for (const explanation of model.explanations) {
      const bucket = classifyCoordinatorItem(explanation);
      if (bucket === "needs-you") result.needsYou.push(toItem(model, explanation));
      else if (bucket === "stuck") result.stuck.push(toItem(model, explanation));
      else if (bucket === "working") result.working.push(toItem(model, explanation));
    }
    result.shipped.push(...shippedItems(model, sinceMs));
    result.continuations.push(...continuationOffers(model, now, quietSeconds));
  }
  issues.sort((left, right) => left.root.localeCompare(right.root) || left.message.localeCompare(right.message));
  result.shipped.sort((left, right) => right.completedAt.localeCompare(left.completedAt));
  result.continuations.sort((left, right) => Number(right.allowed) - Number(left.allowed) || left.runTitle.localeCompare(right.runTitle));
  result.summary = {
    corpora: corpora.length,
    hosts: result.hosts.length,
    hostsOnline: result.hosts.filter((host) => host.state === "online").length,
    needsYou: result.needsYou.length,
    stuck: result.stuck.length,
    working: result.working.length,
    shipped: result.shipped.length,
    canContinue: result.continuations.filter((offer) => offer.allowed).length,
    guarded: result.continuations.filter((offer) => !offer.allowed).length,
  };
  return result;
}

export interface WorkspaceContinueOptions extends WorkspaceCoordinationOptions {
  apply?: boolean;
  actor?: string;
}

export interface WorkspaceContinuationResult {
  schema: typeof WORKSPACE_CONTINUATION_SCHEMA;
  applied: boolean;
  offer: CoordinatorOffer;
  delivery?: { status: string; turnStatus: string; messageId: string; file: string };
  run?: { id: string; status: AgentRun["status"]; revision?: string; comment?: string };
  /** What is still unconfirmed after this action and how to check it. */
  unconfirmed: string;
  verify: string;
}

/**
 * Re-derive the workspace, find the offer by its revision-bound ID, require
 * every guard to pass now, and delegate to the native continuation. Preview by
 * default; `apply` performs exactly one guarded, idempotent action.
 */
export function continueWorkspaceOffer(offerId: string, options: WorkspaceContinueOptions = {}): WorkspaceContinuationResult {
  const coordination = coordinateWorkspace(options);
  const offer = coordination.continuations.find((candidate) => candidate.id === offerId);
  if (!offer) {
    throw new Error(`continuation offer ${offerId} is no longer current; its run, thread, or route changed. Re-run celorga workspace coordinate and choose a current offer. Nothing was changed.`);
  }
  if (!offer.allowed) {
    const failed = offer.guards.filter((guard) => !guard.passed).map((guard) => `${guard.check}: ${guard.detail}`).join("; ");
    throw new Error(`continuation offer ${offerId} is guarded: ${failed}. Nothing was changed.`);
  }
  const actor = options.actor?.trim() || "Workspace coordinator";
  const root = offer.corpus.root;
  if (offer.kind === "thread-send") {
    const queued = queueAIChatInboxMessage(root, offer.threadId!, offer.message!, {
      send: true,
      authorLabel: actor,
      idempotencyKey: offer.idempotencyKey,
      apply: options.apply === true,
    });
    let revision: string | undefined;
    let runComment: string = options.apply === true ? "not needed: request was already queued or delivered" : "preview";
    if (options.apply === true && queued.applied) {
      // Record the continuation on the run under the revision the offer was
      // derived from, so concurrent progress is never silently overwritten.
      const snapshot = loadAgentRunSnapshot(root, offer.runId);
      if (snapshot.revision === offer.runRevision) {
        const updated = addAgentRunComment(snapshot.run, actor, `Workspace coordinator queued continuation ${queued.message.id} to AI chat thread: ${offer.threadId} via ${offer.route?.hostName ?? "unknown host"} (${offer.route?.basis ?? "unrouted"}). Turn start unconfirmed.`);
        saveAgentRun(root, updated, { expectedRevision: snapshot.revision, rejectSourceDrift: true });
        revision = loadAgentRunSnapshot(root, offer.runId).revision;
        runComment = "recorded";
      } else {
        runComment = "skipped: the run changed after the offer; the send was still queued idempotently";
      }
    }
    return {
      schema: WORKSPACE_CONTINUATION_SCHEMA,
      applied: queued.applied,
      offer,
      delivery: { status: queued.deliveryStatus, turnStatus: queued.turnStatus, messageId: queued.message.id, file: queued.file },
      run: { id: offer.runId, status: offer.runStatus, ...(revision ? { revision } : {}), comment: runComment },
      unconfirmed: "Celorga must consume the request on a host with the destination available; neither delivery nor the turn start is confirmed by queuing.",
      verify: `celorga thread wait ${offer.threadId} --after ${queued.message.id} --until reply --dir ${shellQuote(root)} --timeout 60`,
    };
  }
  const snapshot = loadAgentRunSnapshot(root, offer.runId);
  if (snapshot.revision !== offer.runRevision) throw new Error(`run ${offer.runId} changed since the offer; nothing was changed`);
  let revision: string | undefined;
  let status = snapshot.run.status;
  if (options.apply === true) {
    const retried = transitionAgentRun(snapshot.run, "queued", { actor });
    saveAgentRun(root, retried, { expectedRevision: snapshot.revision, rejectSourceDrift: true });
    const saved = loadAgentRunSnapshot(root, offer.runId);
    revision = saved.revision;
    status = saved.run.status;
  }
  return {
    schema: WORKSPACE_CONTINUATION_SCHEMA,
    applied: options.apply === true,
    offer,
    run: { id: offer.runId, status, ...(revision ? { revision } : {}) },
    unconfirmed: "The run is requeued only; no executor was started and no turn was requested.",
    verify: `celorga run wait ${offer.runId} --until running --dir ${shellQuote(root)} --timeout 60`,
  };
}

function clip(text: string, limit = 120): string {
  const compact = text.replace(/\s+/gu, " ").trim();
  return compact.length > limit ? `${compact.slice(0, limit - 1)}…` : compact;
}

function age(nowMs: number, at: string | undefined): string {
  if (!at) return "unknown";
  const seconds = Math.max(0, Math.round((nowMs - Date.parse(at)) / 1000));
  if (seconds < 90) return `${seconds}s ago`;
  if (seconds < 5400) return `${Math.round(seconds / 60)}m ago`;
  if (seconds < 172800) return `${Math.round(seconds / 3600)}h ago`;
  return `${Math.round(seconds / 86400)}d ago`;
}

/** Plain-text rendering for terminals and chat; JSON remains the contract. */
export function renderWorkspaceCoordinationText(result: WorkspaceCoordination): string {
  const nowMs = Date.parse(result.generatedAt);
  const lines: string[] = [];
  const s = result.summary;
  lines.push(`Workspace: ${s.corpora} corpus(es), ${s.hostsOnline}/${s.hosts} host(s) online — ${s.needsYou} need you, ${s.stuck} stuck, ${s.working} working, ${s.shipped} shipped since ${result.shippedSince}, ${s.canContinue} can continue (${s.guarded} guarded)`);
  for (const issue of result.issues) lines.push(`  issue ${issue.root}: ${issue.message}`);
  const multi = result.corpora.length > 1;
  const where = (corpus: { id: string }) => (multi ? `[${corpus.id}] ` : "");
  if (result.hosts.length) {
    lines.push("", "Hosts");
    for (const host of result.hosts) lines.push(`  ${where(host.corpus)}${host.hostName} (${host.hostKind}) ${host.state}${host.draining ? ", draining" : ""} — ${host.stateReason}; ${host.activeTurns.length} turn(s)`);
  }
  const section = (title: string, items: CoordinatorItem[]) => {
    if (!items.length) return;
    lines.push("", title);
    for (const item of items) {
      const who = [item.reportedBy.hostName ?? item.reportedBy.hostRef, item.reportedBy.runtime].filter(Boolean).join(" / ");
      lines.push(`  ${where(item.corpus)}${item.kind} ${item.id} — ${clip(item.title)}`);
      lines.push(`    ${item.state} (${item.confidence}): ${clip(item.summary, 200)}${who ? ` [${who}]` : ""}; last signal ${age(nowMs, item.lastSignal?.at)}`);
      for (const blocker of item.blocking) lines.push(`    blocking ${blocker.kind}: ${clip(blocker.summary, 160)}${blocker.command ? ` → ${blocker.command}` : ""}`);
      const cite = item.evidence.find((evidence) => evidence.kind === "source-task") ?? item.evidence.find((evidence) => evidence.path);
      if (cite) lines.push(`    evidence: ${cite.path}${cite.line ? `:${cite.line}` : ""}`);
    }
  };
  section("Needs you", result.needsYou);
  section("Stuck", result.stuck);
  section("Working", result.working);
  if (result.shipped.length) {
    lines.push("", "Shipped");
    for (const item of result.shipped) {
      lines.push(`  ${where(item.corpus)}run ${item.runId} — ${clip(item.title)} (${age(nowMs, item.completedAt)})${item.reviewPending ? " [review pending]" : ""}`);
      lines.push(`    ${clip(item.summary, 200)}; validations ${item.validations.passed} passed, ${item.validations.failed} failed`);
    }
  }
  if (result.continuations.length) {
    lines.push("", "Continuation offers");
    for (const offer of result.continuations) {
      lines.push(`  ${offer.allowed ? "CAN CONTINUE" : "GUARDED"} ${offer.id} ${offer.kind} — ${where(offer.corpus)}${clip(offer.runTitle)}${offer.route ? ` via ${offer.route.hostName} (${offer.route.basis})` : ""}`);
      for (const guard of offer.guards.filter((candidate) => !candidate.passed)) lines.push(`    blocked by ${guard.check}: ${guard.detail}`);
      if (offer.allowed) lines.push(`    ${offer.continueCommand}`);
    }
  }
  return lines.join("\n");
}
