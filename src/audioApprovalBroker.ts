/**
 * Feature-gated walkie-talkie audio approval broker (prototype).
 *
 * The broker never stores decisions of its own. It selects one exact pending
 * approval from durable agent runs, plans a headset-only spoken prompt, and
 * turns an *initiated* spoken reply into the existing
 * `decideAgentRunApproval` call. The existing approval gate (status, exact
 * fingerprint, requestedFrom/role) remains the authority.
 *
 * Deliberately conservative:
 * - Disabled unless CELORGA_AUDIO_APPROVALS=1.
 * - Playback only on an active headset route; no speaker fallback; held during
 *   calls and music; quiet mode holds everything.
 * - Silence, unclear speech, passive (non-initiated) audio, and replies that
 *   name a stale prompt never authorize anything.
 * - Decisions are idempotent per prompt: a replayed reply returns the original
 *   receipt instead of applying again.
 *
 * Physical playback, Push to Talk capture, and locked-device behaviour are not
 * implemented here; the native client reports those events into this module.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { stateDir } from "./brandNames.js";
import {
  agentRunApprovalFingerprint,
  currentAgentRunApprovalBoundary,
  decideAgentRunApproval,
  loadAgentRunSnapshot,
  saveAgentRun,
  type AgentRun,
  type AgentRunApprovalDecision,
} from "./agentRun.js";

export const AUDIO_APPROVALS_FLAG = "CELORGA_AUDIO_APPROVALS";
export const AUDIO_APPROVAL_SNOOZE_MS = 30 * 60 * 1000;

export type AudioRoute = "headset" | "speaker" | "none";
export type AudioStage = "queued" | "delivered" | "played" | "answered" | "executed";
export type AudioSpokenIntent = "approve" | "reject" | "why" | "read" | "snooze" | "unclear";

export interface AudioApprovalTarget {
  runId: string;
  approvalId: string;
  fingerprint: string;
}

export interface AudioActivePrompt {
  promptId: string;
  target: AudioApprovalTarget;
  stage: AudioStage;
  promptedAt: string;
}

export interface AudioReceipt {
  promptId: string;
  decision: AgentRunApprovalDecision;
  status: "applied" | "rejected";
  reason?: string;
  target: AudioApprovalTarget;
  at: string;
}

export interface AudioBrokerState {
  schema: "celorga:audio-approval-broker:v1";
  seq: number;
  quiet: boolean;
  active?: AudioActivePrompt;
  snoozed: Array<AudioApprovalTarget & { until: string }>;
  receipts: AudioReceipt[];
}

export interface AudioRouteSnapshot {
  route: AudioRoute;
  inCall?: boolean;
  mediaPlaying?: boolean;
}

export type AudioPlaybackPlan =
  | { action: "play"; reason: "headset-ready" }
  | { action: "hold"; reason: "quiet" | "no-headset" | "call-active" | "media-active" };

export type AudioReplyOutcome =
  | { status: "disabled" }
  | { status: "ignored"; reason: "not-initiated" | "no-active-prompt" }
  | { status: "unclear" }
  | { status: "info"; intent: "why" | "read" }
  | { status: "snoozed"; until: string }
  | { status: "applied"; receipt: AudioReceipt; run: AgentRun }
  | { status: "duplicate"; receipt: AudioReceipt }
  | { status: "rejected"; receipt: AudioReceipt };

export function audioApprovalsEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[AUDIO_APPROVALS_FLAG] === "1";
}

export function createAudioBrokerState(): AudioBrokerState {
  return { schema: "celorga:audio-approval-broker:v1", seq: 0, quiet: false, snoozed: [], receipts: [] };
}

function targetKey(target: AudioApprovalTarget): string {
  return `${target.runId}\u0000${target.approvalId}\u0000${target.fingerprint}`;
}

function sameTarget(a: AudioApprovalTarget, b: AudioApprovalTarget): boolean {
  return targetKey(a) === targetKey(b);
}

/** Pending approvals on the current approval boundary of waiting runs, oldest first. */
export function pendingAudioTargets(runs: AgentRun[]): Array<AudioApprovalTarget & { requestedAt: string }> {
  const targets: Array<AudioApprovalTarget & { requestedAt: string }> = [];
  for (const run of runs) {
    if (run.status !== "waiting-approval") continue;
    for (const approval of currentAgentRunApprovalBoundary(run)) {
      if (approval.status !== "pending") continue;
      if (approval.fingerprint !== agentRunApprovalFingerprint(approval)) continue;
      targets.push({ runId: run.id, approvalId: approval.id, fingerprint: approval.fingerprint, requestedAt: approval.requestedAt });
    }
  }
  return targets.sort((a, b) =>
    a.requestedAt.localeCompare(b.requestedAt)
    || a.runId.localeCompare(b.runId)
    || a.approvalId.localeCompare(b.approvalId));
}

