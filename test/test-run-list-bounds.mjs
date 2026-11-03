import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  agentRunPath, createAgentRun, listAgentRuns, queryAgentRuns, renderAgentRunOrg, summarizeAgentRunAttempts,
} from "../dist/agentRun.js";
import { workspaceRunList } from "../dist/workspaceAgentState.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-run-list-bounds-"));
const history = "Synthetic history entry. ".repeat(80000);

function cli(args) {
  return spawnSync("node", ["dist/cli.js", "run", "list", "--dir", root, ...args], {
    cwd: repo, encoding: "utf8", maxBuffer: 256 * 1024 * 1024,
  });
}
function cliJson(args) {
  const result = cli([...args, "--json"]);
  assert.equal(result.status, 0, result.stderr);
  return { value: JSON.parse(result.stdout), bytes: Buffer.byteLength(result.stdout) };
}
function cliError(args, pattern) {
  const result = cli([...args, "--json"]);
  assert.notEqual(result.status, 0, `expected failure for ${args.join(" ")}`);
  assert.match(result.stderr, pattern);
  assert.equal(result.stdout, "");
}
function write(run) {
  fs.mkdirSync(path.dirname(agentRunPath(root, run.id)), { recursive: true });
  fs.writeFileSync(agentRunPath(root, run.id), renderAgentRunOrg(run));
}
function heavy(run) {
  for (let index = 0; index < 3; index++) {
    run.comments.push({ id: `${run.id}-comment-${index}`, author: "synthetic-agent", body: history, createdAt: run.createdAt });
    run.events.push({ id: `${run.id}-event-${index}`, type: "note", at: run.createdAt, detail: history.slice(0, 50000) });
  }
  return run;
}

const at = (minute) => `2026-10-01T00:${String(minute).padStart(2, "0")}:00.000Z`;
const make = (id, status, minute, extra = {}) =>
  createAgentRun({ id, goal: `Synthetic goal for ${id}. ${"Detail. ".repeat(2000)}`, status, now: at(minute), ...extra });

