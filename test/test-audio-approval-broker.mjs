#!/usr/bin/env node
// Regression coverage for the feature-gated walkie-talkie audio approval broker.
// Hardware behaviour (locked iPhone, Push to Talk, AirPods routing) is NOT tested here.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  createAgentRun,
  decideAgentRunApproval,
  loadAgentRunSnapshot,
  requestAgentRunApproval,
  saveAgentRun,
  transitionAgentRun,
} from "../dist/agentRun.js";
import {
  AUDIO_APPROVAL_SNOOZE_MS,
  applyAudioSpokenReplyToCorpus,
  audioBrokerStatePath,
  audioApprovalsEnabled,
  createAudioBrokerState,
  handleAudioRouteChange,
  markAudioPrompt,
  parseAudioSpokenReply,
  pendingAudioTargets,
  planAudioPlayback,
  readAudioBrokerState,
  resolveAudioSpokenReply,
  selectActiveAudioPrompt,
  setAudioQuietMode,
  writeAudioBrokerState,
} from "../dist/audioApprovalBroker.js";

const ON = { CELORGA_AUDIO_APPROVALS: "1" };
const OFF = {};
const T0 = "2026-10-09T10:00:00.000Z";
const T1 = "2026-10-09T10:01:00.000Z";
const T2 = "2026-10-09T10:02:00.000Z";

