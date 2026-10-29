#!/usr/bin/env node
// Explainable agent state, the local activity event stream, and race-free
// waits are derived from structured presence, transcript, run, and workflow
// records in a synthetic corpus.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { appleReferenceDateSeconds } from "../dist/openClawThreadState.js";
import { createAgentRun, requestAgentRunApproval, saveAgentRun, transitionAgentRun, addAgentRunComment, loadAgentRunSnapshot } from "../dist/agentRun.js";
import { activityHosts, classifyHostState, explainActivity } from "../dist/activityState.js";
import { activityEventHistory, followActivityEvents, runWaitConditionState, waitForRun, waitForThread } from "../dist/activityEvents.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist", "cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-activity-explain-"));
const now = new Date();
const minutesAgo = (minutes) => new Date(now.getTime() - minutes * 60_000);
const org2 = (...args) => spawnSync(process.execPath, [cli, ...args, "--dir", root], { encoding: "utf8" });

try {
  fs.writeFileSync(path.join(root, "org2.json"), `${JSON.stringify({ automationHostRef: "press" }, null, 2)}\n`);
  const liveDir = path.join(root, ".org2", "openclaw-chat.store", "live");
  fs.mkdirSync(liveDir, { recursive: true });
  const writeHost = (writerID, record) => fs.writeFileSync(path.join(liveDir, `${writerID}.json`), JSON.stringify({
    schema: "org2:ai-chat-live-host:v1",
    writerID,
    isOnline: true,
    enabledDestinationIDs: ["builtin.codex"],
    turns: [],
    ...record,
  }));
  writeHost("w-press", { hostRef: "press", hostName: "OpenOrg on press", hostKind: "server", updatedAt: minutesAgo(0.5).toISOString() });
  writeHost("w-mac", {
    hostRef: "desktop-mac",
    hostName: "Laptop",
    hostKind: "desktop",
    updatedAt: minutesAgo(40).toISOString(),
    turns: [{ threadID: "BBBBBBBB-0000-4000-8000-000000000002", destinationID: "builtin.codex", destinationName: "Codex", streamingReply: "", reasoning: "", activities: [] }],
  });
  writeHost("w-live", {
    hostRef: "desktop-live",
    hostName: "Studio",
    hostKind: "desktop",
    updatedAt: minutesAgo(0.2).toISOString(),
    authenticationNeededDestinationIDs: [],
    turns: [{
      threadID: "AAAAAAAA-0000-4000-8000-000000000001",
      destinationID: "builtin.codex",
      destinationName: "Codex",
      startedAt: minutesAgo(2).toISOString(),
      streamingReply: "",
      reasoning: "",
      activities: [{ id: "a1", runID: "r", kind: "tool", title: "Running npm test", status: "running", updatedAt: minutesAgo(0.3).toISOString() }],
    }],
  });

  const message = (id, role, at, extra = {}) => ({ id, role, content: `${role} ${id}`, createdAt: appleReferenceDateSeconds(at), deliveryStatus: "sent", ...extra });
  const thread = (id, title, messages, extra = {}) => ({
    id, title, createdAt: appleReferenceDateSeconds(minutesAgo(60)), updatedAt: appleReferenceDateSeconds(messages.length ? minutesAgo(1) : minutesAgo(60)),
    sessionKey: `agent:main:${id}`, messages, isPinned: false, isArchived: false, unreadMessageCount: 0, runtime: "codex", destinationID: "builtin.codex", ...extra,
  });
  const transcript = {
    version: 6,
    selectedThreadID: null,
    threads: [
      thread("AAAAAAAA-0000-4000-8000-000000000001", "Live turn", [message("M1", "user", minutesAgo(2), { deliveryStatus: "sending", provenance: { executionHostRef: "desktop-live", executionHostName: "Studio" } })], { storedHasUnresolvedLatestDelivery: true }),
      thread("BBBBBBBB-0000-4000-8000-000000000002", "Sleeping laptop", [message("M2", "user", minutesAgo(45), { deliveryStatus: "sending", provenance: { executionHostRef: "desktop-mac", executionHostName: "Laptop" } })], { storedHasUnresolvedLatestDelivery: true }),
      thread("CCCCCCCC-0000-4000-8000-000000000003", "Failed send", [message("M3", "user", minutesAgo(5), { deliveryStatus: "failed", sendFailure: "Codex is not signed in" })], { storedLatestDeliveryNeedsAttention: true }),
      thread("DDDDDDDD-0000-4000-8000-000000000004", "Replied", [message("M4", "user", minutesAgo(10)), message("M5", "assistant", minutesAgo(9))], { unreadMessageCount: 1 }),
      thread("EEEEEEEE-0000-4000-8000-000000000005", "Waiting for host", [message("M6", "user", minutesAgo(3), { deliveryStatus: "sending", provenance: { executionHostRef: "press", executionHostName: "OpenOrg on press", acceptedAt: appleReferenceDateSeconds(minutesAgo(3)) } })], { storedHasUnresolvedLatestDelivery: true }),
    ],
  };
  const transcriptFile = path.join(root, ".org2", "openclaw-chat.json");
  fs.writeFileSync(transcriptFile, JSON.stringify(transcript));

  // Runs: one waiting for approval (linked to the replied thread), one blocked on a question, one silent.
  let approvalRun = createAgentRun({ id: "run-approval", title: "Send outreach", goal: "Send outreach", riskClass: "external-action", now: minutesAgo(30).toISOString() });
  approvalRun = transitionAgentRun(approvalRun, "running", { actor: "Codex", now: minutesAgo(29).toISOString() });
  approvalRun = addAgentRunComment(approvalRun, "OpenOrg", "AI chat thread: DDDDDDDD-0000-4000-8000-000000000004", minutesAgo(29).toISOString());
  approvalRun = requestAgentRunApproval(approvalRun, { title: "Email Acme", action: "send email to a@acme.example", riskClass: "external-action", requestedAt: minutesAgo(20).toISOString() }, "Codex");
  approvalRun = transitionAgentRun(approvalRun, "waiting-approval", { actor: "Codex", now: minutesAgo(20).toISOString() });
  saveAgentRun(root, approvalRun, { expectedRevision: null });
  let blockedRun = createAgentRun({ id: "run-blocked", title: "Pick a checkout", goal: "Pick a checkout", now: minutesAgo(15).toISOString() });
  blockedRun = transitionAgentRun(blockedRun, "running", { actor: "OpenCode", now: minutesAgo(14).toISOString() });
  blockedRun = transitionAgentRun(blockedRun, "blocked", { actor: "OpenCode", reason: "Which checkout should I use?", now: minutesAgo(13).toISOString() });
  saveAgentRun(root, blockedRun, { expectedRevision: null });
  let silentRun = createAgentRun({ id: "run-silent", title: "Old work", goal: "Old work", now: minutesAgo(60 * 30).toISOString() });
  silentRun = transitionAgentRun(silentRun, "running", { actor: "OpenClaw", now: minutesAgo(60 * 30).toISOString() });
  saveAgentRun(root, silentRun, { expectedRevision: null });
  // Resumed from blocked by an executor that then stopped without recording a
  // transition: well inside a day, but long past the trace's quiet window.
  let resumedRun = createAgentRun({ id: "run-resumed-quiet", title: "Resumed work", goal: "Resumed work", now: minutesAgo(120).toISOString() });
  resumedRun = transitionAgentRun(resumedRun, "running", { actor: "Codex", now: minutesAgo(119).toISOString() });
  resumedRun = transitionAgentRun(resumedRun, "blocked", { actor: "Codex", reason: "Awaiting review", now: minutesAgo(90).toISOString() });
  resumedRun = transitionAgentRun(resumedRun, "running", { actor: "Codex", now: minutesAgo(50).toISOString() });
  saveAgentRun(root, resumedRun, { expectedRevision: null });
  let recentRun = createAgentRun({ id: "run-recent", title: "Recent work", goal: "Recent work", now: minutesAgo(6).toISOString() });
  recentRun = transitionAgentRun(recentRun, "running", { actor: "Codex", now: minutesAgo(5).toISOString() });
  saveAgentRun(root, recentRun, { expectedRevision: null });

  // Hosts.
  assert.equal(classifyHostState({ isOnline: false, updatedAtMs: now.getTime(), authenticationNeededDestinationIDs: [] }, now).state, "offline");
  assert.equal(classifyHostState({ isOnline: true, updatedAtMs: minutesAgo(5).getTime(), authenticationNeededDestinationIDs: [] }, now).state, "reconnecting");
  assert.equal(classifyHostState({ isOnline: true, updatedAtMs: now.getTime(), authenticationNeededDestinationIDs: ["builtin.codex"] }, now).state, "authentication-needed");
  const hosts = activityHosts(root, now);
  const byRef = Object.fromEntries(hosts.hosts.map((host) => [host.hostRef, host]));
  assert.equal(byRef.press.state, "online");
  assert.equal(byRef.press.isAutomationHost, true);
  assert.equal(byRef["desktop-mac"].state, "stale");
  assert.equal(byRef["desktop-mac"].confidence, "cached");
  assert.equal(byRef["desktop-mac"].turns.length, 1, "a silent host keeps its last-known turns as cached state");
  assert.deepEqual(byRef["desktop-mac"].failoverHostRefs.sort(), ["desktop-live", "press"]);

  // A draining host is not a failover candidate, and hand-offs to it are explained.
  writeHost("w-press", { hostRef: "press", hostName: "OpenOrg on press", hostKind: "server", updatedAt: minutesAgo(0.5).toISOString(), isDraining: true });
  {
    const drainingHosts = activityHosts(root, now).hosts;
    const pressHost = drainingHosts.find((host) => host.hostRef === "press");
    assert.equal(pressHost.draining, true);
    assert.match(pressHost.stateReason, /Draining/u);
    assert.ok(!drainingHosts.find((host) => host.hostRef === "desktop-mac").failoverHostRefs.includes("press"));
    const restarting = explainActivity(root, { now, thread: "EEEEEEEE-0000-4000-8000-000000000005" }).items[0];
    assert.equal(restarting.reason.code, "host-restarting");
  }
  writeHost("w-press", { hostRef: "press", hostName: "OpenOrg on press", hostKind: "server", updatedAt: minutesAgo(0.5).toISOString() });

  // Threads.
  const explain = (options) => explainActivity(root, { now, ...options }).items[0];
  const live = explain({ thread: "AAAAAAAA-0000-4000-8000-000000000001" });
  assert.equal(live.state, "working");
  assert.equal(live.confidence, "live");
  assert.equal(live.reason.code, "turn-running");
  assert.equal(live.reportedBy.hostName, "Studio");
  assert.equal(live.lastSignal.type, "heartbeat");
  assert.match(live.reason.summary, /Running npm test/u);
  const sleeping = explain({ thread: "BBBBBBBB-0000-4000-8000-000000000002" });
  assert.equal(sleeping.state, "working");
  assert.equal(sleeping.confidence, "uncertain");
  assert.equal(sleeping.reason.code, "turn-unconfirmed");
  const failed = explain({ thread: "CCCCCCCC-0000-4000-8000-000000000003" });
  assert.equal(failed.state, "needs-you");
  assert.equal(failed.blocking[0].kind, "delivery-failure");
  assert.equal(failed.blocking[0].summary, "Codex is not signed in");
  const replied = explain({ thread: "DDDDDDDD-0000-4000-8000-000000000004" });
  assert.equal(replied.state, "needs-you", "the linked run's pending approval blocks the conversation");
  assert.equal(replied.blocking[0].kind, "approval");
  assert.equal(replied.blocking[0].approvalId, approvalRun.approvals[0].id);
  assert.equal(replied.blocking[0].fingerprint, approvalRun.approvals[0].fingerprint);
  assert.deepEqual(replied.related, [{ kind: "run", id: "run-approval", relation: "linked-run" }]);
  const waiting = explain({ thread: "EEEEEEEE-0000-4000-8000-000000000005" });
  assert.equal(waiting.state, "queued");
  assert.equal(waiting.confidence, "uncertain");
  assert.equal(waiting.reportedBy.hostRef, "press");

  // Runs.
  const approval = explain({ run: "run-approval" });
  assert.equal(approval.state, "needs-you");
  assert.equal(approval.reason.code, "waiting-approval");
  assert.match(approval.blocking[0].command, /celorga run approval-decide run-approval /u);
  assert.equal(approval.reportedBy.actor, "Codex");
  const blocked = explain({ run: "run-blocked" });
  assert.equal(blocked.blocking[0].kind, "question");
  assert.equal(blocked.blocking[0].summary, "Which checkout should I use?");
  const silent = explain({ run: "run-silent" });
  assert.equal(silent.state, "working");
  assert.equal(silent.confidence, "uncertain");
  assert.equal(silent.reason.code, "silent");
  const resumedQuiet = explain({ run: "run-resumed-quiet" });
  assert.equal(resumedQuiet.state, "working");
  assert.equal(resumedQuiet.confidence, "uncertain", "a quiet running run without presence is not confirmed as working");
  assert.equal(resumedQuiet.reason.code, "silent");
  assert.match(resumedQuiet.reason.summary, /no host reports a turn for it and the last run event was 50 min/u);
  const recent = explain({ run: "run-recent" });
  assert.equal(recent.reason.code, "running", "a recently started run stays working inside the quiet window");
  assert.equal(recent.confidence, "cached");

  // Full listing ranks attention first and skips idle work.
  const listing = explainActivity(root, { now });
  assert.ok(listing.items[0].needsAttention);
  assert.ok(!listing.items.some((item) => item.state === "idle"));
  assert.ok(listing.summary.uncertain >= 2);

  // CLI envelopes.
  const json = JSON.parse(org2("activity", "explain", "--run", "run-blocked", "--json").stdout);
  assert.equal(json.schema, "org2:activity-explanation:v1");
  assert.equal(json.items[0].reason.code, "blocked-question");
  const text = org2("activity", "explain");
  assert.equal(text.status, 0, text.stderr);
  assert.match(text.stdout, /blocking question: Which checkout should I use\?/u);
  assert.equal(JSON.parse(org2("activity", "hosts", "--json").stdout).schema, "org2:activity-hosts:v1");

  // History replays durable events with stable IDs.
  const history = activityEventHistory(root, { since: minutesAgo(31), now });
  const types = history.map((event) => event.type);
  assert.ok(types.includes("run.created"));
  assert.ok(types.includes("approval.requested"));
  assert.ok(types.includes("run.waiting-approval"));
  assert.ok(types.includes("run.blocked"));
  assert.ok(types.includes("thread.reply-received"));
  const blockedEvent = history.find((event) => event.type === "run.blocked");
  assert.equal(blockedEvent.data.reason, "Which checkout should I use?");
  assert.deepEqual(activityEventHistory(root, { since: minutesAgo(31), now }).map((event) => event.id), history.map((event) => event.id));
  const filtered = activityEventHistory(root, { since: minutesAgo(31), now, filter: { types: ["approval.*"] } });
  assert.ok(filtered.length > 0 && filtered.every((event) => event.type.startsWith("approval.")));
  const ndjson = org2("activity", "events", "--since", "31m", "--type", "run.blocked", "--json").stdout.trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(ndjson.length, 1);
  assert.equal(ndjson[0].subject.id, "run-blocked");

  // Run wait conditions.
  assert.equal(runWaitConditionState(approvalRun, "approval"), "matched");
  assert.equal(runWaitConditionState(approvalRun, "completed"), "pending");
  assert.equal(runWaitConditionState({ ...approvalRun, status: "failed", approvals: [] }, "completed"), "unreachable");
  // Already-satisfied waits return immediately (race-free).
  const immediate = await waitForRun(root, "run-approval", "approval", { timeoutSeconds: 5 });
  assert.equal(immediate.outcome, "matched");
  const timedOut = await waitForRun(root, "run-blocked", "completed", { timeoutSeconds: 0.3, intervalMs: 50 });
  assert.equal(timedOut.outcome, "timeout");
  const timeoutCli = org2("run", "wait", "run-blocked", "--until", "completed", "--timeout", "0.2", "--json");
  assert.equal(timeoutCli.status, 124, timeoutCli.stderr);

  // A transition that lands while waiting wakes the wait.
  const pendingWait = waitForRun(root, "run-blocked", "completed", { timeoutSeconds: 10, intervalMs: 100 });
  setTimeout(() => {
    const snapshot = loadAgentRunSnapshot(root, "run-blocked");
    let run = transitionAgentRun(snapshot.run, "running", { actor: "OpenCode" });
    run = transitionAgentRun(run, "completed", { actor: "OpenCode", summary: "Used ~/dev/org2" });
    saveAgentRun(root, run, { expectedRevision: snapshot.revision });
  }, 200);
  const woke = await pendingWait;
  assert.equal(woke.outcome, "matched");
  assert.equal(woke.status, "completed");

  // Thread reply waits use the latest prompt as the baseline: a reply that
  // already landed counts; a thread without a newer reply waits.
  const already = await waitForThread(root, "DDDDDDDD-0000-4000-8000-000000000004", "reply", { timeoutSeconds: 2 });
  assert.equal(already.outcome, "matched");
  assert.equal(already.reply.messageId, "M5");
  const notYet = await waitForThread(root, "EEEEEEEE-0000-4000-8000-000000000005", "reply", { timeoutSeconds: 0.3, intervalMs: 50 });
  assert.equal(notYet.outcome, "timeout");
  const failedNeedsYou = await waitForThread(root, "CCCCCCCC-0000-4000-8000-000000000003", "needs-you", { timeoutSeconds: 2 });
  assert.equal(failedNeedsYou.outcome, "matched");

  // A background reply posted through the inbox satisfies a reply wait.
  const replyWait = waitForThread(root, "EEEEEEEE-0000-4000-8000-000000000005", "reply", { timeoutSeconds: 10, intervalMs: 100 });
  setTimeout(() => {
    const posted = org2("thread", "post", "EEEEEEEE-0000-4000-8000-000000000005", "--message", "Done", "--author", "Worker", "--idempotency-key", "activity-test", "--apply");
    assert.equal(posted.status, 0, posted.stderr);
  }, 200);
  const replyResult = await replyWait;
  assert.equal(replyResult.outcome, "matched");
  assert.equal(replyResult.reply.source, "inbox");

  // Following streams new run events.
  const controller = new AbortController();
  const streamed = [];
  const follow = followActivityEvents(root, (event) => streamed.push(event), { intervalMs: 100, signal: controller.signal, filter: { types: ["run.*"] }, limit: 2 });
  setTimeout(() => {
    const run = createAgentRun({ id: "run-new", title: "New work", goal: "New work" });
    saveAgentRun(root, transitionAgentRun(run, "running", { actor: "Codex" }), { expectedRevision: null });
  }, 200);
  const stopper = setTimeout(() => controller.abort(), 8000);
  await follow;
  clearTimeout(stopper);
  assert.deepEqual(streamed.map((event) => event.type), ["run.created", "run.running"]);

  // Following from the CLI emits NDJSON.
  // Anchor before spawning so a slow CLI startup can replay the transition.
  const since = new Date().toISOString();
  const child = spawn(process.execPath, [cli, "activity", "events", "--follow", "--since", since, "--type", "run.completed", "--limit", "1", "--interval-ms", "100", "--json", "--dir", root], { stdio: ["ignore", "pipe", "pipe"] });
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const deadline = setTimeout(() => child.kill("SIGTERM"), 20_000);
  child.once("exit", () => clearTimeout(deadline));
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  await new Promise((resolve) => setTimeout(resolve, 600));
  {
    const snapshot = loadAgentRunSnapshot(root, "run-new");
    saveAgentRun(root, transitionAgentRun(snapshot.run, "completed", { actor: "Codex", summary: "ok" }), { expectedRevision: snapshot.revision });
  }
  const exitCode = await exited;
  assert.equal(exitCode, 0);
  const streamedEvent = JSON.parse(output.trim());
  assert.equal(streamedEvent.type, "run.completed");
  assert.equal(streamedEvent.subject.id, "run-new");

  console.log("activity explain, events, and waits ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