try {
  assert.deepEqual(workspaceRunList(root, { statuses: ["queued"], limit: 5, summary: true }).page,
    { total: 0, offset: 0, limit: 5, returned: 0, hasMore: false, nextOffset: null });

  const huge = heavy(make("run-c", "completed", 50, {
    logicalWorkId: "work-1",
    attempt: { id: "work-1-attempt-1", number: 1, triggerId: "schedule", triggerType: "schedule", signalIds: ["sig-1"], signals: [{ id: "sig-1", type: "todo-state", at: at(50), note: history.slice(0, 20000) }] },
    plan: [{ title: "Draft", kind: "agent" }, { title: "Check", kind: "validation" }],
  }));
  huge.artifacts.push({ id: "artifact-1", path: "views/draft.org", role: "draft", reviewStatus: "review-required", createdAt: at(50) });
  huge.validations.push({ id: "validation-1", name: "lint", status: "failed", checkedAt: at(50) });
  const runs = [
    make("run-a", "queued", 30),
    make("run-b", "running", 30),
    huge,
    make("run-d", "failed", 10),
    make("run-e", "queued", 20, { logicalWorkId: "work-1", attempt: { id: "work-1-attempt-2", number: 2 } }),
    make("run-f", "running", 40, { logicalWorkId: "work-1", attempt: { id: "work-1-attempt-3", number: 3 } }),
    heavy(make("run-g", "completed", 0)),
  ];
  for (const run of runs) write(run);
  fs.writeFileSync(path.join(path.dirname(agentRunPath(root, "run-a")), "run-a.sync-conflict.org2"), renderAgentRunOrg({ ...runs[0], updatedAt: at(59) }));

  // Default API and CLI contracts are unchanged.
  const all = listAgentRuns(root);
  assert.deepEqual(all.map((run) => run.id), ["run-c", "run-f", "run-a", "run-b", "run-e", "run-d", "run-g"]);
  const legacy = workspaceRunList(root);
  assert.deepEqual(legacy, { schema: "org2:run-list:v1", runs: all, logicalWork: summarizeAgentRunAttempts(all) });
  assert.deepEqual(Object.keys(legacy), ["schema", "runs", "logicalWork"]);
  const full = cliJson([]);
  assert.deepEqual(full.value, JSON.parse(JSON.stringify(legacy)));
  assert.ok(full.bytes > 4_000_000, "fixture must carry large histories");
  const queuedLegacy = workspaceRunList(root, "queued");
  assert.deepEqual(queuedLegacy.runs, all.filter((run) => run.status === "queued"));
  assert.deepEqual(workspaceRunList(root, "not-a-status").runs, [], "legacy string API stays unvalidated");
  assert.deepEqual(cliJson(["--status", "queued"]).value, JSON.parse(JSON.stringify(queuedLegacy)));

  // Repeated statuses use OR semantics, keep list order, and ignore duplicates.
  const open = cliJson(["--status", "queued", "--status", "running", "--status", "queued"]).value;
  assert.deepEqual(Object.keys(open), ["schema", "runs", "logicalWork"]);
  assert.deepEqual(open.runs.map((run) => run.id), ["run-f", "run-a", "run-b", "run-e"]);
  assert.deepEqual(open.logicalWork, JSON.parse(JSON.stringify(summarizeAgentRunAttempts(all.filter((run) => ["queued", "running"].includes(run.status))))));

  // Pages are stable, cover every match exactly once, and report continuation.
  const pages = [];
  for (let offset = 0; offset !== null;) {
    const page = cliJson(["--status", "queued", "--status", "running", "--limit", "3", "--offset", String(offset)]).value;
    assert.equal(page.projection, "full");
    assert.deepEqual(page.statuses, ["queued", "running"]);
    assert.equal(page.page.total, 4);
    pages.push(page);
    offset = page.page.nextOffset;
  }
  assert.deepEqual(pages.map((page) => page.page), [
    { total: 4, offset: 0, limit: 3, returned: 3, hasMore: true, nextOffset: 3 },
    { total: 4, offset: 3, limit: 3, returned: 1, hasMore: false, nextOffset: null },
  ]);
  assert.deepEqual(pages.flatMap((page) => page.runs), open.runs);
  // A represented group's roll-up counts every matching attempt, including
  // attempts on other pages.
  assert.deepEqual(pages[1].logicalWork, open.logicalWork);

  const tie = cliJson(["--limit", "1", "--offset", "2"]).value;
  assert.deepEqual(tie.runs.map((run) => run.id), ["run-a"]);
  assert.deepEqual(cliJson(["--limit", "1", "--offset", "3"]).value.runs.map((run) => run.id), ["run-b"]);
  const tail = cliJson(["--offset", "5"]).value;
  assert.deepEqual(tail.runs.map((run) => run.id), ["run-d", "run-g"]);
  assert.deepEqual(tail.page, { total: 7, offset: 5, limit: null, returned: 2, hasMore: false, nextOffset: null });
  assert.equal(tail.statuses, undefined);
  const beyond = cliJson(["--status", "queued", "--limit", "10", "--offset", "50"]).value;
  assert.deepEqual(beyond.runs, []);
  assert.deepEqual(beyond.page, { total: 2, offset: 50, limit: 10, returned: 0, hasMore: false, nextOffset: null });
  assert.deepEqual(beyond.logicalWork, []);
  const none = cliJson(["--status", "canceled", "--limit", "10"]).value;
  assert.deepEqual(none.runs, []);
  assert.deepEqual(none.logicalWork, []);
  assert.deepEqual(none.page, { total: 0, offset: 0, limit: 10, returned: 0, hasMore: false, nextOffset: null });

  // Full records are returned unchanged when paging without a summary.
  assert.deepEqual(workspaceRunList(root, { limit: 1 }).runs, [all[0]]);

  // Summaries stay compact while keeping identity, lifecycle, and counts.
  const summary = cliJson(["--summary"]);
  assert.ok(summary.bytes < 20_000, `summary output should be compact, got ${summary.bytes} bytes`);
  assert.equal(summary.value.projection, "summary");
  assert.deepEqual(summary.value.page, { total: 7, offset: 0, limit: null, returned: 7, hasMore: false, nextOffset: null });
  assert.deepEqual(summary.value.runs.map((run) => run.id), all.map((run) => run.id));
  assert.deepEqual(summary.value.logicalWork, full.value.logicalWork);
  for (const item of summary.value.runs) {
    for (const key of ["goal", "comments", "events", "plan", "approvals", "artifacts", "validations", "context", "acceptanceCriteria", "capabilities", "outcome", "budget"]) {
      assert.equal(key in item, false, `summary must omit ${key}`);
    }
  }
  const compact = summary.value.runs[0];
  assert.deepEqual(compact, {
    id: "run-c",
    title: huge.title,
    status: "completed",
    riskClass: "local-draft",
    logicalWorkId: "work-1",
    attempt: { id: "work-1-attempt-1", number: 1, triggerId: "schedule", triggerType: "schedule" },
    createdAt: at(50),
    updatedAt: at(50),
    ...(huge.startedAt ? { startedAt: huge.startedAt } : {}),
    ...(huge.completedAt ? { completedAt: huge.completedAt } : {}),
    counts: {
      comments: 3, events: huge.events.length, approvals: 0, pendingApprovals: 0,
      artifacts: 1, reviewRequiredArtifacts: 1, validations: 1, failedValidations: 1, planSteps: 2,
    },
  });
  const bounded = cliJson(["--status", "queued", "--status", "running", "--summary", "--limit", "2"]).value;
  assert.deepEqual(bounded.runs.map((run) => run.id), ["run-f", "run-a"]);
  assert.equal(bounded.page.nextOffset, 2);

  // Text output names the continuation for bounded requests.
  const text = cli(["--status", "queued", "--summary", "--limit", "1"]);
  assert.equal(text.status, 0, text.stderr);
  assert.equal(text.stdout, "run-a\tqueued\tSynthetic goal for run-a\nShowing 1-1 of 2; next page: --offset 1\n");

  // Invalid options fail instead of returning a misleading empty or partial list.
  cliError(["--status", "queud"], /invalid run status: queud; expected one of: queued, running/);
  cliError(["--status", "queued", "--status", "runing"], /invalid run status: runing/);
  cliError(["--status"], /--status requires a value/);
  cliError(["--limit", "0"], /--limit must be a positive integer: 0/);
  cliError(["--limit", "-1"], /--limit must be a positive integer/);
  cliError(["--limit", "1.5"], /--limit must be a positive integer/);
  cliError(["--limit", "ten"], /--limit must be a positive integer/);
  cliError(["--limit"], /--limit must be a positive integer: missing value/);
  cliError(["--limit", "2", "--limit", "3"], /--limit may be given only once/);
  cliError(["--offset", "-2"], /--offset must be a non-negative integer/);
  cliError(["--summary", "yes"], /--summary does not take a value/);
  assert.throws(() => workspaceRunList(root, { statuses: ["done"] }), /invalid run status: done/);
  assert.throws(() => workspaceRunList(root, { limit: 0 }), /limit must be a positive integer/);
  assert.throws(() => workspaceRunList(root, { offset: -1 }), /offset must be a non-negative integer/);
  assert.throws(() => workspaceRunList(root, { limit: 1.5 }), /limit must be a positive integer/);

  // A bounded query projects only records that can still reach the page.
  const projected = [];
  const page = queryAgentRuns(root, { limit: 1, project: (run) => { projected.push(run.id); return run.id; } });
  assert.deepEqual(page.items, ["run-c"]);
  assert.equal(page.total, 7);
  // With room for one record, a run is projected only when it outranks every
  // run projected before it; older runs are discarded without projection.
  const rank = (id) => all.findIndex((run) => run.id === id);
  for (let index = 1; index < projected.length; index++) assert.ok(rank(projected[index]) < rank(projected[index - 1]));
  assert.equal(projected.at(-1), "run-c");

  // Unreadable canonical input still fails closed on every list path.
  fs.writeFileSync(path.join(path.dirname(agentRunPath(root, "run-a")), "invalid.org2"), "invalid run");
  assert.throws(() => workspaceRunList(root, { summary: true, limit: 1 }), /machine-state JSON/);
  cliError(["--summary", "--limit", "1"], /machine-state JSON/);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

// Bounded pages report roll-ups only for logical-work groups on the page, so a
// one-run page stays small however many workflow groups the history holds.
const groupsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-run-list-groups-"));
try {
  const save = (run) => {
    fs.mkdirSync(path.dirname(agentRunPath(groupsRoot, run.id)), { recursive: true });
    fs.writeFileSync(agentRunPath(groupsRoot, run.id), renderAgentRunOrg(run));
  };
  const attemptRun = (id, group, number, status, now) => createAgentRun({
    id, goal: `Synthetic scheduled work ${id}.`, status, now, logicalWorkId: group,
    attempt: { id: `${group}-attempt-${number}`, number, triggerId: "schedule", triggerType: "schedule" },
  });
  const groupCount = 200;
  for (let index = 0; index < groupCount; index++) {
    save(attemptRun(`group-${index}-run`, `group-${index}`, 1, "queued", new Date(Date.UTC(2026, 9, 1, 1, 0, index)).toISOString()));
  }
  save(attemptRun("selected-run-3", "selected-group", 3, "running", "2026-10-02T00:00:00.000Z"));
  save(attemptRun("selected-run-2", "selected-group", 2, "queued", "2026-09-30T00:00:01.000Z"));
  save(attemptRun("selected-run-1", "selected-group", 1, "completed", "2026-09-30T00:00:00.000Z"));
  const total = groupCount + 3;
  const run = (args) => {
    const result = spawnSync("node", ["dist/cli.js", "run", "list", "--dir", groupsRoot, ...args, "--json"], { cwd: repo, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    assert.equal(result.status, 0, result.stderr);
    return { value: JSON.parse(result.stdout), bytes: Buffer.byteLength(result.stdout) };
  };

  const first = run(["--summary", "--limit", "1"]);
  assert.deepEqual(first.value.runs.map((item) => item.id), ["selected-run-3"]);
  assert.deepEqual(first.value.page, { total, offset: 0, limit: 1, returned: 1, hasMore: true, nextOffset: 1 });
  assert.deepEqual(first.value.logicalWork, [{
    logicalWorkId: "selected-group", attempts: 3, queued: 1, running: 1, blocked: 0, terminal: 1,
    latestRunId: "selected-run-3", latestAttemptNumber: 3, latestStatus: "running", updatedAt: "2026-10-02T00:00:00.000Z",
  }]);
  assert.ok(first.bytes < 4_000, `one-run page should stay small, got ${first.bytes} bytes`);
  assert.deepEqual(workspaceRunList(groupsRoot, { summary: true, limit: 1 }).logicalWork, first.value.logicalWork);

  // Counts cover matching attempts only when a status filter applies.
  const running = run(["--status", "running", "--summary", "--limit", "1"]).value;
  assert.deepEqual(running.logicalWork.map((item) => [item.logicalWorkId, item.attempts]), [["selected-group", 1]]);

  // The next page names only its own group.
  const second = run(["--summary", "--limit", "1", "--offset", "1"]).value;
  assert.deepEqual(second.runs.map((item) => item.id), [`group-${groupCount - 1}-run`]);
  assert.deepEqual(second.logicalWork.map((item) => [item.logicalWorkId, item.attempts]), [[`group-${groupCount - 1}`, 1]]);

  const last = run(["--summary", "--limit", "2", "--offset", String(total - 2)]).value;
  assert.deepEqual(last.runs.map((item) => item.id), ["selected-run-2", "selected-run-1"]);
  assert.deepEqual(last.logicalWork.map((item) => [item.logicalWorkId, item.attempts, item.latestRunId]), [["selected-group", 3, "selected-run-3"]]);

  for (const offset of [String(total), "5000"]) {
    const beyond = run(["--summary", "--limit", "1", "--offset", offset]).value;
    assert.deepEqual(beyond.runs, []);
    assert.deepEqual(beyond.logicalWork, []);
    assert.deepEqual(beyond.page, { total, offset: Number(offset), limit: 1, returned: 0, hasMore: false, nextOffset: null });
  }

  // Default and status-only envelopes keep roll-ups for every matching group.
  const legacy = run([]).value;
  assert.equal(legacy.runs.length, total);
  assert.equal(legacy.logicalWork.length, groupCount + 1);
  assert.deepEqual(legacy.logicalWork, JSON.parse(JSON.stringify(summarizeAgentRunAttempts(listAgentRuns(groupsRoot)))));
  const queued = run(["--status", "queued"]).value;
  assert.deepEqual(Object.keys(queued), ["schema", "runs", "logicalWork"]);
  assert.equal(queued.logicalWork.length, groupCount + 1);
  assert.equal(queued.logicalWork.find((item) => item.logicalWorkId === "selected-group").attempts, 1);
} finally {
  fs.rmSync(groupsRoot, { recursive: true, force: true });
}
console.log("run list bounds tests passed");