/**
 * Keep the current prompt while its exact target is still pending; otherwise
 * select the oldest pending, non-snoozed target. Never more than one active.
 */
export function selectActiveAudioPrompt(state: AudioBrokerState, runs: AgentRun[], nowIso: string): AudioBrokerState {
  const now = Date.parse(nowIso);
  const snoozed = state.snoozed.filter((entry) => Date.parse(entry.until) > now);
  const candidates = pendingAudioTargets(runs).filter((target) =>
    !snoozed.some((entry) => sameTarget(entry, target)));
  if (state.active && candidates.some((target) => sameTarget(target, state.active!.target))) {
    return { ...state, snoozed };
  }
  const next = candidates[0];
  if (!next) return { ...state, snoozed, active: undefined };
  const seq = state.seq + 1;
  const promptId = `prompt-${seq}-${crypto.createHash("sha256").update(targetKey(next)).digest("hex").slice(0, 12)}`;
  return {
    ...state,
    seq,
    snoozed,
    active: {
      promptId,
      target: { runId: next.runId, approvalId: next.approvalId, fingerprint: next.fingerprint },
      stage: "queued",
      promptedAt: nowIso,
    },
  };
}

/** Headset-only playback gate, evaluated again at the moment of playback. */
export function planAudioPlayback(state: AudioBrokerState, route: AudioRouteSnapshot): AudioPlaybackPlan {
  if (state.quiet) return { action: "hold", reason: "quiet" };
  if (route.route !== "headset") return { action: "hold", reason: "no-headset" };
  if (route.inCall) return { action: "hold", reason: "call-active" };
  if (route.mediaPlaying) return { action: "hold", reason: "media-active" };
  return { action: "play", reason: "headset-ready" };
}

/** Route lost mid-prompt: the prompt returns to queued and is retained, never moved to a speaker. */
export function handleAudioRouteChange(state: AudioBrokerState, route: AudioRouteSnapshot): AudioBrokerState {
  if (!state.active || route.route === "headset") return state;
  return { ...state, active: { ...state.active, stage: "queued" } };
}

export function markAudioPrompt(state: AudioBrokerState, promptId: string, stage: Exclude<AudioStage, "queued" | "answered" | "executed">): AudioBrokerState {
  if (!state.active || state.active.promptId !== promptId) return state;
  return { ...state, active: { ...state.active, stage } };
}

export function setAudioQuietMode(state: AudioBrokerState, quiet: boolean): AudioBrokerState {
  return { ...state, quiet };
}

/**
 * Normalise a whole utterance. Only whole, unambiguous phrases map to an
 * intent; mixed or partial speech is "unclear" and authorizes nothing.
 */
