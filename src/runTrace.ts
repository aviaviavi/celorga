/**
 * Run failure explanations.
 *
 * `traceRun` follows one durable run through dispatch -> executor -> tools ->
 * result -> delivery and returns an evidence-linked verdict. It reads the same
 * structured records as `activityState.ts` (run event log and comments, chat
 * transcript and message provenance, host presence, the AI chat inbox) and
 * never scrapes terminal output.
 *
 * The verdict describes what is actually happening, which can differ from the
 * run record: a run marked `failed` whose executor is still reporting a live
 * turn is `running`, and a run whose executor replied but whose result never
 * reached the run record or the conversation is `completed-undelivered`. When
 * evidence is stale or missing the verdict is `unknown`, never `completed`.
 *
 * `retry` states whether re-queuing the run could execute the work twice.
 * `celorga run retry` refuses unsafe retries unless `--force` is given.
 */
import path from "node:path";
import { loadAgentRun, type AgentRun } from "./agentRun.js";
import {
  ACTIVITY_RUNNING_QUIET_SECONDS,
  describeAge,
  isHostLive,
  linkedThreadID,
  loadActivityHosts,
  messageTime,
  pendingInboxMessages,
  type ActivityConfidence,
  type ActivityEvidence,
  type ActivityHost,
  type ActivityLiveActivity,
  type ActivityLiveTurn,
} from "./activityState.js";
import {
  findOpenClawThread,
  loadOpenClawThreadState,
  openClawDateMilliseconds,
  type OpenClawChatMessageRecord,
  type OpenClawChatThreadRecord,
} from "./openClawThreadState.js";

export const RUN_TRACE_SCHEMA = "org2:run-trace:v1" as const;

/** A tool still running after this long without an update is reported as slow. */
export const RUN_TRACE_SLOW_TOOL_SECONDS = 5 * 60;
/** A run event this recent is cached evidence that a run without presence is still running. */
export const RUN_TRACE_RECENT_EVENT_SECONDS = ACTIVITY_RUNNING_QUIET_SECONDS;
/** A hand-off this recent may simply not have been accepted yet. */
export const RUN_TRACE_HANDOFF_GRACE_SECONDS = 2 * 60;

export type RunTraceVerdict =
  | "queued"
  | "running"
  | "waiting"
  | "failed"
  | "completed"
  | "completed-undelivered"
  | "canceled"
  | "unknown";

export type RunTraceStageName = "dispatch" | "executor" | "tools" | "result" | "delivery";
export type RunTraceStageStatus = "ok" | "active" | "pending" | "warning" | "failed" | "unknown" | "not-applicable";

export interface RunTraceStage {
  stage: RunTraceStageName;
  status: RunTraceStageStatus;
  summary: string;
  evidence: ActivityEvidence[];
}

export type RunTraceFindingCode =
  | "slow-tool"
  | "shell-error"
  | "stale-host"
  | "host-mismatch"
  | "delivery-uncertain"
  | "result-unrecorded"
  | "result-after-failure"
  | "executor-active-after-terminal"
  | "turn-interrupted"
  | "silent-run";

export interface RunTraceFinding {
  code: RunTraceFindingCode;
  stage: RunTraceStageName;
  summary: string;
  evidence: ActivityEvidence[];
}

export type RunTraceRetryRecommendation = "retry" | "wait" | "record-result" | "redeliver" | "decide" | "inspect" | "none";

export interface RunTraceRetry {
  /** True only when re-queuing cannot run work that is active or already produced. */
  safe: boolean;
  recommendation: RunTraceRetryRecommendation;
  reason: string;
}

export interface RunTrace {
  schema: typeof RUN_TRACE_SCHEMA;
  generatedAt: string;
  corpus: string;
  run: { id: string; title: string; status: string; workflowId?: string; threadId?: string };
  verdict: RunTraceVerdict;
  reason: { code: string; summary: string };
  confidence: ActivityConfidence;
  confidenceReason: string;
  stages: RunTraceStage[];
  findings: RunTraceFinding[];
  retry: RunTraceRetry;
}

export interface TraceRunOptions {
  now?: Date;
}