function waitingRun(id, approvalId, requestedAt, extra = {}) {
  let run = createAgentRun({ id, title: `Run ${id}`, goal: `Goal ${id}`, now: requestedAt });
  run = transitionAgentRun(run, "running", { actor: "OpenCode", now: requestedAt });
  run = requestAgentRunApproval(run, {
    id: approvalId,
    title: `Approve ${id}`,
    action: `send reply for ${id}`,
    riskClass: "external-action",
    requestedAt,
    ...extra,
  }, "OpenCode");
  return run;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-audio-approval-"));

// 1. Feature gate: off by default, and the corpus entry point touches nothing when off.
assert.equal(audioApprovalsEnabled(OFF), false);
assert.equal(audioApprovalsEnabled({ CELORGA_AUDIO_APPROVALS: "true" }), false, "only the explicit 1 enables the prototype");
assert.equal(audioApprovalsEnabled(ON), true);
{
  const root = path.join(tmp, "gate-off");
  fs.mkdirSync(root, { recursive: true });
  const outcome = applyAudioSpokenReplyToCorpus(root, ["missing-run"], {
    transcript: "yes", promptId: "p", target: { runId: "missing-run", approvalId: "a", fingerprint: "sha256:x" }, initiated: true, clientId: "avi-headset", nowIso: T0,
  }, { env: OFF });
  assert.equal(outcome.status, "disabled");
  assert.equal(fs.existsSync(path.join(root, ".celorga")), false, "disabled gate must not create broker state");
}

// 2. Intent parsing: only whole, unambiguous phrases map; mixed or partial speech is unclear.
assert.equal(parseAudioSpokenReply("Yes."), "approve");
assert.equal(parseAudioSpokenReply("No"), "reject");
assert.equal(parseAudioSpokenReply("Why?"), "why");
assert.equal(parseAudioSpokenReply("Read it to me"), "read");
assert.equal(parseAudioSpokenReply("Not now"), "snooze");
assert.equal(parseAudioSpokenReply("yes no"), "unclear", "mixed speech authorizes nothing");
assert.equal(parseAudioSpokenReply("yes, wait, no"), "unclear");
assert.equal(parseAudioSpokenReply("yes please send it"), "unclear", "unrecognised phrasing is not authorization");
assert.equal(parseAudioSpokenReply(""), "unclear", "silence is not authorization");

// 3. One shared broker, one active exact approval; oldest pending first; no bare-yes to the next queue item.
const runA = waitingRun("run-a", "appr-a", T0);
const runB = waitingRun("run-b", "appr-b", T1);
assert.deepEqual(pendingAudioTargets([runB, runA]).map((t) => t.runId), ["run-a", "run-b"]);
{
  const urgentB = { ...runB, approvals: runB.approvals.map((approval) => ({ ...approval, priority: "urgent" })) };
  assert.deepEqual(pendingAudioTargets([runA, urgentB]).map((t) => t.runId), ["run-b", "run-a"], "explicit urgency outranks age");
}
let state = selectActiveAudioPrompt(createAudioBrokerState(), [runA, runB], T1);
assert.equal(state.active.target.runId, "run-a");
const firstPrompt = state.active.promptId;
// A later arrival must not displace the active prompt.
const runC = waitingRun("run-c", "appr-c", T2);
state = selectActiveAudioPrompt(state, [runA, runB, runC], T2);
assert.equal(state.active.promptId, firstPrompt, "active prompt is kept while its exact target is pending");

// 4. Playback is headset-only and held for quiet/calls; ordinary media is interruptible.
assert.deepEqual(planAudioPlayback(state, { route: "headset" }), { action: "play", reason: "headset-ready" });
assert.deepEqual(planAudioPlayback(state, { route: "speaker" }), { action: "hold", reason: "no-headset" }, "no speaker fallback");
assert.deepEqual(planAudioPlayback(state, { route: "none" }), { action: "hold", reason: "no-headset" });
assert.deepEqual(planAudioPlayback(state, { route: "speaker" }, { allowSpeaker: true }), { action: "play", reason: "speaker-allowed" }, "speaker only with the explicit opt-in");
assert.deepEqual(planAudioPlayback(state, { route: "speaker", headsetConnecting: true }, { allowSpeaker: true }), { action: "hold", reason: "no-headset" }, "a connecting headset is waited for");
assert.deepEqual(planAudioPlayback(state, { route: "none" }, { allowSpeaker: true }), { action: "hold", reason: "no-headset" });
assert.deepEqual(planAudioPlayback(state, { route: "speaker", inCall: true }, { allowSpeaker: true }), { action: "hold", reason: "call-active" });
assert.deepEqual(planAudioPlayback(state, { route: "headset", inCall: true }), { action: "hold", reason: "call-active" });
assert.deepEqual(planAudioPlayback(state, { route: "headset", mediaPlaying: true }), { action: "play", reason: "headset-ready" }, "joined approvals interrupt podcasts and music");
assert.deepEqual(planAudioPlayback(state, { route: "speaker", mediaPlaying: true }), { action: "hold", reason: "no-headset" });
assert.deepEqual(planAudioPlayback(state, { route: "headset", mediaPlaying: true, inCall: true }), { action: "hold", reason: "call-active" });
const quiet = setAudioQuietMode(state, true);
assert.deepEqual(planAudioPlayback(quiet, { route: "headset" }), { action: "hold", reason: "quiet" });
// Route loss mid-prompt retains the prompt as queued rather than moving it to another output.
const playing = markAudioPrompt(state, firstPrompt, "played");
const lost = handleAudioRouteChange(playing, { route: "speaker" });
assert.equal(lost.active.stage, "queued");
assert.equal(lost.active.promptId, firstPrompt, "route loss keeps the same retained prompt");
{
  // A prompt interrupted by headset loss must be heard again before any reply binds to it.
  const afterLoss = resolveAudioSpokenReply(lost, [runA, runB], {
    transcript: "yes", promptId: firstPrompt, target: lost.active.target, initiated: true, clientId: "avi-headset", nowIso: T2,
  });
  assert.deepEqual(afterLoss.outcome, { status: "ignored", reason: "prompt-not-heard" });
  const neverPlayed = resolveAudioSpokenReply(state, [runA, runB], {
    transcript: "yes", promptId: firstPrompt, target: state.active.target, initiated: true, clientId: "avi-headset", nowIso: T2,
  });
  assert.deepEqual(neverPlayed.outcome, { status: "ignored", reason: "prompt-not-heard" }, "a queued prompt cannot be answered");
  assert.equal(runA.approvals[0].status, "pending");
}

// 5. Passive (non-initiated) audio never decides.
{
  const result = resolveAudioSpokenReply(state, [runA, runB], {
    transcript: "yes", promptId: firstPrompt, target: state.active.target, initiated: false, clientId: "avi-headset", nowIso: T2,
  });
  assert.deepEqual(result.outcome, { status: "ignored", reason: "not-initiated" });
  assert.equal(runA.approvals[0].status, "pending");
}

// 6. Corpus round trip through the existing approval gate, with idempotent receipts.
const root = path.join(tmp, "corpus");
fs.mkdirSync(root, { recursive: true });
saveAgentRun(root, runA, { expectedRevision: null });
saveAgentRun(root, runB, { expectedRevision: null });
const stateFile = audioBrokerStatePath(root);
assert.equal(stateFile.includes(`${path.sep}audio-approvals${path.sep}broker-state.json`), true);
{
  const selected = selectActiveAudioPrompt(createAudioBrokerState(), [runA, runB], T1);
  writeAudioBrokerState(root, markAudioPrompt(selected, selected.active.promptId, "played"));
}
const active = readAudioBrokerState(root).active;
assert.equal(active.target.runId, "run-a");
const reply = (transcript, extra = {}) => applyAudioSpokenReplyToCorpus(root, ["run-a", "run-b"], {
  transcript, promptId: active.promptId, target: active.target, initiated: true, clientId: "avi-headset", nowIso: T2, ...extra,
}, { env: ON });

assert.deepEqual(reply("Why?").status, "info", "info questions do not decide");
assert.equal(loadAgentRunSnapshot(root, "run-a").run.approvals[0].status, "pending");
assert.equal(reply("yes maybe").status, "unclear");

const applied = reply("Yes");
assert.equal(applied.status, "applied");
assert.equal(applied.receipt.decision, "approved");
const afterApply = loadAgentRunSnapshot(root, "run-a").run;
assert.equal(afterApply.approvals[0].status, "approved");
assert.equal(afterApply.approvals[0].decidedBy, "avi-headset");
assert.equal(afterApply.approvals[0].receipt, `audio-prompt:${active.promptId}`);
assert.equal(afterApply.status, "running", "run resumes once its only boundary approval is decided");
const eventsAfterApply = afterApply.events.length;

// Replay of the same reply (duplicate delivery / retry) returns the original receipt and writes nothing.
const replay = reply("Yes");
assert.equal(replay.status, "duplicate");
assert.equal(loadAgentRunSnapshot(root, "run-a").run.events.length, eventsAfterApply, "replay must not add decision events");

// A conflicting later decision for the same prompt is refused.
assert.equal(reply("No").status, "rejected");
assert.equal(loadAgentRunSnapshot(root, "run-a").run.approvals[0].status, "approved");

// After the decision, the same prompt is stale: the next queued item is never approved by a bare yes.
const stale = reply("Yes");
assert.equal(stale.status, "duplicate", "already-recorded prompt returns its receipt, not a new decision");
const persisted = readAudioBrokerState(root);
const next = selectActiveAudioPrompt(persisted, [loadAgentRunSnapshot(root, "run-a").run, loadAgentRunSnapshot(root, "run-b").run], T2);
assert.equal(next.active.target.runId, "run-b", "next prompt is selected only after the decision is durable");
assert.notEqual(next.active.promptId, active.promptId);
assert.equal(fs.existsSync(stateFile), true);

// 7. Stale and mismatched targets are rejected without changing the run.
{
  const runBState = loadAgentRunSnapshot(root, "run-b").run;
  const selectedB = selectActiveAudioPrompt(createAudioBrokerState(), [runBState], T2);
  const current = markAudioPrompt(selectedB, selectedB.active.promptId, "played");
  const wrongFingerprint = { ...current.active.target, fingerprint: "sha256:stale" };
  const r1 = resolveAudioSpokenReply(current, [runBState], {
    transcript: "yes", promptId: current.active.promptId, target: wrongFingerprint, initiated: true, clientId: "avi-headset", nowIso: T2,
  });
  assert.equal(r1.outcome.status, "rejected");
  assert.equal(r1.outcome.receipt.reason, "stale-prompt", "target not equal to the active prompt is stale");

  const r2 = resolveAudioSpokenReply(current, [runBState], {
    transcript: "yes", promptId: "prompt-forged", target: current.active.target, initiated: true, clientId: "avi-headset", nowIso: T2,
  });
  assert.equal(r2.outcome.receipt.reason, "stale-prompt");

  // Approval already decided elsewhere (another client or the desktop app) between prompt and reply.
  const decidedElsewhere = decideAgentRunApproval(runBState, current.active.target.approvalId, "rejected", { actor: "avi-desktop", now: T2 });
  const r3 = resolveAudioSpokenReply(current, [decidedElsewhere], {
    transcript: "yes", promptId: current.active.promptId, target: current.active.target, initiated: true, clientId: "avi-headset", nowIso: T2,
  });
  assert.equal(r3.outcome.status, "rejected");
  assert.equal(r3.outcome.receipt.reason, "run-not-waiting", "a run no longer waiting on approval refuses");
  assert.equal(decidedElsewhere.approvals[0].status, "rejected");
}

// 8. The existing gate still decides who may answer: a requestedFrom approval refuses other clients.
{
  const gated = waitingRun("run-gated", "appr-gated", T0, { requestedFrom: "avi" });
  const selGated = selectActiveAudioPrompt(createAudioBrokerState(), [gated], T1);
  const sel = markAudioPrompt(selGated, selGated.active.promptId, "played");
  const r = resolveAudioSpokenReply(sel, [gated], {
    transcript: "yes", promptId: sel.active.promptId, target: sel.active.target, initiated: true, clientId: "someone-else", nowIso: T2,
  });
  assert.equal(r.outcome.status, "rejected");
  assert.match(r.outcome.receipt.reason, /gate-refused/);
  assert.equal(gated.approvals[0].status, "pending", "a refused reply leaves the approval pending");
}

// 9. Snooze keeps the approval pending and returns it after the window.
{
  const snoozeRun = waitingRun("run-snooze", "appr-snooze", T0);
  const selSnooze = selectActiveAudioPrompt(createAudioBrokerState(), [snoozeRun], T1);
  const sel = markAudioPrompt(selSnooze, selSnooze.active.promptId, "played");
  const r = resolveAudioSpokenReply(sel, [snoozeRun], {
    transcript: "Later", promptId: sel.active.promptId, target: sel.active.target, initiated: true, clientId: "avi-headset", nowIso: T1,
  });
  assert.equal(r.outcome.status, "snoozed");
  assert.equal(r.state.active, undefined);
  const during = selectActiveAudioPrompt(r.state, [snoozeRun], T2);
  assert.equal(during.active, undefined, "snoozed approval is not re-prompted");
  const later = new Date(Date.parse(T1) + AUDIO_APPROVAL_SNOOZE_MS + 1000).toISOString();
  assert.equal(selectActiveAudioPrompt(r.state, [snoozeRun], later).active.target.approvalId, "appr-snooze");
  assert.equal(snoozeRun.approvals[0].status, "pending");
}

// 10. Quiet mode is stored but never decides, and gating is per-run boundary only.
assert.equal(setAudioQuietMode(createAudioBrokerState(), true).quiet, true);

fs.rmSync(tmp, { recursive: true, force: true });
console.log("audio approval broker tests passed");
