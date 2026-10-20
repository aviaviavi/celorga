#!/usr/bin/env node
// The workspace coordinator reviews durable work across two mounted corpora
// and their hosts, links evidence, and offers continuation only when every
// guard passes. Continuation is re-derived at execution time, preview-first,
// idempotent, and never claims a turn started.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";
import { appleReferenceDateSeconds } from "../dist/openClawThreadState.js";
import { addAgentRunArtifact, addAgentRunComment, addAgentRunValidation, createAgentRun, loadAgentRunSnapshot, requestAgentRunApproval, saveAgentRun, transitionAgentRun } from "../dist/agentRun.js";
import { aiChatInboxDirectory } from "../dist/aiChatInbox.js";
import { serveMcp } from "../dist/mcpRuntime.js";
import { continueWorkspaceOffer, coordinateWorkspace, renderWorkspaceCoordinationText } from "../dist/workspaceCoordinator.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist", "cli.js");
const base = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-workspace-coordinator-"));
const now = new Date();
const minutesAgo = (minutes) => new Date(now.getTime() - minutes * 60_000);
const iso = (minutes) => minutesAgo(minutes).toISOString();

const T = {
  live: "AAAAAAAA-0000-4000-8000-000000000001",
  quiet: "BBBBBBBB-0000-4000-8000-000000000002",
  offline: "CCCCCCCC-0000-4000-8000-000000000003",
  failover: "DDDDDDDD-0000-4000-8000-000000000004",
  room: "EEEEEEEE-0000-4000-8000-000000000005",
};

function corpus(name, id, { automationHostRef = "server-one" } = {}) {
  const root = path.join(base, name);
  fs.mkdirSync(path.join(root, "notes"), { recursive: true });
  fs.writeFileSync(path.join(root, "celorga.json"), `${JSON.stringify({ corpus: { schema: "org2:corpus:v1", id, name, kind: "project" }, automationHostRef }, null, 2)}\n`);
  return root;
}