const SHELL_ERROR_PATTERN = /\b(?:zsh|bash|sh|fish|dash):\s.*(?:command not found|no matches found|bad substitution|syntax error|parse error|not found)|\bcommand not found\b|\bno matches found\b|\bbad substitution\b/iu;
const EXPLICIT_FAILED_OUTCOME = /^\s*ORG2_RUN_OUTCOME:\s*failed\s*$/mu;
const REPLY_COMMENT_PATTERN = /^AI chat thread\s+([0-9A-Fa-f-]{36})\s+replied:/u;

type Message = OpenClawChatMessageRecord;

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function iso(ms: number): string | undefined {
  return Number.isFinite(ms) ? new Date(ms).toISOString() : undefined;
}

function ageSeconds(now: Date, ms: number): number {
  return Math.max(0, Math.round((now.getTime() - ms) / 1000));
}

function provenanceOf(message: Message | undefined): Record<string, unknown> {
  const raw = message?.provenance;
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : {};
}

/** The start of the run's current attempt: creation, or the latest retry back to `queued`. */
function attemptStart(run: AgentRun): number {
  let start = Date.parse(run.createdAt);
  for (const event of run.events) {
    if (event.type === "status-changed" && event.data?.to === "queued") start = Date.parse(event.at);
  }
  return start;
}

function latestTransitionTo(run: AgentRun, status: string, after: number): AgentRun["events"][number] | undefined {
  return [...run.events].reverse().find((event) => event.type === "status-changed"
    && event.data?.to === status
    && Date.parse(event.at) >= after);
}

function runEvidence(run: AgentRun, event: AgentRun["events"][number], detail: string): ActivityEvidence {
  return { source: "run-event", ref: `run:${run.id}#${event.id}`, at: event.at, detail };
}

function messageEvidence(threadID: string, message: Message, detail: string): ActivityEvidence {
  return { source: "transcript", ref: `thread:${threadID}#${String(message.id ?? "?")}`, at: iso(messageTime(message)), detail };
}

function presenceEvidence(host: ActivityHost, detail: string): ActivityEvidence {
  return { source: "presence", ref: host.file, at: host.lastSeenAt, detail };
}

function findLiveTurn(hosts: ActivityHost[], threadID: string | undefined): { host: ActivityHost; turn: ActivityLiveTurn } | undefined {
  if (!threadID) return undefined;
  let found: { host: ActivityHost; turn: ActivityLiveTurn } | undefined;
  for (const host of hosts) {
    for (const turn of host.turns) {
      if (turn.threadID.toLowerCase() !== threadID) continue;
      if (!found || (isHostLive(host) && !isHostLive(found.host))) found = { host, turn };
    }
  }
  return found;
}

function loadThread(corpusRoot: string, threadID: string): OpenClawChatThreadRecord | undefined {
  try {
    const state = loadOpenClawThreadState(corpusRoot, { hydrateThreadID: threadID });
    return findOpenClawThread(state, threadID) ?? undefined;
  } catch {
    return undefined;
  }
}

function toolFindings(
  turn: ActivityLiveTurn,
  host: ActivityHost,
  now: Date,
): { findings: RunTraceFinding[]; running: ActivityLiveActivity[]; failed: ActivityLiveActivity[] } {
  const activities = turn.recentActivities ?? (turn.latestActivity ? [turn.latestActivity] : []);
  const tools = activities.filter((activity) => activity.kind === "tool");
  const running = tools.filter((activity) => activity.status === "running");
  const failed = tools.filter((activity) => activity.status === "failed");
  const findings: RunTraceFinding[] = [];
  for (const activity of running) {
    const updated = Date.parse(activity.updatedAt ?? "");
    if (!Number.isFinite(updated)) continue;
    const age = ageSeconds(now, updated);
    if (age < RUN_TRACE_SLOW_TOOL_SECONDS) continue;
    findings.push({
      code: "slow-tool",
      stage: "tools",
      summary: `${activity.title ?? "A tool"} has been running without an update since ${describeAge(age)}${isHostLive(host) ? "" : `; ${host.hostName} is ${host.state}, so it may have stopped`}`,
      evidence: [presenceEvidence(host, `${activity.kind}/${activity.status}: ${activity.title ?? activity.id ?? "tool"}`)],
    });
  }
  for (const activity of failed) {
    const text = `${activity.title ?? ""}\n${activity.detail ?? ""}`;
    if (!SHELL_ERROR_PATTERN.test(text)) continue;
    findings.push({
      code: "shell-error",
      stage: "tools",
      summary: `${activity.title ?? "A command"} failed with a shell error; the executor's shell or PATH may not match what the command expects`,
      evidence: [presenceEvidence(host, (activity.detail ?? activity.title ?? "failed tool").slice(0, 200))],
    });
  }
  return { findings, running, failed };
}

