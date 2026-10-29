#!/usr/bin/env node
// Run failure explanations trace dispatch -> executor -> tools -> result ->
// delivery from structured records in a synthetic corpus. The trace must never
// report work as completed without a completed run, must name a result that
// exists but was not delivered, must stay "unknown" when host evidence is
// stale, and `celorga run retry` must refuse retries that could run the same
// work twice.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { appleReferenceDateSeconds } from "../dist/openClawThreadState.js";
import { addAgentRunComment, createAgentRun, loadAgentRun, saveAgentRun, transitionAgentRun } from "../dist/agentRun.js";
import { explainActivity } from "../dist/activityState.js";
import { traceRun } from "../dist/runTrace.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist", "cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-run-trace-"));
const now = new Date();
const minutesAgo = (minutes) => new Date(now.getTime() - minutes * 60_000);
const celorga = (...args) => spawnSync(process.execPath, [cli, ...args, "--dir", root], { encoding: "utf8" });
const thread = (n) => `${String(n).repeat(8)}-0000-4000-8000-00000000000${n}`;

try {
  fs.writeFileSync(path.join(root, "org2.json"), `${JSON.stringify({ automationHostRef: "server-a" }, null, 2)}\n`);
  const liveDir = path.join(root, ".org2", "openclaw-chat.store", "live");
  fs.mkdirSync(liveDir, { recursive: true });
  const writeHost = (writerID, record) => fs.writeFileSync(path.join(liveDir, `${writerID}.json`), JSON.stringify({
    schema: "org2:ai-chat-live-host:v1", writerID, isOnline: true, enabledDestinationIDs: ["builtin.agent"], turns: [], ...record,
  }));
  const turn = (threadID, activities = []) => ({ threadID, destinationID: "builtin.agent", destinationName: "Agent", startedAt: minutesAgo(20).toISOString(), activities });
  writeHost("w-a", {
    hostRef: "server-a", hostName: "Server A", hostKind: "server", updatedAt: minutesAgo(0.2).toISOString(),
    turns: [
      // A live turn with a slow tool and a shell error.
      turn(thread(1), [
        { id: "t1", kind: "tool", title: "ls *.missing", detail: "zsh: no matches found: *.missing", status: "failed", updatedAt: minutesAgo(12).toISOString() },
        { id: "t2", kind: "tool", title: "Running test suite", status: "running", updatedAt: minutesAgo(11).toISOString() },
      ]),
      // A run already marked failed whose executor is still working.
      turn(thread(2), [{ id: "t3", kind: "tool", title: "Running command", status: "running", updatedAt: minutesAgo(0.5).toISOString() }]),
      // Reported by a different host than the one it was dispatched to.
      turn(thread(7)),
    ],
  });
  // A host that stopped heartbeating while it still listed a turn.
  writeHost("w-b", { hostRef: "laptop-b", hostName: "Laptop B", hostKind: "desktop", updatedAt: minutesAgo(90).toISOString(), turns: [turn(thread(3))] });

  const message = (id, role, at, extra = {}) => ({ id, role, content: `${role} ${id}`, createdAt: appleReferenceDateSeconds(at), deliveryStatus: "sent", ...extra });
  const dispatched = (host, hostName) => ({ provenance: { executionHostRef: host, executionHostName: hostName, receivedByHostRef: host, acceptedAt: appleReferenceDateSeconds(minutesAgo(20)) } });
  const chat = (id, messages, extra = {}) => ({
    id, title: `Chat ${id.slice(0, 1)}`, createdAt: appleReferenceDateSeconds(minutesAgo(60)), updatedAt: appleReferenceDateSeconds(minutesAgo(1)),
    sessionKey: `agent:main:${id}`, messages, isPinned: false, isArchived: false, unreadMessageCount: 0, runtime: "codex", destinationID: "builtin.agent", ...extra,
  });
  fs.writeFileSync(path.join(root, ".org2", "openclaw-chat.json"), JSON.stringify({
    version: 6,
    selectedThreadID: null,
    threads: [
      chat(thread(1), [message("U1", "user", minutesAgo(20), { deliveryStatus: "sending", ...dispatched("server-a", "Server A") })], { storedHasUnresolvedLatestDelivery: true }),
      chat(thread(2), [message("U2", "user", minutesAgo(20), { deliveryStatus: "sending", ...dispatched("server-a", "Server A") })], { storedHasUnresolvedLatestDelivery: true }),
      chat(thread(3), [message("U3", "user", minutesAgo(95), { deliveryStatus: "sending", ...dispatched("laptop-b", "Laptop B") })], { storedHasUnresolvedLatestDelivery: true }),
      // Automation replied, but the scheduler never recorded the reply on the run.
      chat(thread(4), [message("U4", "user", minutesAgo(20), dispatched("server-a", "Server A")), message("A4", "assistant", minutesAgo(10))]),
      // Completed run whose reply failed to deliver.
      chat(thread(5), [message("U5", "user", minutesAgo(20), dispatched("server-a", "Server A")), message("A5", "assistant", minutesAgo(10), { deliveryStatus: "failed", sendFailure: "Destination rejected the reply" })], { storedLatestDeliveryNeedsAttention: true }),
      // Failed run whose executor produced a reply after the failure was recorded.
      chat(thread(6), [message("U6", "user", minutesAgo(20), dispatched("server-a", "Server A")), message("A6", "assistant", minutesAgo(5))]),
      chat(thread(7), [message("U7", "user", minutesAgo(20), { deliveryStatus: "sending", ...dispatched("laptop-b", "Laptop B") })], { storedHasUnresolvedLatestDelivery: true }),
      // Executor reported an explicit failed outcome; the run was not updated.
      chat(thread(8), [message("U8", "user", minutesAgo(20), dispatched("server-a", "Server A")), message("A8", "assistant", minutesAgo(10), { content: "Could not finish.\nORG2_RUN_OUTCOME: failed" })]),
      // A stopped turn.
      chat(thread(9), [message("U9", "user", minutesAgo(20), dispatched("server-a", "Server A")), message("A9", "assistant", minutesAgo(10), { deliveryStatus: "interrupted" })]),
    ],
  }));

  const makeRun = (id, { status = "running", threadN, workflowId, startedMinutesAgo = 25, failedMinutesAgo, completedMinutesAgo } = {}) => {
    let run = createAgentRun({ id, title: id, goal: id, now: minutesAgo(30).toISOString(), ...(workflowId ? { workflowId } : {}) });
    if (status !== "queued") run = transitionAgentRun(run, "running", { actor: "Scheduler", now: minutesAgo(startedMinutesAgo).toISOString() });
    if (threadN) run = addAgentRunComment(run, "Scheduler", `AI chat thread: ${thread(threadN).toLowerCase()}`, minutesAgo(startedMinutesAgo).toISOString());
    if (status === "failed") run = transitionAgentRun(run, "failed", { actor: "Scheduler", reason: "Timed out waiting for a reply", now: minutesAgo(failedMinutesAgo ?? 15).toISOString() });
    if (status === "completed") run = transitionAgentRun(run, "completed", { actor: "Scheduler", summary: "Sent the digest", now: minutesAgo(completedMinutesAgo ?? 9).toISOString() });
    saveAgentRun(root, run, { expectedRevision: null });
    return run;
  };
  makeRun("run-queued", { status: "queued" });
  makeRun("run-live", { threadN: 1 });
  makeRun("run-failed-but-live", { status: "failed", threadN: 2 });
  makeRun("run-stale-host", { threadN: 3 });
  makeRun("run-unrecorded", { threadN: 4, workflowId: "daily-digest" });
  makeRun("run-completed-undelivered", { status: "completed", threadN: 5 });
  makeRun("run-result-after-failure", { status: "failed", threadN: 6, failedMinutesAgo: 8 });
  makeRun("run-host-mismatch", { threadN: 7 });
  makeRun("run-explicit-failure", { threadN: 8, workflowId: "daily-digest" });
  makeRun("run-interrupted", { threadN: 9 });
  makeRun("run-failed", { status: "failed" });
  makeRun("run-silent", { startedMinutesAgo: 60 * 48 });
  makeRun("run-completed", { status: "completed" });

  const trace = (id) => traceRun(root, id, { now });
  const stage = (result, name) => result.stages.find((item) => item.stage === name);
  const findingCodes = (result) => result.findings.map((finding) => finding.code).sort();

  // Every trace names all five stages in order with evidence-backed summaries.
  {
    const result = trace("run-live");
    assert.equal(result.schema, "org2:run-trace:v1");
    assert.deepEqual(result.stages.map((item) => item.stage), ["dispatch", "executor", "tools", "result", "delivery"]);
    assert.equal(result.verdict, "running");
    assert.equal(result.confidence, "live");
    assert.equal(stage(result, "executor").status, "active");
    assert.ok(stage(result, "executor").evidence.some((item) => item.source === "presence"));
    assert.ok(stage(result, "dispatch").evidence.some((item) => item.source === "transcript" && /executes on Server A/u.test(item.detail)));
    assert.equal(stage(result, "tools").status, "warning");
    assert.deepEqual(findingCodes(result), ["shell-error", "slow-tool"]);
    assert.match(result.findings.find((finding) => finding.code === "slow-tool").summary, /Running test suite/u);
    assert.equal(result.retry.safe, false);
    assert.equal(result.retry.recommendation, "wait");
  }

  // Queued: nothing dispatched; retrying would duplicate the request.
  {
    const result = trace("run-queued");
    assert.equal(result.verdict, "queued");
    assert.equal(stage(result, "dispatch").status, "pending");
    assert.equal(result.retry.safe, false);
  }

  // Failed with no executor evidence: the only state where retry is safe.
  {
    const result = trace("run-failed");
    assert.equal(result.verdict, "failed");
    assert.equal(stage(result, "result").status, "failed");
    assert.match(result.reason.summary, /Timed out waiting for a reply/u);
    assert.equal(result.retry.safe, true);
  }

  // A run marked failed whose executor is still live is running, not failed.
  {
    const result = trace("run-failed-but-live");
    assert.equal(result.verdict, "running");
    assert.equal(result.reason.code, "executor-active-after-terminal");
    assert.equal(result.retry.safe, false);
  }

  // A stale host's cached turn makes the executor unknown, never running or done.
  {
    const result = trace("run-stale-host");
    assert.equal(result.verdict, "unknown");
    assert.equal(result.confidence, "uncertain");
    assert.ok(findingCodes(result).includes("stale-host"));
    assert.equal(stage(result, "executor").status, "unknown");
    assert.equal(result.retry.recommendation, "inspect");
  }

  // Completed-undelivered: the result exists, but did not reach the run record.
  {
    const result = trace("run-unrecorded");
    assert.equal(result.verdict, "completed-undelivered");
    assert.equal(result.reason.code, "result-unrecorded");
    assert.notEqual(result.verdict, "completed", "a chat reply alone is not proof the run completed");
    assert.equal(stage(result, "result").status, "ok");
    assert.equal(stage(result, "delivery").status, "failed");
    assert.equal(result.retry.safe, false);
    assert.equal(result.retry.recommendation, "record-result");
    assert.equal(loadAgentRun(root, "run-unrecorded").status, "running", "tracing is read-only");
  }

  // Completed-undelivered: the run completed but the reply failed to send.
  {
    const result = trace("run-completed-undelivered");
    assert.equal(result.verdict, "completed-undelivered");
    assert.equal(stage(result, "delivery").status, "failed");
    assert.match(stage(result, "delivery").summary, /Destination rejected the reply/u);
    assert.equal(result.retry.recommendation, "redeliver");
  }

  // A result produced after the failure was recorded is not a failure to retry.
  {
    const result = trace("run-result-after-failure");
    assert.equal(result.verdict, "completed-undelivered");
    assert.equal(result.reason.code, "result-after-failure");
    assert.equal(result.retry.safe, false);
  }

  // The executor reported an explicit failure: failed, never completed.
  {
    const result = trace("run-explicit-failure");
    assert.equal(result.verdict, "failed");
    assert.equal(result.reason.code, "failed-outcome-unrecorded");
  }

  // A stopped turn explains the stop instead of looking idle.
  {
    const result = trace("run-interrupted");
    assert.notEqual(result.verdict, "completed");
    const threadExplanation = explainActivity(root, { now, thread: thread(9) }).items[0];
    assert.equal(threadExplanation.reason.code, "turn-interrupted");
    assert.equal(threadExplanation.needsAttention, true);
  }

  // The reporting host differs from the dispatched host.
  {
    const result = trace("run-host-mismatch");
    assert.ok(findingCodes(result).includes("host-mismatch"));
    assert.equal(result.verdict, "running");
  }

  // Silent runs without a thread or recent event are unknown.
  {
    const result = trace("run-silent");
    assert.equal(result.verdict, "unknown");
    assert.ok(findingCodes(result).includes("silent-run"));
    assert.match(result.retry.reason, /`celorga run block run-silent --reason TEXT`/u, "recovery names the transition a person records");
  }

  // A completed run without a linked conversation is completed.
  assert.equal(trace("run-completed").verdict, "completed");

  // A queued background post is not delivery.
  {
    const posted = celorga("thread", "post", thread(4), "--message", "Digest ready", "--author", "Worker", "--idempotency-key", "run-trace-test", "--apply");
    assert.equal(posted.status, 0, posted.stderr);
    makeRun("run-completed-queued-post", { status: "completed", threadN: 4, completedMinutesAgo: 1 });
    const result = trace("run-completed-queued-post");
    assert.equal(result.verdict, "completed-undelivered");
    assert.equal(stage(result, "delivery").status, "pending");
    assert.equal(result.confidence, "uncertain");
    assert.ok(findingCodes(result).includes("delivery-uncertain"));
  }

  // CLI: trace output and the duplicate-retry guard.
  {
    const traced = celorga("activity", "trace", "--run", "run-unrecorded", "--json");
    assert.equal(traced.status, 0, traced.stderr);
    assert.equal(JSON.parse(traced.stdout).verdict, "completed-undelivered");
    const text = celorga("activity", "trace", "--run", "run-live");
    assert.equal(text.status, 0, text.stderr);
    assert.match(text.stdout, /verdict: running/u);
    assert.match(text.stdout, /finding slow-tool/u);

    const refused = celorga("run", "retry", "run-failed-but-live", "--actor", "Tester", "--json");
    assert.notEqual(refused.status, 0, "retrying a run with a live executor must be refused");
    assert.match(refused.stderr, /refusing to retry run-failed-but-live/u);
    assert.equal(loadAgentRun(root, "run-failed-but-live").status, "failed", "a refused retry writes nothing");

    const refusedResult = celorga("run", "retry", "run-result-after-failure", "--actor", "Tester", "--json");
    assert.notEqual(refusedResult.status, 0, "retrying a run whose result already exists must be refused");
    assert.equal(loadAgentRun(root, "run-result-after-failure").status, "failed");

    const allowed = celorga("run", "retry", "run-failed", "--actor", "Tester", "--json");
    assert.equal(allowed.status, 0, allowed.stderr);
    assert.equal(loadAgentRun(root, "run-failed").status, "queued");
    const again = celorga("run", "retry", "run-failed", "--actor", "Tester", "--json");
    assert.notEqual(again.status, 0, "a second retry of an already-queued run is refused");
    assert.equal(loadAgentRun(root, "run-failed").events.filter((event) => event.type === "status-changed" && event.data?.to === "queued").length, 1, "exactly one retry was recorded");

    const forced = celorga("run", "retry", "run-failed-but-live", "--actor", "Tester", "--force", "--json");
    assert.equal(forced.status, 0, forced.stderr);
    const forcedRun = loadAgentRun(root, "run-failed-but-live");
    assert.equal(forcedRun.status, "queued");
    assert.ok(forcedRun.comments.some((comment) => /Retry forced despite trace verdict running/u.test(comment.body)), "a forced retry records why it was unsafe");
  }

  console.log("run trace tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