export function parseAudioSpokenReply(transcript: string): AudioSpokenIntent {
  const normalized = String(transcript || "")
    .toLowerCase()
    .replace(/[^a-z' ]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (["yes", "yeah", "yep", "approve"].includes(normalized)) return "approve";
  if (["no", "nope", "reject", "deny"].includes(normalized)) return "reject";
  if (normalized === "why") return "why";
  if (["read it to me", "read it", "read to me"].includes(normalized)) return "read";
  if (["later", "not now"].includes(normalized)) return "snooze";
  return "unclear";
}

export interface AudioSpokenReplyInput {
  transcript: string;
  promptId: string;
  target: AudioApprovalTarget;
  /** True only for a reply the user explicitly initiated (Push to Talk press). */
  initiated: boolean;
  clientId: string;
  nowIso: string;
}

export interface AudioReplyDecision {
  state: AudioBrokerState;
  outcome: AudioReplyOutcome;
  /** Run to persist when outcome.status is "applied". */
  run?: AgentRun;
}

/**
 * Decide what one spoken reply does. Pure: it returns the updated run without
 * persisting it. Use applyAudioSpokenReplyToCorpus to persist with revision guards.
 */
export function resolveAudioSpokenReply(state: AudioBrokerState, runs: AgentRun[], input: AudioSpokenReplyInput): AudioReplyDecision {
  if (!input.initiated) return { state, outcome: { status: "ignored", reason: "not-initiated" } };
  if (!state.active) return { state, outcome: { status: "ignored", reason: "no-active-prompt" } };

  const intent = parseAudioSpokenReply(input.transcript);
  if (intent === "unclear") return { state, outcome: { status: "unclear" } };
  if (intent === "why" || intent === "read") return { state, outcome: { status: "info", intent } };
  if (intent === "snooze") {
    const until = new Date(Date.parse(input.nowIso) + AUDIO_APPROVAL_SNOOZE_MS).toISOString();
    const snoozed = [...state.snoozed.filter((entry) => !sameTarget(entry, state.active!.target)), { ...state.active.target, until }];
    return { state: { ...state, snoozed, active: undefined }, outcome: { status: "snoozed", until } };
  }

  const decision: AgentRunApprovalDecision = intent === "approve" ? "approved" : "rejected";
  const prior = state.receipts.find((receipt) => receipt.promptId === input.promptId);
  if (prior) {
    if (prior.decision === decision) return { state, outcome: { status: "duplicate", receipt: prior } };
    return { state, outcome: { status: "rejected", receipt: prior } };
  }

  const reject = (reason: string): AudioReplyDecision => {
    const receipt: AudioReceipt = { promptId: input.promptId, decision, status: "rejected", reason, target: input.target, at: input.nowIso };
    return { state: { ...state, receipts: [...state.receipts, receipt] }, outcome: { status: "rejected", receipt } };
  };

  if (input.promptId !== state.active.promptId || !sameTarget(input.target, state.active.target)) return reject("stale-prompt");

  const run = runs.find((candidate) => candidate.id === input.target.runId);
  if (!run) return reject("run-not-found");
  if (run.status !== "waiting-approval") return reject("run-not-waiting");
  const approval = run.approvals.find((candidate) => candidate.id === input.target.approvalId);
  if (!approval || approval.status !== "pending") return reject("approval-not-pending");
  if (approval.fingerprint !== input.target.fingerprint || agentRunApprovalFingerprint(approval) !== input.target.fingerprint) return reject("fingerprint-mismatch");

  let updated: AgentRun;
  try {
    updated = decideAgentRunApproval(run, input.target.approvalId, decision, {
      actor: input.clientId,
      fingerprint: input.target.fingerprint,
      receipt: `audio-prompt:${input.promptId}`,
      now: input.nowIso,
    });
  } catch (error) {
    return reject(`gate-refused: ${(error as Error).message}`);
  }
  const receipt: AudioReceipt = { promptId: input.promptId, decision, status: "applied", target: input.target, at: input.nowIso };
  return {
    state: {
      ...state,
      active: { ...state.active, stage: "executed" },
      receipts: [...state.receipts, receipt],
    },
    outcome: { status: "applied", receipt, run: updated },
    run: updated,
  };
}

/**
 * Broker state lives under the same state directory resolver as agent runs, so
 * writing it cannot change which directory run files are read from.
 */
export function audioBrokerStatePath(corpusRoot: string): string {
  return stateDir(path.resolve(corpusRoot), "audio-approvals", "broker-state.json");
}

export function readAudioBrokerState(corpusRoot: string): AudioBrokerState {
  const file = audioBrokerStatePath(corpusRoot);
  if (!fs.existsSync(file)) return createAudioBrokerState();
  return JSON.parse(fs.readFileSync(file, "utf8")) as AudioBrokerState;
}

export function writeAudioBrokerState(corpusRoot: string, state: AudioBrokerState): void {
  const file = audioBrokerStatePath(corpusRoot);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, file);
}

/**
 * Feature-gated end-to-end entry point for one spoken reply against a corpus.
 * Loads the run with its revision, applies the gate, persists with the revision
 * guard, and records the receipt. Returns "disabled" without touching state
 * when the flag is off.
 */
export function applyAudioSpokenReplyToCorpus(
  corpusRoot: string,
  runIds: string[],
  input: AudioSpokenReplyInput,
  options: { env?: NodeJS.ProcessEnv } = {},
): AudioReplyOutcome {
  if (!audioApprovalsEnabled(options.env)) return { status: "disabled" };
  let state = readAudioBrokerState(corpusRoot);
  const snapshots = runIds.map((id) => loadAgentRunSnapshot(corpusRoot, id));
  const runs = snapshots.map((snapshot) => snapshot.run);
  const result = resolveAudioSpokenReply(state, runs, input);
  if (result.outcome.status === "applied" && result.run) {
    const snapshot = snapshots.find((candidate) => candidate.run.id === result.run!.id)!;
    try {
      saveAgentRun(corpusRoot, result.run, { expectedRevision: snapshot.revision });
    } catch (error) {
      // The run changed after it was read: keep the prompt active, record nothing, and refuse.
      return { status: "rejected", receipt: { promptId: input.promptId, decision: result.outcome.receipt.decision, status: "rejected", reason: `run-changed-during-apply: ${(error as Error).message}`, target: input.target, at: input.nowIso } };
    }
  }
  state = result.state;
  writeAudioBrokerState(corpusRoot, state);
  return result.outcome;
}