export function traceRun(corpusRootRaw: string, runID: string, options: TraceRunOptions = {}): RunTrace {
  const corpusRoot = path.resolve(corpusRootRaw);
  const run = loadAgentRun(corpusRoot, runID);
  return traceAgentRun(corpusRoot, run, options);
}

export function traceAgentRun(corpusRootRaw: string, run: AgentRun, options: TraceRunOptions = {}): RunTrace {
  const corpusRoot = path.resolve(corpusRootRaw);
  const now = options.now ?? new Date();
  const hosts = loadActivityHosts(corpusRoot, now);
  const hostsByRef = new Map(hosts.map((host) => [host.hostRef, host]));
  const threadID = linkedThreadID(run);
  const thread = threadID ? loadThread(corpusRoot, threadID) : undefined;
  const live = findLiveTurn(hosts, threadID);
  const liveActive = Boolean(live && isHostLive(live.host));
  const findings: RunTraceFinding[] = [];

  // MARK: Attempt window
  const start = attemptStart(run);
  const dispatchEvent = latestTransitionTo(run, "running", start);
  const failedEvent = run.status === "failed" ? latestTransitionTo(run, "failed", start) : undefined;
  const canceledEvent = run.status === "canceled" ? latestTransitionTo(run, "canceled", start) : undefined;
  const messages = (thread?.messages ?? []).filter((message) => {
    const at = messageTime(message);
    return !Number.isFinite(start) || !Number.isFinite(at) || at >= start - 1000;
  });
  const lastUser = [...messages].reverse().find((message) => message.role === "user");
  const lastUserAt = messageTime(lastUser);
  const reply = [...messages].reverse().find((message) => message.role === "assistant"
    && (!lastUser || !Number.isFinite(lastUserAt) || messageTime(message) >= lastUserAt));
  const replyAt = messageTime(reply);
  const replyComment = [...run.comments].reverse().find((comment) => REPLY_COMMENT_PATTERN.test(comment.body)
    && Date.parse(comment.createdAt) >= start);
  const pending = threadID ? pendingInboxMessages(corpusRoot, threadID).filter((message) => Date.parse(message.createdAt) >= start - 1000) : [];
  const pendingSends = pending.filter((message) => message.isSend);
  const pendingPosts = pending.filter((message) => !message.isSend);
  const resultText = reply?.content ?? replyComment?.body;
  const explicitFailure = typeof resultText === "string" && EXPLICIT_FAILED_OUTCOME.test(resultText);
  const hasResult = Boolean(reply || replyComment);
  const resultAt = Number.isFinite(replyAt) ? replyAt : Date.parse(replyComment?.createdAt ?? "");
  const userProvenance = provenanceOf(lastUser);
  const executionHostRef = str(userProvenance.executionHostRef);
  const executionHost = executionHostRef ? hostsByRef.get(executionHostRef) : undefined;
  const lastEventMs = Date.parse(run.events.at(-1)?.at ?? run.updatedAt);

  // MARK: Dispatch
  const dispatchEvidence: ActivityEvidence[] = [];
  const created = run.events.find((event) => event.type === "created");
  if (created) dispatchEvidence.push(runEvidence(run, created, `Created${created.actor ? ` by ${created.actor}` : ""}`));
  if (dispatchEvent) dispatchEvidence.push(runEvidence(run, dispatchEvent, `Started${dispatchEvent.actor ? ` by ${dispatchEvent.actor}` : ""}`));
  if (lastUser && threadID) {
    const received = str(userProvenance.receivedByHostName) ?? str(userProvenance.receivedByHostRef);
    const executes = str(userProvenance.executionHostName) ?? executionHostRef;
    dispatchEvidence.push(messageEvidence(threadID, lastUser, `Request ${lastUser.deliveryStatus ?? "recorded"}${received ? `; received by ${received}` : ""}${executes ? `; executes on ${executes}` : ""}`));
  }
  for (const send of pendingSends) dispatchEvidence.push({ source: "inbox", ref: send.file, at: send.createdAt, detail: "Send request queued; runtime start unconfirmed" });
  let dispatch: RunTraceStage;
  if (pendingSends.length && !liveActive && !hasResult) {
    dispatch = { stage: "dispatch", status: "pending", summary: "A send request is queued for Celorga; queue acceptance does not confirm that a runtime started", evidence: dispatchEvidence };
  } else if (dispatchEvent || lastUser || live || hasResult) {
    dispatch = { stage: "dispatch", status: "ok", summary: executionHostRef ? `Dispatched to ${str(userProvenance.executionHostName) ?? executionHostRef}` : "Dispatched", evidence: dispatchEvidence };
  } else if (run.status === "queued") {
    dispatch = { stage: "dispatch", status: "pending", summary: "Queued; no executor has started it", evidence: dispatchEvidence };
  } else if (run.status === "canceled" || run.status === "failed") {
    dispatch = { stage: "dispatch", status: "not-applicable", summary: "No dispatch was recorded in this attempt", evidence: dispatchEvidence };
  } else {
    dispatch = { stage: "dispatch", status: "unknown", summary: "No dispatch event or request message was recorded", evidence: dispatchEvidence };
  }

  // MARK: Executor
  let executor: RunTraceStage;
  if (live) {
    const evidence = [presenceEvidence(live.host, `${live.host.hostName} (${live.host.state}) reports a turn${live.turn.startedAt ? ` started ${live.turn.startedAt}` : ""}`)];
    if (executionHostRef && live.host.hostRef !== executionHostRef) {
      findings.push({
        code: "host-mismatch",
        stage: "executor",
        summary: `The request was dispatched to ${str(userProvenance.executionHostName) ?? executionHostRef}, but ${live.host.hostName} reports the turn`,
        evidence,
      });
    }
    if (liveActive) {
      executor = { stage: "executor", status: "active", summary: `Turn running on ${live.host.hostName}`, evidence };
    } else {
      findings.push({ code: "stale-host", stage: "executor", summary: `${live.host.hostName} last reported this turn ${describeAge(live.host.lastSeenAgeSeconds)} and is ${live.host.state}`, evidence });
      executor = { stage: "executor", status: "unknown", summary: `Last reported running on ${live.host.hostName}, which is ${live.host.state}; the turn may have finished or stopped`, evidence };
    }
  } else if (hasResult) {
    executor = { stage: "executor", status: "ok", summary: "The executor finished its turn", evidence: [] };
  } else if (executionHost && lastUser?.deliveryStatus === "sending") {
    const evidence = [presenceEvidence(executionHost, `${executionHost.hostName} is ${executionHost.state} and reports no turn for this thread`)];
    if (!isHostLive(executionHost)) {
      findings.push({ code: "stale-host", stage: "executor", summary: `${executionHost.hostName} is ${executionHost.state} (${executionHost.stateReason})`, evidence });
      executor = { stage: "executor", status: "unknown", summary: `Waiting for ${executionHost.hostName}, which is ${executionHost.state}`, evidence };
    } else {
      executor = { stage: "executor", status: "pending", summary: `${executionHost.hostName} is online but reports no turn yet`, evidence };
    }
  } else if (lastUser?.deliveryStatus === "interrupted" || reply?.deliveryStatus === "interrupted") {
    const message = reply?.deliveryStatus === "interrupted" ? reply : lastUser!;
    const evidence = threadID ? [messageEvidence(threadID, message, "Turn was stopped before it finished")] : [];
    findings.push({ code: "turn-interrupted", stage: "executor", summary: "The executor's turn was stopped before it finished", evidence });
    executor = { stage: "executor", status: "failed", summary: "Turn stopped before it finished", evidence };
  } else if (["queued", "canceled", "failed", "completed"].includes(run.status)) {
    executor = { stage: "executor", status: "not-applicable", summary: "No host reports a turn for this run", evidence: [] };
  } else {
    executor = { stage: "executor", status: "unknown", summary: threadID ? "No host reports a turn for this run's conversation" : "This run is not linked to a conversation, so no host presence can confirm its executor", evidence: [] };
  }

  // MARK: Tools
  let toolsStage: RunTraceStage;
  if (live) {
    const tools = toolFindings(live.turn, live.host, now);
    findings.push(...tools.findings);
    const evidence = tools.findings.flatMap((finding) => finding.evidence);
    toolsStage = tools.findings.length
      ? { stage: "tools", status: "warning", summary: tools.findings.map((finding) => finding.summary).join("; "), evidence }
      : {
        stage: "tools",
        status: tools.running.length ? "active" : "ok",
        summary: tools.running.length ? `${tools.running.at(-1)!.title ?? "A tool"} is running` : `${tools.failed.length ? `${tools.failed.length} tool call(s) failed; ` : ""}no tool is running`,
        evidence: [presenceEvidence(live.host, live.turn.latestActivity ? `latest: ${live.turn.latestActivity.kind ?? "activity"} ${live.turn.latestActivity.title ?? ""} ${live.turn.latestActivity.status ?? ""}`.trim() : "no activity reported")],
      };
  } else {
    toolsStage = { stage: "tools", status: "not-applicable", summary: "Tool activity is only reported while a turn is live", evidence: [] };
  }

  // MARK: Result
  const resultEvidence: ActivityEvidence[] = [];
  if (reply && threadID) resultEvidence.push(messageEvidence(threadID, reply, `Executor replied (${reply.deliveryStatus ?? "unknown delivery"})${explicitFailure ? " with ORG2_RUN_OUTCOME: failed" : ""}`));
  if (replyComment) resultEvidence.push({ source: "run", ref: `run:${run.id}#comment:${replyComment.id}`, at: replyComment.createdAt, detail: "Reply recorded on the run" });
  const outcomeEvent = run.status === "completed" ? latestTransitionTo(run, "completed", start) : undefined;
  if (outcomeEvent) resultEvidence.push(runEvidence(run, outcomeEvent, `Completed${outcomeEvent.actor ? ` by ${outcomeEvent.actor}` : ""}`));
  if (failedEvent) resultEvidence.push(runEvidence(run, failedEvent, `Failed${failedEvent.actor ? ` by ${failedEvent.actor}` : ""}: ${run.failure ?? "no reason"}`));
  let result: RunTraceStage;
  if (run.status === "completed") {
    result = { stage: "result", status: "ok", summary: run.outcome?.summary ? `Completed: ${run.outcome.summary}` : "Completed", evidence: resultEvidence };
  } else if (hasResult && explicitFailure) {
    result = { stage: "result", status: "failed", summary: "The executor reported ORG2_RUN_OUTCOME: failed", evidence: resultEvidence };
  } else if (run.status === "failed" && !(hasResult && Number.isFinite(resultAt) && resultAt >= Date.parse(failedEvent?.at ?? ""))) {
    result = { stage: "result", status: "failed", summary: `Failed: ${run.failure ?? "no failure recorded"}`, evidence: resultEvidence };
  } else if (hasResult) {
    result = { stage: "result", status: "ok", summary: `The executor produced a result${Number.isFinite(resultAt) ? ` at ${iso(resultAt)}` : ""}`, evidence: resultEvidence };
  } else if (liveActive || run.status === "queued") {
    result = { stage: "result", status: "pending", summary: "No result yet", evidence: resultEvidence };
  } else {
    result = { stage: "result", status: run.status === "canceled" ? "not-applicable" : "unknown", summary: "No result was recorded", evidence: resultEvidence };
  }

  // MARK: Delivery
  const deliveryEvidence: ActivityEvidence[] = [];
  for (const post of pendingPosts) deliveryEvidence.push({ source: "inbox", ref: post.file, at: post.createdAt, detail: `Background post${post.authorLabel ? ` from ${post.authorLabel}` : ""} queued; not yet imported into the conversation` });
  let delivery: RunTraceStage;
  const replyFailed = reply?.deliveryStatus === "failed" || Boolean(str(reply?.sendFailure));
  if (replyFailed) {
    deliveryEvidence.push(messageEvidence(threadID!, reply!, `Reply delivery failed${str(reply?.sendFailure) ? `: ${reply!.sendFailure}` : ""}`));
    delivery = { stage: "delivery", status: "failed", summary: `The result was produced but not delivered${str(reply?.sendFailure) ? `: ${reply!.sendFailure}` : ""}`, evidence: deliveryEvidence };
  } else if (pendingPosts.length) {
    findings.push({ code: "delivery-uncertain", stage: "delivery", summary: "A result is queued for the conversation but has not been imported; queued is not delivered", evidence: deliveryEvidence });
    delivery = { stage: "delivery", status: "pending", summary: "Queued for the conversation; delivery unconfirmed", evidence: deliveryEvidence };
  } else if (hasResult && run.status === "running" && !liveActive && run.workflowId && !replyComment) {
    findings.push({ code: "result-unrecorded", stage: "delivery", summary: "The executor replied, but the reply was never recorded on the run, so the run still looks like it is running", evidence: resultEvidence });
    delivery = { stage: "delivery", status: "failed", summary: "Reply reached the conversation but not the run record", evidence: resultEvidence };
  } else if (reply && reply.deliveryStatus === "sent") {
    delivery = { stage: "delivery", status: "ok", summary: replyComment || run.status === "completed" ? "Delivered to the conversation and recorded on the run" : "Delivered to the conversation", evidence: resultEvidence };
  } else if (run.status === "completed" && !threadID) {
    delivery = { stage: "delivery", status: "ok", summary: "Outcome recorded on the run; no conversation is linked", evidence: resultEvidence };
  } else if (run.status === "completed") {
    delivery = { stage: "delivery", status: "unknown", summary: "Completed, but the linked conversation has no delivered reply for this attempt", evidence: resultEvidence };
  } else if (hasResult) {
    delivery = { stage: "delivery", status: "unknown", summary: "A result exists but its delivery state was not recorded", evidence: resultEvidence };
  } else {
    delivery = { stage: "delivery", status: "not-applicable", summary: "Nothing to deliver yet", evidence: [] };
  }

  // MARK: Verdict
  const stalePresence = Boolean(live && !liveActive) || Boolean(executionHost && !isHostLive(executionHost) && lastUser?.deliveryStatus === "sending" && !hasResult);
  let verdict: RunTraceVerdict;
  let code: string;
  let summary: string;
  let confidence: ActivityConfidence = "cached";
  let confidenceReason = "Derived from the run event log and committed conversation records";
  const resultAfterFailure = run.status === "failed" && hasResult && !explicitFailure
    && Number.isFinite(resultAt) && resultAt >= Date.parse(failedEvent?.at ?? "");
  const undelivered = delivery.status === "failed" || delivery.status === "pending";

  if ((run.status === "failed" || run.status === "canceled" || run.status === "completed") && liveActive) {
    verdict = "running";
    code = "executor-active-after-terminal";
    summary = `Marked ${run.status}, but ${live!.host.hostName} still reports a running turn; the executor did not stop`;
    confidence = "live";
    confidenceReason = `${live!.host.hostName} refreshed its presence ${describeAge(live!.host.lastSeenAgeSeconds)}`;
    findings.push({ code: "executor-active-after-terminal", stage: "executor", summary, evidence: executor.evidence });
  } else if (run.status === "canceled") {
    verdict = "canceled";
    code = "canceled";
    summary = canceledEvent?.actor ? `Canceled by ${canceledEvent.actor}` : "Canceled";
    if (stalePresence) { verdict = "unknown"; code = "canceled-executor-unconfirmed"; summary = `${summary}, but a stale host still lists its turn; cannot confirm the executor stopped`; confidence = "uncertain"; }
  } else if (run.status === "waiting-approval" || run.status === "blocked") {
    verdict = "waiting";
    code = run.status;
    summary = run.status === "blocked" ? `Blocked: ${run.blockedReason ?? "no reason recorded"}` : "Waiting for an approval decision";
  } else if (run.status === "completed") {
    verdict = undelivered ? "completed-undelivered" : "completed";
    code = undelivered ? "completed-undelivered" : "completed";
    summary = undelivered ? `Completed, but the result has not reached the conversation: ${delivery.summary}` : result.summary;
    if (delivery.status === "unknown" || delivery.status === "pending") {
      confidence = "uncertain";
      confidenceReason = delivery.status === "pending" ? "Queued for delivery; a queued post is not a delivered result" : "No delivered reply for this attempt is recorded";
    }
  } else if (resultAfterFailure) {
    verdict = "completed-undelivered";
    code = "result-after-failure";
    summary = `Marked failed (${run.failure ?? "no reason"}), but the executor produced a result afterwards; review it instead of retrying`;
    findings.push({ code: "result-after-failure", stage: "result", summary, evidence: resultEvidence });
  } else if (run.status === "failed") {
    if (stalePresence) {
      verdict = "unknown";
      code = "failed-executor-unconfirmed";
      summary = `Marked failed (${run.failure ?? "no reason"}), but a stale host still lists its turn; the executor may still be running`;
      confidence = "uncertain";
      confidenceReason = live ? live.host.stateReason : "Executor presence is stale";
    } else {
      verdict = "failed";
      code = executor.status === "failed" ? "turn-interrupted" : "failed";
      summary = `Failed at ${executor.status === "failed" ? "executor" : "result"}: ${run.failure ?? "no failure recorded"}`;
    }
  } else if (liveActive) {
    verdict = "running";
    code = "turn-running";
    summary = `Running on ${live!.host.hostName}${toolsStage.status === "warning" ? ` — ${toolsStage.summary}` : toolsStage.status === "active" ? ` — ${toolsStage.summary}` : ""}`;
    confidence = "live";
    confidenceReason = `${live!.host.hostName} refreshed its presence ${describeAge(live!.host.lastSeenAgeSeconds)}`;
  } else if (stalePresence) {
    verdict = "unknown";
    code = "executor-unconfirmed";
    summary = executor.summary;
    confidence = "uncertain";
    confidenceReason = live ? live.host.stateReason : executionHost?.stateReason ?? "Executor presence is stale";
  } else if (run.status === "queued") {
    verdict = "queued";
    code = pendingSends.length ? "send-request-queued" : "queued";
    summary = dispatch.summary;
  } else if (hasResult && explicitFailure) {
    verdict = "failed";
    code = "failed-outcome-unrecorded";
    summary = "The executor reported failure, but the run record was not updated";
    findings.push({ code: "result-unrecorded", stage: "result", summary, evidence: resultEvidence });
  } else if (delivery.status === "failed" || delivery.status === "pending") {
    verdict = "completed-undelivered";
    code = findings.some((finding) => finding.code === "result-unrecorded") ? "result-unrecorded" : "delivery-incomplete";
    summary = `The executor finished, but ${delivery.summary.charAt(0).toLowerCase()}${delivery.summary.slice(1)}; the run is not complete until the result is reviewed and recorded`;
    if (delivery.status === "pending") confidence = "uncertain";
  } else if (executor.status === "pending") {
    const accepted = openClawDateMilliseconds(userProvenance.acceptedAt as number | string | undefined ?? Number.NaN);
    const recent = Number.isFinite(accepted) && ageSeconds(now, accepted) <= RUN_TRACE_HANDOFF_GRACE_SECONDS;
    verdict = recent ? "queued" : "unknown";
    code = recent ? "handoff-pending" : "turn-not-reported";
    summary = recent ? `Handed to ${executionHost?.hostName ?? "the executor"}; waiting for it to accept the turn` : `${executor.summary}; the turn may have been dropped`;
    confidence = "uncertain";
    confidenceReason = "The executing host has not reported this turn";
  } else if (hasResult) {
    verdict = "unknown";
    code = "executor-idle";
    summary = `No executor is working; the latest turn ended${Number.isFinite(resultAt) ? ` at ${iso(resultAt)}` : ""} and the run is still open. Continue it or close it explicitly`;
    confidence = "uncertain";
    confidenceReason = "An open run without a live turn may be finished or abandoned";
  } else if (executor.status === "failed") {
    verdict = "failed";
    code = "turn-interrupted";
    summary = "The turn was stopped before it produced a result, but the run is still marked running";
  } else if (Number.isFinite(lastEventMs) && ageSeconds(now, lastEventMs) <= RUN_TRACE_RECENT_EVENT_SECONDS) {
    verdict = "running";
    code = "running-recent-event";
    summary = `Marked running; last run event ${describeAge(ageSeconds(now, lastEventMs))}, but no live presence confirms the executor`;
    confidenceReason = "Recent run event; no host presence links this run to a turn";
  } else {
    verdict = "unknown";
    code = "silent";
    summary = `Marked running, but no host reports it and the last run event was ${Number.isFinite(lastEventMs) ? describeAge(ageSeconds(now, lastEventMs)) : "never"}`;
    confidence = "uncertain";
    confidenceReason = "The executor may have stopped without recording a transition";
    findings.push({ code: "silent-run", stage: "executor", summary, evidence: [] });
  }
  if (stalePresence && confidence !== "live") confidence = "uncertain";

  return {
    schema: RUN_TRACE_SCHEMA,
    generatedAt: now.toISOString(),
    corpus: corpusRoot,
    run: {
      id: run.id,
      title: run.title?.trim() || run.goal,
      status: run.status,
      ...(run.workflowId ? { workflowId: run.workflowId } : {}),
      ...(threadID ? { threadId: threadID } : {}),
    },
    verdict,
    reason: { code, summary },
    confidence,
    confidenceReason,
    stages: [dispatch, executor, toolsStage, result, delivery],
    findings,
    retry: assessRetry(verdict, code, run),
  };
}