function writeHost(root, writerID, record) {
  const dir = path.join(root, ".org2", "openclaw-chat.store", "live");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${writerID}.json`), JSON.stringify({ schema: "org2:ai-chat-live-host:v1", writerID, isOnline: true, turns: [], ...record }));
}

const message = (id, role, minutes, extra = {}) => ({ id, role, content: `${role} ${id}`, createdAt: appleReferenceDateSeconds(minutesAgo(minutes)), deliveryStatus: "sent", ...extra });
const thread = (id, title, messages, extra = {}) => ({
  id, title, createdAt: appleReferenceDateSeconds(minutesAgo(600)), updatedAt: appleReferenceDateSeconds(minutesAgo(30)),
  sessionKey: `agent:main:${id}`, messages, isPinned: false, isArchived: false, unreadMessageCount: 0, runtime: "openCode", destinationID: "dest.opencode", ...extra,
});
function writeThreads(root, threads) {
  fs.mkdirSync(path.join(root, ".org2"), { recursive: true });
  fs.writeFileSync(path.join(root, ".org2", "openclaw-chat.json"), JSON.stringify({ version: 6, selectedThreadID: null, threads }));
}
const ranOn = (hostRef, hostName) => ({ provenance: { executionHostRef: hostRef, executionHostName: hostName } });

function running(id, title, { minutes = 30, thread: threadID, context, assignee } = {}) {
  let run = createAgentRun({ id, title, goal: title, riskClass: "local-draft", now: iso(minutes + 1), ...(context ? { context } : {}), ...(assignee ? { assignee } : {}) });
  run = transitionAgentRun(run, "running", { actor: "Agent", now: iso(minutes) });
  if (threadID) run = addAgentRunComment(run, "Agent", `AI chat thread: ${threadID}`, iso(minutes));
  return run;
}

async function mcp(root, requests, options) {
  const input = new PassThrough();
  const output = new PassThrough();
  let text = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { text += chunk; });
  const serving = serveMcp(root, input, output, options);
  input.end(requests.map((request, index) => JSON.stringify({ jsonrpc: "2.0", id: index + 1, ...request })).join("\n") + "\n");
  await serving;
  return text.trim().split("\n").map((line) => JSON.parse(line));
}

const celorga = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });

try {
  // Corpus A ("alpha"): a live desktop and a live server share destinations.
  const alpha = corpus("alpha", "alpha-project");
  writeHost(alpha, "w-studio", {
    hostRef: "desktop-studio", hostName: "Studio", hostKind: "desktop", updatedAt: iso(0.2), enabledDestinationIDs: ["dest.opencode"],
    turns: [{ threadID: T.live, destinationID: "dest.opencode", destinationName: "OpenCode", startedAt: iso(3), activities: [{ id: "a", kind: "tool", title: "Running tests", status: "running", updatedAt: iso(0.3) }] }],
  });
  writeHost(alpha, "w-server", { hostRef: "server-one", hostName: "Server One", hostKind: "server", updatedAt: iso(0.4), enabledDestinationIDs: ["dest.opencode"] });
  writeThreads(alpha, [
    thread(T.live, "Live work", [message("L1", "user", 3, { deliveryStatus: "sending", ...ranOn("desktop-studio", "Studio") })], { storedHasUnresolvedLatestDelivery: true }),
    thread(T.quiet, "Quiet work", [message("Q1", "user", 40), message("Q2", "assistant", 35, ranOn("server-one", "Server One"))]),
    thread(T.room, "Shared room", [message("R1", "user", 50)], { isSharedRoom: true }),
  ]);
  fs.writeFileSync(path.join(alpha, "notes", "project.org"), [
    "#+title: Project",
    "",
    "* Work",
    "** TODO Ship the importer",
    ":PROPERTIES:",
    ":ID: 11111111-2222-4333-8444-555555555555",
    ":ORG2_RUN_ID: run-quiet",
    `:CELORGA_THREAD_ID: ${T.quiet}`,
    ":END:",
    "",
  ].join("\n"));

  // run-quiet links its thread only through the canonical task heading.
  saveAgentRun(alpha, running("run-quiet", "Ship the importer", { minutes: 30, context: [{ ref: "notes/project.org" }] }), { expectedRevision: null });
  saveAgentRun(alpha, running("run-live", "Live importer tests", { minutes: 2, thread: T.live }), { expectedRevision: null });
  saveAgentRun(alpha, running("run-room", "Room work", { minutes: 40, thread: T.room }), { expectedRevision: null });
  let approval = running("run-approval", "Publish release notes", { minutes: 25 });
  approval = requestAgentRunApproval(approval, { title: "Publish notes", action: "publish release notes", riskClass: "external-action", requestedAt: iso(20) }, "Agent");
  approval = transitionAgentRun(approval, "waiting-approval", { actor: "Agent", now: iso(20) });
  saveAgentRun(alpha, approval, { expectedRevision: null });
  saveAgentRun(alpha, running("run-silent", "Forgotten crawl", { minutes: 60 * 30 }), { expectedRevision: null });
  let shipped = running("run-shipped", "Fix pagination", { minutes: 120 });
  shipped = addAgentRunArtifact(shipped, { path: "views/pagination-report.org", role: "report", reviewStatus: "reviewed" }, "Agent");
  shipped = addAgentRunValidation(shipped, { name: "npm test", status: "passed", detail: "42 passing" }, "Agent");
  shipped = transitionAgentRun(shipped, "completed", { actor: "Agent", summary: "Pagination fixed and tested", now: iso(60) });
  saveAgentRun(alpha, shipped, { expectedRevision: null });
  let oldShipped = running("run-old", "Old shipped work", { minutes: 60 * 72 });
  oldShipped = transitionAgentRun(oldShipped, "completed", { actor: "Agent", summary: "Long ago", now: iso(60 * 71) });
  saveAgentRun(alpha, oldShipped, { expectedRevision: null });
  let failed = running("run-failed", "One-off export", { minutes: 50, assignee: "Export agent" });
  failed = transitionAgentRun(failed, "failed", { actor: "Agent", reason: "disk full", now: iso(45) });
  saveAgentRun(alpha, failed, { expectedRevision: null });
  // An older failure of the same work is superseded; an unowned failure has nobody to pick it up.
  let olderFailed = running("run-failed-older", "One-off export", { minutes: 80, assignee: "Export agent" });
  olderFailed = transitionAgentRun(olderFailed, "failed", { actor: "Agent", reason: "disk full", now: iso(75) });
  saveAgentRun(alpha, olderFailed, { expectedRevision: null });
  let unowned = running("run-failed-unowned", "Unowned cleanup", { minutes: 50 });
  unowned = transitionAgentRun(unowned, "failed", { actor: "Agent", reason: "crash", now: iso(45) });
  saveAgentRun(alpha, unowned, { expectedRevision: null });
  let failedAttempt = createAgentRun({ id: "run-failed-attempt", title: "Nightly digest", goal: "Nightly digest", workflowId: "nightly-digest", now: iso(46) });
  failedAttempt = transitionAgentRun(failedAttempt, "running", { now: iso(45) });
  failedAttempt = transitionAgentRun(failedAttempt, "failed", { reason: "timeout", now: iso(44) });
  saveAgentRun(alpha, failedAttempt, { expectedRevision: null });

  // Corpus B ("beta"): its last executor laptop is stale; a server can fail over
  // for one destination but nobody serves the other.
  const beta = corpus("beta", "beta-project", { automationHostRef: "server-two" });
  writeHost(beta, "w-laptop", { hostRef: "desktop-laptop", hostName: "Laptop", hostKind: "desktop", updatedAt: iso(40), enabledDestinationIDs: ["dest.opencode", "dest.codex"] });
  writeHost(beta, "w-server2", { hostRef: "server-two", hostName: "Server Two", hostKind: "server", updatedAt: iso(0.5), enabledDestinationIDs: ["dest.opencode"] });
  writeThreads(beta, [
    thread(T.failover, "Failover work", [message("F1", "user", 60), message("F2", "assistant", 55, ranOn("desktop-laptop", "Laptop"))]),
    thread(T.offline, "Codex only", [message("C1", "user", 60), message("C2", "assistant", 55, ranOn("desktop-laptop", "Laptop"))], { runtime: "codex", destinationID: "dest.codex" }),
  ]);
  saveAgentRun(beta, running("run-failover", "Migrate schema", { minutes: 50, thread: T.failover }), { expectedRevision: null });
  saveAgentRun(beta, running("run-offline", "Codex refactor", { minutes: 50, thread: T.offline }), { expectedRevision: null });

  // An unidentified mount is reported without hiding the identified corpora.
  const stray = path.join(base, "stray");
  fs.mkdirSync(stray);

  const result = coordinateWorkspace({ mounts: [alpha, beta, stray], now });
  assert.equal(result.schema, "org2:workspace-coordination:v1");
  assert.deepEqual(result.corpora.map((item) => item.id), ["alpha-project", "beta-project"]);
  assert.equal(result.issues.length, 1);
  assert.equal(result.issues[0].root, stray);

  // Hosts across machines retain their corpus and freshness.
  const hostState = Object.fromEntries(result.hosts.map((host) => [`${host.corpus.id}/${host.hostName}`, host.state]));
  assert.equal(hostState["alpha-project/Studio"], "online");
  assert.equal(hostState["beta-project/Laptop"], "stale");
  assert.equal(result.hosts.find((host) => host.hostName === "Studio").activeTurns[0].latestActivity, "Running tests");

  const ids = (items) => items.map((item) => item.id);
  assert.ok(ids(result.needsYou).includes("run-approval"), "pending approval needs a person");
  assert.ok(!ids(result.stuck).includes("run-approval"), "an approval boundary is not 'stuck'");
  assert.ok(ids(result.stuck).includes("run-silent"), "a silent running run is stuck");
  assert.ok(ids(result.stuck).includes("run-failed"), "a recent failure is stuck");
  assert.ok(ids(result.working).includes("run-live"), "a run with a live turn is working");
  assert.equal(result.working.find((item) => item.id === "run-live").confidence, "live");
  const approvalItem = result.needsYou.find((item) => item.id === "run-approval");
  assert.equal(approvalItem.blocking[0].kind, "approval");
  assert.ok(approvalItem.evidence.some((evidence) => evidence.kind === "run-file" && fs.existsSync(evidence.path)));

  // Shipped work is evidence-linked and bounded by the window.
  assert.deepEqual(result.shipped.map((item) => item.runId), ["run-shipped"]);
  const shippedItem = result.shipped[0];
  assert.equal(shippedItem.summary, "Pagination fixed and tested");
  assert.deepEqual(shippedItem.validations, { passed: 1, failed: 0, warning: 0, skipped: 0 });
  assert.equal(shippedItem.reviewPending, false);
  assert.ok(shippedItem.evidence.some((evidence) => evidence.kind === "artifact" && evidence.path === "views/pagination-report.org"));
  assert.ok(shippedItem.evidence.some((evidence) => evidence.kind === "validation" && /42 passing/.test(evidence.detail)));

  const offerFor = (runId) => result.continuations.find((offer) => offer.runId === runId);
  const failedGuards = (offer) => offer.guards.filter((guard) => !guard.passed).map((guard) => guard.check);

  // Allowed: quiet run linked through its canonical task; routed to the last executor.
  const quiet = offerFor("run-quiet");
  assert.equal(quiet.kind, "thread-send");
  assert.equal(quiet.allowed, true, JSON.stringify(quiet.guards));
  assert.equal(quiet.threadId.toLowerCase(), T.quiet.toLowerCase());
  assert.deepEqual(quiet.route, { destinationID: "dest.opencode", hostRef: "server-one", hostName: "Server One", basis: "last-executor" });
  assert.ok(quiet.guards.find((guard) => guard.check === "linked-thread").detail.includes("notes/project.org:4"));
  const quietItem = result.stuck.concat(result.working).find((item) => item.id === "run-quiet");
  const sourceEvidence = quietItem?.evidence.find((evidence) => evidence.kind === "source-task");
  assert.equal(sourceEvidence?.line, 4);
  assert.equal(sourceEvidence?.ref, "id:11111111-2222-4333-8444-555555555555");

  // Guarded: live turn, shared room, approval, scheduled attempt, offline route.
  assert.ok(!offerFor("run-live"), "a confirmed live turn is never offered for continuation");
  assert.deepEqual(failedGuards(offerFor("run-room")), ["single-agent-thread"]);
  assert.ok(!offerFor("run-approval"), "waiting-approval runs need a decision, not a continuation");
  assert.ok(failedGuards(offerFor("run-failed-attempt")).includes("not-scheduled-attempt"));
  assert.deepEqual(failedGuards(offerFor("run-failed-older")), ["not-superseded"]);
  assert.deepEqual(failedGuards(offerFor("run-failed-unowned")), ["has-executor"]);
  assert.equal(offerFor("run-failed").kind, "run-retry");
  assert.equal(offerFor("run-failed").allowed, true);
  assert.match(offerFor("run-failed").effect, /No executor is started/);
  const offline = offerFor("run-offline");
  assert.deepEqual(failedGuards(offline), ["route"]);
  assert.match(offline.guards.find((guard) => guard.check === "route").detail, /dest\.codex/);

  // Failover: the stale last executor is replaced by a live host with the destination.
  const failover = offerFor("run-failover");
  assert.equal(failover.allowed, true, JSON.stringify(failover.guards));
  assert.equal(failover.route.basis, "failover");
  assert.equal(failover.route.hostName, "Server Two");

  // Quiet guard: a recently active run must not be nudged.
  const strict = coordinateWorkspace({ mounts: [alpha], now, quietSeconds: 2 * 3600 });
  assert.deepEqual(failedGuards(strict.continuations.find((offer) => offer.runId === "run-quiet")), ["quiet"]);

  const text = renderWorkspaceCoordinationText(result);
  for (const heading of ["Hosts", "Needs you", "Stuck", "Working", "Shipped", "Continuation offers"]) assert.ok(text.includes(`\n${heading}\n`), heading);
  assert.match(text, /CAN CONTINUE .*Ship the importer via Server One \(last-executor\)/);

  // Preview writes nothing.
  const inboxDir = aiChatInboxDirectory(alpha);
  const inboxFiles = () => (fs.existsSync(inboxDir) ? fs.readdirSync(inboxDir).filter((name) => name.endsWith(".json")) : []);
  const before = loadAgentRunSnapshot(alpha, "run-quiet").revision;
  const preview = continueWorkspaceOffer(quiet.id, { mounts: [alpha, beta], now });
  assert.equal(preview.applied, false);
  assert.equal(preview.delivery.status, "preview");
  assert.equal(preview.delivery.turnStatus, "unconfirmed");
  assert.deepEqual(inboxFiles(), []);
  assert.equal(loadAgentRunSnapshot(alpha, "run-quiet").revision, before);

  // Guarded and unknown offers change nothing.
  assert.throws(() => continueWorkspaceOffer(offerFor("run-room").id, { mounts: [alpha, beta], now, apply: true }), /guarded: single-agent-thread/);
  assert.throws(() => continueWorkspaceOffer("co_missing", { mounts: [alpha, beta], now, apply: true }), /no longer current/);
  assert.deepEqual(inboxFiles(), []);

  // Apply queues exactly one idempotent single-agent send and records it on the run.
  const applied = continueWorkspaceOffer(quiet.id, { mounts: [alpha, beta], now, apply: true, actor: "Coordinator test" });
  assert.equal(applied.applied, true);
  assert.equal(applied.delivery.status, "queued");
  assert.equal(applied.delivery.turnStatus, "unconfirmed", "queuing never claims a started turn");
  assert.match(applied.unconfirmed, /neither delivery nor the turn start is confirmed/);
  assert.equal(applied.run.comment, "recorded");
  const queued = inboxFiles();
  assert.equal(queued.length, 1);
  const envelope = JSON.parse(fs.readFileSync(path.join(inboxDir, queued[0]), "utf8"));
  assert.equal(envelope.schema, "org2:ai-chat-send-message:v1");
  assert.equal(envelope.destinationID, "dest.opencode");
  assert.match(envelope.content, /Continue Celorga run run-quiet/);
  assert.match(envelope.content, /notes\/project\.org:4/);
  const after = loadAgentRunSnapshot(alpha, "run-quiet");
  assert.notEqual(after.revision, before);
  assert.match(after.run.comments.at(-1).body, /queued continuation .* Turn start unconfirmed/);

  // The applied offer is now stale, and the new offer is guarded by the queued request.
  assert.throws(() => continueWorkspaceOffer(quiet.id, { mounts: [alpha, beta], now, apply: true }), /no longer current/);
  const again = coordinateWorkspace({ mounts: [alpha, beta], now }).continuations.find((offer) => offer.runId === "run-quiet");
  assert.notEqual(again.id, quiet.id);
  assert.equal(again.allowed, false);
  assert.ok(failedGuards(again).includes("no-undelivered-request"));
  assert.equal(inboxFiles().length, 1, "no duplicate continuation was queued");

  // Run retry delegates to a revision-guarded requeue and starts nothing.
  const retry = continueWorkspaceOffer(offerFor("run-failed").id, { mounts: [alpha, beta], now, apply: true });
  assert.equal(retry.run.status, "queued");
  assert.match(retry.unconfirmed, /no executor was started/);
  assert.equal(loadAgentRunSnapshot(alpha, "run-failed").run.status, "queued");

  // CLI surface: mounted JSON, text, and argument guards.
  const json = celorga("workspace", "coordinate", "--mount", alpha, "--mount", beta, "--since", "2h", "--json");
  assert.equal(json.status, 0, json.stderr);
  const parsed = JSON.parse(json.stdout);
  assert.equal(parsed.schema, "org2:workspace-coordination:v1");
  assert.equal(parsed.summary.corpora, 2);
  assert.ok(parsed.continuations.some((offer) => offer.runId === "run-failover" && offer.allowed));
  const single = celorga("workspace", "coordinate", "--dir", beta);
  assert.equal(single.status, 0, single.stderr);
  assert.match(single.stdout, /Continuation offers/);
  const both = celorga("workspace", "coordinate", "--mount", alpha, "--dir", beta);
  assert.notEqual(both.status, 0);
  assert.match(both.stderr, /not both/);
  const badSince = celorga("workspace", "coordinate", "--dir", beta, "--since", "soon");
  assert.notEqual(badSince.status, 0);
  const failoverID = parsed.continuations.find((offer) => offer.runId === "run-failover").id;
  const cliPreview = celorga("workspace", "continue", failoverID, "--mount", alpha, "--mount", beta);
  assert.equal(cliPreview.status, 0, cliPreview.stderr);
  assert.match(cliPreview.stdout, /would queue continuation for run run-failover .* via Server Two/);
  assert.match(cliPreview.stdout, /celorga thread wait/);
  const betaInbox = aiChatInboxDirectory(beta);
  assert.equal(fs.existsSync(betaInbox) ? fs.readdirSync(betaInbox).filter((name) => name.endsWith(".json")).length : 0, 0);

  // MCP: a chat agent can review and preview continuation natively; the
  // read-only endpoint exposes neither tool.
  const [tools, reviewed] = await mcp(beta, [
    { method: "tools/list" },
    { method: "tools/call", params: { name: "celorga_workspace_coordinate", arguments: { sinceHours: 2 } } },
  ]);
  assert.ok(tools.result.tools.some((tool) => tool.name === "celorga_workspace_coordinate"));
  const mcpReview = JSON.parse(reviewed.result.content[0].text);
  const mcpOffer = mcpReview.continuations.find((offer) => offer.runId === "run-failover");
  const [previewed] = await mcp(beta, [{ method: "tools/call", params: { name: "celorga_workspace_continue", arguments: { offerId: mcpOffer.id } } }]);
  const mcpPreview = JSON.parse(previewed.result.content[0].text);
  assert.equal(mcpPreview.applied, false);
  assert.equal(mcpPreview.delivery.status, "preview");
  const [readOnlyTools, readOnlyCall] = await mcp(beta, [
    { method: "tools/list" },
    { method: "tools/call", params: { name: "celorga_workspace_coordinate", arguments: {} } },
  ], { readOnly: true });
  assert.ok(!readOnlyTools.result.tools.some((tool) => tool.name.startsWith("celorga_workspace_")));
  assert.ok(readOnlyCall.error || readOnlyCall.result?.isError, "read-only endpoint rejects the coordinator");

  console.log("OK: workspace coordinator reviews cross-host work with evidence and guarded, idempotent continuation");
} finally {
  fs.rmSync(base, { recursive: true, force: true });
}