/** Whether re-queuing could execute work that is still active or already produced. */
export function assessRetry(verdict: RunTraceVerdict, code: string, run: Pick<AgentRun, "id" | "status">): RunTraceRetry {
  switch (verdict) {
    case "failed":
      return { safe: true, recommendation: "retry", reason: "The attempt failed and no executor reports it; retrying starts one new attempt" };
    case "canceled":
      return { safe: true, recommendation: "retry", reason: "The attempt was canceled and no executor reports it" };
    case "running":
      return { safe: false, recommendation: "wait", reason: code === "executor-active-after-terminal" ? "An executor is still running this run; retrying would run the work twice. Stop that turn first" : "The run is still executing; retrying would run the work twice" };
    case "queued":
      return { safe: false, recommendation: "wait", reason: "The run is already queued; another retry would duplicate the request" };
    case "waiting":
      return { safe: false, recommendation: "decide", reason: `Resolve the pending ${run.status === "blocked" ? "question" : "approval"} instead of retrying` };
    case "completed-undelivered":
      return { safe: false, recommendation: code === "result-unrecorded" || code === "result-after-failure" ? "record-result" : "redeliver", reason: "The executor already produced a result; review and record or redeliver it instead of running the work again" };
    case "completed":
      return { safe: false, recommendation: "none", reason: "The run is complete" };
    case "unknown":
    default:
      // A run left "running" by an executor that stopped is not retried
      // directly: the person who confirms it stopped records that first.
      if (run.status === "running") {
        return {
          safe: false,
          recommendation: "inspect",
          reason: `The executor's state cannot be confirmed; it may still be running. Once you confirm it stopped, record that on the run: \`celorga run block ${run.id} --reason TEXT\` to continue it with direction, or \`celorga run fail ${run.id} --reason TEXT\` to retry it`,
        };
      }
      return { safe: false, recommendation: "inspect", reason: "The executor's state cannot be confirmed; it may still be running. Confirm it stopped before retrying" };
  }
}

export function renderRunTraceText(trace: RunTrace): string {
  const lines = [
    `run ${trace.run.id}  ${trace.run.title}`,
    `  verdict: ${trace.verdict} (${trace.reason.code}) — ${trace.reason.summary}`,
    `  record status: ${trace.run.status}${trace.run.threadId ? `; thread ${trace.run.threadId}` : ""}${trace.run.workflowId ? `; workflow ${trace.run.workflowId}` : ""}`,
    `  confidence: ${trace.confidence} — ${trace.confidenceReason}`,
  ];
  for (const stage of trace.stages) {
    lines.push(`  ${stage.stage.padEnd(8)} ${stage.status.padEnd(14)} ${stage.summary}`);
    for (const item of stage.evidence) lines.push(`             ${item.source} ${item.ref}${item.at ? ` @ ${item.at}` : ""}: ${item.detail}`);
  }
  for (const finding of trace.findings) lines.push(`  finding ${finding.code}: ${finding.summary}`);
  lines.push(`  retry: ${trace.retry.safe ? "safe" : "unsafe"} (${trace.retry.recommendation}) — ${trace.retry.reason}`);
  return lines.join("\n");
}
