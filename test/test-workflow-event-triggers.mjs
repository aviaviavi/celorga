import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  loadWorkflow,
  markWorkflowTriggerAttempt,
  promptAutomation,
  recordWorkflowSignals,
  saveWorkflow,
  validateWorkflow,
  workflowEventTriggerWindows,
  workflowTriggerEligibility,
} from "../dist/agentWorkflow.js";
import {
  detectTodoStateTransitions,
  detectTodoStateTransitionsInText,
  extractTodoHeadings,
  githubCursorPath,
  observeTodoStateTransitions,
  pollGithubPullRequests,
  todoStateSnapshotPath,
  todoStateTriggerMatches,
  workflowPathGlobMatches,
} from "../dist/workflowEventTriggers.js";

const cli = path.resolve("dist/cli.js");
const run = (args, options = {}) => {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", ...options });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
};

const roots = [];
const tempCorpus = (config = {}) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-event-triggers-"));
  roots.push(root);
  fs.writeFileSync(path.join(root, "celorga.json"), `${JSON.stringify(config)}\n`);
  return root;
};

function automation(id, triggers, extra = {}) {
  const workflow = promptAutomation({ id, title: `Synthetic ${id}`, instructions: "Handle the triggering item.", state: "active", now: "2026-01-01T00:00:00Z" });
  return { ...workflow, triggers: [...workflow.triggers, ...triggers], ...extra };
}

try {
  // --- Path globs -----------------------------------------------------------
  assert.equal(workflowPathGlobMatches("notes/**", "notes/a/b.org"), true);
  assert.equal(workflowPathGlobMatches("notes/**/*.org", "notes/b.org"), true);
  assert.equal(workflowPathGlobMatches("notes/*.org", "notes/a/b.org"), false);
  assert.equal(workflowPathGlobMatches("projects", "projects/x.org"), true);
  assert.equal(workflowPathGlobMatches("projects", "projects-old/x.org"), false);
  assert.equal(workflowPathGlobMatches("inbox?.org", "inbox2.org"), true);

  // --- Transition detection ------------------------------------------------
  const before = [
    "#+TODO: TODO NEXT | DONE",
    "* Projects :work:",
    "** TODO Draft the onboarding guide",
    ":PROPERTIES:",
    ":ID: guide-1",
    ":AGENT_REF: writer-bot",
    ":END:",
    "** TODO Review the sample budget",
    "** Someday list",
    "",
  ].join("\n");
  const after = [
    "#+TODO: TODO NEXT | DONE",
    "* Projects :work:",
    "** NEXT Draft the onboarding guide (v2)",
    ":PROPERTIES:",
    ":ID: guide-1",
    ":AGENT_REF: writer-bot",
    ":END:",
    "** NEXT Review the sample budget",
    "** Someday list",
    "** NEXT Brand new task :urgent:",
    "",
  ].join("\n");
  const transitions = detectTodoStateTransitionsInText(before, after, "notes/tasks.org");
  assert.deepEqual(transitions.map((item) => [item.title, item.from, item.to, item.headingId ?? null]), [
    ["Draft the onboarding guide (v2)", "TODO", "NEXT", "guide-1"],
    ["Review the sample budget", "TODO", "NEXT", null],
    ["Brand new task", null, "NEXT", null],
  ], "ID match survives a retitle; title fallback pairs headings without IDs; new headings report from null");
  assert.equal(transitions[0].line, 3);
  assert.deepEqual(transitions[0].tags, ["work"], "tags are inherited from ancestors");
  assert.deepEqual(transitions[2].tags, ["work", "urgent"]);
  assert.equal(detectTodoStateTransitionsInText(after, after, "notes/tasks.org").length, 0, "unchanged files have no transitions");

  // Two headings with the same title keep their document order.
  const twinBefore = "#+TODO: TODO NEXT | DONE\n* TODO Follow up\n* TODO Follow up\n";
  const twinAfter = "#+TODO: TODO NEXT | DONE\n* TODO Follow up\n* NEXT Follow up\n";
  assert.deepEqual(detectTodoStateTransitionsInText(twinBefore, twinAfter, "a.org").map((item) => item.line), [3]);

  // A heading with a different ID never pairs by title.
  const idSwap = detectTodoStateTransitions(
    [{ title: "Task", outline: "Task", state: "TODO", id: "old-id", line: 1 }],
    extractTodoHeadings("* TODO Task\n:PROPERTIES:\n:ID: new-id\n:END:\n"),
    "a.org",
  );
  assert.deepEqual(idSwap.map((item) => item.from), [null]);
  // A refiled heading keeps its previous state through its ID.
  const refiled = detectTodoStateTransitions([], extractTodoHeadings("#+TODO: TODO NEXT | DONE\n* NEXT Moved\n:PROPERTIES:\n:ID: moved-1\n:END:\n"), "b.org", new Map([["moved-1", "NEXT"]]));
  assert.equal(refiled.length, 0);

  // File-local TODO sequences come from the shared parser.
  const custom = detectTodoStateTransitionsInText("#+TODO: QUEUED READY | SHIPPED\n* QUEUED Item\n", "#+TODO: QUEUED READY | SHIPPED\n* READY Item\n", "c.org");
  assert.deepEqual(custom.map((item) => [item.from, item.to]), [["QUEUED", "READY"]]);

  // --- Trigger filters -----------------------------------------------------
  const base = { id: "next", type: "todo-state", enabled: true, states: ["NEXT"] };
  assert.equal(todoStateTriggerMatches(base, transitions[1]), true);
  assert.equal(todoStateTriggerMatches({ ...base, states: ["WAITING"] }, transitions[1]), false);
  assert.equal(todoStateTriggerMatches({ ...base, property: "AGENT_REF" }, transitions[0]), true);
  assert.equal(todoStateTriggerMatches({ ...base, property: "AGENT_REF" }, transitions[1]), false);
  assert.equal(todoStateTriggerMatches({ ...base, property: "AGENT_REF=writer-bot" }, transitions[0]), true);
  assert.equal(todoStateTriggerMatches({ ...base, property: "AGENT_REF=other" }, transitions[0]), false);
  assert.equal(todoStateTriggerMatches({ ...base, tags: ["urgent"] }, transitions[2]), true);
  assert.equal(todoStateTriggerMatches({ ...base, tags: ["urgent"] }, transitions[1]), false);
  assert.equal(todoStateTriggerMatches({ ...base, paths: ["notes/**"] }, transitions[1]), true);
  assert.equal(todoStateTriggerMatches({ ...base, paths: ["projects/**"] }, transitions[1]), false);
  assert.equal(todoStateTriggerMatches({ ...base, enabled: false }, transitions[1]), false);

  // --- Validation ----------------------------------------------------------
  const issues = (triggers) => validateWorkflow(automation("validate", triggers)).issues.map((item) => `${item.path} ${item.message}`);
  assert.deepEqual(issues([{ id: "t", type: "todo-state", enabled: true, states: ["NEXT"], coalesce: "5m" }]), []);
  assert.match(issues([{ id: "t", type: "todo-state", enabled: true }]).join("\n"), /states must list at least one TODO keyword/);
  assert.match(issues([{ id: "t", type: "todo-state", enabled: true, states: ["NEXT"], coalesce: "soon" }]).join("\n"), /coalesce must be a duration/);
  assert.match(issues([{ id: "t", type: "todo-state", enabled: true, states: ["NEXT"], coalesce: "25h" }]).join("\n"), /at most 24h/);
  assert.match(issues([{ id: "t", type: "todo-state", enabled: true, states: ["NEXT"], paths: ["../outside"] }]).join("\n"), /corpus-relative path globs/);
  assert.match(issues([{ id: "t", type: "todo-state", enabled: true, states: ["NEXT"], repo: "acme/widgets" }]).join("\n"), /repo applies only to pull-request triggers/);
  assert.match(issues([{ id: "p", type: "pull-request", enabled: true }]).join("\n"), /repo must be a GitHub repository as owner\/name/);
  assert.match(issues([{ id: "p", type: "pull-request", enabled: true, repo: "acme/widgets", events: ["pushed"] }]).join("\n"), /unsupported pull-request event: pushed/);
  assert.match(issues([{ id: "p", type: "pull-request", enabled: true, repo: "acme/widgets", number: 0 }]).join("\n"), /positive pull request number/);
  assert.match(issues([{ id: "s", type: "schedule", enabled: true, schedule: "every 1h", coalesce: "5m" }]).join("\n"), /coalesce applies only to todo-state and pull-request triggers/);
  assert.deepEqual(issues([{ id: "p", type: "pull-request", enabled: true, repo: "acme/widgets", events: ["review", "merged"], author: "octo-dev", number: 12 }]), []);

  // --- Coalescing windows --------------------------------------------------
  let coalesced = automation("coalesced", [{ id: "pr", type: "pull-request", enabled: true, repo: "acme/widgets", coalesce: "5m" }]);
  coalesced = recordWorkflowSignals(coalesced, [
    { id: "s1", type: "pull-request", at: "2026-03-01T10:00:00Z", triggerId: "pr" },
    { id: "s2", type: "pull-request", at: "2026-03-01T10:02:00Z", triggerId: "pr" },
    { id: "s3", type: "pull-request", at: "2026-03-01T10:07:00Z", triggerId: "pr" },
    { id: "s1", type: "pull-request", at: "2026-03-01T10:09:00Z", triggerId: "pr" },
  ]);
  assert.equal(coalesced.signals.length, 3, "duplicate signal ids are ignored");
  const windows = workflowEventTriggerWindows(coalesced, coalesced.triggers.find((item) => item.id === "pr"), { now: "2026-03-01T10:06:00Z" });
  assert.deepEqual(windows.map((item) => [item.scheduledFor, item.ready, item.signals.map((signal) => signal.id)]), [
    ["2026-03-01T10:05:00.000Z", true, ["s1", "s2"]],
    ["2026-03-01T10:12:00.000Z", false, ["s3"]],
  ]);
  assert.equal(workflowTriggerEligibility(coalesced, "pr", { now: "2026-03-01T10:03:00Z" }).eligible, false);
  assert.match(workflowTriggerEligibility(coalesced, "pr", { now: "2026-03-01T10:03:00Z" }).reason, /coalescing 2 pull-request signals until/);
  const consumed = markWorkflowTriggerAttempt(coalesced, "pr", "2026-03-01T10:05:00.000Z");
  assert.deepEqual(consumed.signals.map((item) => item.id), ["s3"], "consumed detector signals are pruned");
  assert.deepEqual(workflowTriggerEligibility(consumed, "pr", { now: "2026-03-01T10:20:00Z" }).signalIds, ["s3"]);

  // Without coalescing each recording batch is its own attempt.
  let immediate = automation("immediate", [{ id: "pr", type: "pull-request", enabled: true, repo: "acme/widgets" }]);
  immediate = recordWorkflowSignals(immediate, [
    { id: "a", type: "pull-request", at: "2026-03-01T10:00:00Z", triggerId: "pr" },
    { id: "b", type: "pull-request", at: "2026-03-01T10:00:00Z", triggerId: "pr" },
    { id: "c", type: "pull-request", at: "2026-03-01T10:01:00Z", triggerId: "pr" },
  ]);
  assert.deepEqual(workflowEventTriggerWindows(immediate, immediate.triggers[1], { now: "2026-03-01T11:00:00Z" }).map((item) => item.signals.length), [2, 1]);

  // --- CLI: coalesced due → run attempt with combined signals ---------------
  const dueRoot = tempCorpus();
  saveWorkflow(dueRoot, coalesced, { expectedRevision: null });
  const dueList = run(["workflow", "due", "--now", "2026-03-01T10:06:00Z", "--dir", dueRoot, "--json"]);
  const dueEvent = dueList.due.find((item) => item.workflowId === "coalesced");
  assert.equal(dueEvent.triggerType, "pull-request");
  assert.equal(dueEvent.scheduledFor, "2026-03-01T10:05:00.000Z");
  assert.deepEqual(dueEvent.signalIds, ["s1", "s2"]);
  assert.deepEqual(dueList.pending.map((item) => item.signalIds), [["s3"]]);
  assert.deepEqual(dueList.eventSources, { todoState: false, pullRequest: true });
  const attempt = run(["workflow", "run", "coalesced", "--trigger", "pr", "--scheduled-for", dueEvent.scheduledFor, "--dir", dueRoot, "--json"]);
  assert.deepEqual(attempt.run.attempt.signalIds, ["s1", "s2"]);
  assert.deepEqual(attempt.run.attempt.signals.map((item) => item.id), ["s1", "s2"]);
  assert.equal(attempt.run.attempt.triggerType, "pull-request");
  assert.match(attempt.prompt, /ORG2_WORKFLOW_SIGNALS: \[/);
  assert.match(attempt.prompt, /Trigger events \(2\):/);
  const repeat = run(["workflow", "run", "coalesced", "--trigger", "pr", "--scheduled-for", dueEvent.scheduledFor, "--dir", dueRoot, "--json"]);
  assert.equal(repeat.schema, "org2:workflow-run-skipped:v1");
  assert.deepEqual(loadWorkflow(dueRoot, "coalesced").signals.map((item) => item.id), ["s3"]);
  const later = run(["workflow", "due", "--now", "2026-03-01T10:13:00Z", "--dir", dueRoot, "--json"]);
  assert.deepEqual(later.due.filter((item) => item.workflowId === "coalesced").map((item) => item.signalIds), [["s3"]]);
  const early = run(["workflow", "run", "coalesced", "--trigger", "pr", "--now", "2026-03-01T10:08:00Z", "--dir", dueRoot, "--json"]);
  assert.equal(early.schema, "org2:workflow-run-skipped:v1", "an open coalescing window waits");

  // --- CLI: trigger-set / trigger-remove -----------------------------------
  const setRoot = tempCorpus();
  saveWorkflow(setRoot, automation("configured", []), { expectedRevision: null });
  run(["workflow", "trigger-set", "configured", "--trigger", "next", "--type", "todo-state", "--state", "NEXT", "--property", "AGENT_REF", "--path", "notes/**", "--coalesce", "2m", "--dir", setRoot, "--json"]);
  run(["workflow", "trigger-set", "configured", "--trigger", "prs", "--type", "pull-request", "--repo", "acme/widgets", "--pr-event", "review,merged", "--author", "octo-dev", "--dir", setRoot, "--json"]);
  let configured = loadWorkflow(setRoot, "configured");
  assert.deepEqual(configured.triggers.find((item) => item.id === "next"), { id: "next", type: "todo-state", enabled: true, states: ["NEXT"], paths: ["notes/**"], property: "AGENT_REF", coalesce: "2m" });
  assert.deepEqual(configured.triggers.find((item) => item.id === "prs").events, ["review", "merged"]);
  const badSet = spawnSync(process.execPath, [cli, "workflow", "trigger-set", "configured", "--trigger", "bad", "--type", "pull-request", "--repo", "not a repo", "--dir", setRoot], { encoding: "utf8" });
  assert.notEqual(badSet.status, 0);
  assert.match(badSet.stderr, /repo must be a GitHub repository/);
  run(["workflow", "trigger-remove", "configured", "--trigger", "prs", "--dir", setRoot, "--json"]);
  configured = loadWorkflow(setRoot, "configured");
  assert.equal(configured.triggers.some((item) => item.id === "prs"), false);

  // --- CLI: observe end to end ---------------------------------------------
  // NEXT comes from the corpus TODO sequence, resolved by the shared parser.
  const observeRoot = tempCorpus({ todo: { sequences: ["TODO NEXT | DONE"] } });
  fs.mkdirSync(path.join(observeRoot, "notes"));
  const tasks = path.join(observeRoot, "notes", "tasks.org");
  fs.writeFileSync(tasks, "* TODO Write the synthetic report\n:PROPERTIES:\n:ID: report-1\n:AGENT_REF: research-bot\n:END:\n* TODO Unassigned chore\n");
  saveWorkflow(observeRoot, automation("delegate", [{ id: "next", type: "todo-state", enabled: true, states: ["NEXT"], property: "AGENT_REF", paths: ["notes/**"] }]), { expectedRevision: null });
  const baseline = run(["workflow", "observe", "--apply", "--now", "2026-04-01T09:00:00Z", "--dir", observeRoot, "--json"]);
  assert.equal(baseline.status, "ok");
  assert.equal(baseline.signals.length, 0);
  assert.equal(baseline.baselined.includes("notes/tasks.org"), true);
  assert.equal(fs.existsSync(todoStateSnapshotPath(observeRoot)), true);
  const bump = (file) => { const t = new Date(Date.now() + 5_000 + Math.random() * 1_000); fs.utimesSync(file, t, t); };
  fs.writeFileSync(tasks, fs.readFileSync(tasks, "utf8").replaceAll("* TODO", "* NEXT"));
  bump(tasks);
  const snapshotBefore = fs.readFileSync(todoStateSnapshotPath(observeRoot), "utf8");
  const preview = run(["workflow", "observe", "--changed", tasks, "--now", "2026-04-01T09:01:00Z", "--dir", observeRoot, "--json"]);
  assert.equal(preview.applied, false);
  assert.equal(preview.transitions.length, 2);
  assert.equal(preview.signals.length, 1, "only the heading with AGENT_REF matches");
  assert.deepEqual(preview.signals[0].signal.todoState, { file: "notes/tasks.org", line: 1, headingId: "report-1", title: "Write the synthetic report", from: "TODO", to: "NEXT", tags: [] });
  assert.equal(fs.readFileSync(todoStateSnapshotPath(observeRoot), "utf8"), snapshotBefore, "preview does not advance the snapshot");
  assert.equal(loadWorkflow(observeRoot, "delegate").signals, undefined, "preview records nothing");
  const applied = run(["workflow", "observe", "--changed", tasks, "--apply", "--now", "2026-04-01T09:01:00Z", "--dir", observeRoot, "--json"]);
  assert.equal(applied.recorded, 1);
  const again = run(["workflow", "observe", "--apply", "--now", "2026-04-01T09:02:00Z", "--dir", observeRoot, "--json"]);
  assert.equal(again.recorded, 0);
  const observedDue = run(["workflow", "due", "--now", "2026-04-01T09:03:00Z", "--dir", observeRoot, "--json"]);
  const observedItem = observedDue.due.find((item) => item.workflowId === "delegate");
  assert.equal(observedItem.triggerType, "todo-state");
  assert.deepEqual(observedDue.eventSources, { todoState: true, pullRequest: false });
  const observedRun = run(["workflow", "run", "delegate", "--trigger", "next", "--scheduled-for", observedItem.scheduledFor, "--dir", observeRoot, "--json"]);
  assert.equal(observedRun.run.attempt.signals[0].todoState.headingId, "report-1");
  assert.deepEqual(observedRun.run.context.at(-1), { ref: "id:report-1", title: "Write the synthetic report", citation: "notes/tasks.org:1" });
  assert.match(observedRun.prompt, /notes\/tasks\.org:1 “Write the synthetic report” entered NEXT from TODO/);

  // A newly created file with a matching heading fires; a newly added trigger first records a baseline.
  run(["workflow", "trigger-set", "delegate", "--trigger", "any-next", "--type", "todo-state", "--state", "NEXT", "--dir", observeRoot, "--json"]);
  const newFile = path.join(observeRoot, "notes", "fresh.org");
  fs.writeFileSync(newFile, "* NEXT Fresh delegated task\n:PROPERTIES:\n:AGENT_REF: research-bot\n:END:\n");
  const mixed = observeTodoStateTransitions(observeRoot, { changed: [newFile], apply: true, now: "2026-04-01T09:10:00Z" });
  assert.deepEqual(mixed.newTriggers, ["delegate/any-next"]);
  assert.deepEqual(mixed.signals.map((item) => [item.triggerId, item.signal.todoState.from]), [["next", null]]);
  fs.writeFileSync(newFile, "* NEXT Fresh delegated task\n:PROPERTIES:\n:AGENT_REF: research-bot\n:END:\n* NEXT Another task\n");
  bump(newFile);
  const second = observeTodoStateTransitions(observeRoot, { changed: [newFile], apply: true, now: "2026-04-01T09:11:00Z" });
  assert.deepEqual(second.signals.map((item) => item.triggerId), ["any-next"]);

  // Paused workflows and non-owning hosts do not observe.
  const idleRoot = tempCorpus();
  saveWorkflow(idleRoot, { ...automation("paused", [{ id: "next", type: "todo-state", enabled: true, states: ["NEXT"] }]), state: "paused" }, { expectedRevision: null });
  assert.equal(observeTodoStateTransitions(idleRoot, { apply: true }).status, "idle");
  assert.equal(fs.existsSync(todoStateSnapshotPath(idleRoot)), false);
  fs.writeFileSync(path.join(idleRoot, "celorga.json"), JSON.stringify({ automationHostRef: "studio-server" }));
  assert.equal(run(["workflow", "observe", "--apply", "--dir", idleRoot, "--json"]).status, "not-owner");

  // --- Pull-request poller with fixture gh output ----------------------------
  const prRoot = tempCorpus();
  saveWorkflow(prRoot, automation("pr-watch", [
    { id: "reviews", type: "pull-request", enabled: true, repo: "acme/widgets", events: ["review", "comment", "commit", "merged", "closed", "opened"] },
    { id: "mine", type: "pull-request", enabled: true, repo: "acme/widgets", author: "octo-dev", events: ["merged"] },
  ]), { expectedRevision: null });
  const pull = (number, fields) => ({ number, title: `Synthetic change ${number}`, html_url: `https://github.com/acme/widgets/pull/${number}`, user: { login: "octo-dev" }, head: { sha: `sha-${number}-a` }, created_at: "2026-05-01T08:00:00Z", updated_at: "2026-05-01T09:00:00Z", closed_at: null, merged_at: null, ...fields });
  const fixtures = {
    initial: {
      "repos/acme/widgets/pulls?state=all&sort=updated&direction=desc&per_page=50": [pull(7, {}), pull(8, {})],
    },
    later: {
      "repos/acme/widgets/pulls?state=all&sort=updated&direction=desc&per_page=50&page=1": [
        pull(7, { head: { sha: "sha-7-b" }, updated_at: "2026-05-01T10:30:00Z" }),
        pull(8, { merged_at: "2026-05-01T10:15:00Z", closed_at: "2026-05-01T10:15:00Z", updated_at: "2026-05-01T10:15:00Z" }),
        pull(9, { user: { login: "other-dev" }, created_at: "2026-05-01T10:05:00Z", updated_at: "2026-05-01T10:05:00Z" }),
        pull(3, { updated_at: "2026-04-20T00:00:00Z" }),
      ],
      "repos/acme/widgets/pulls/7/reviews?per_page=100": [
        { id: 501, state: "APPROVED", submitted_at: "2026-05-01T10:20:00Z", user: { login: "reviewer-a" } },
        { id: 499, state: "COMMENTED", submitted_at: "2026-04-30T10:00:00Z", user: { login: "reviewer-a" } },
        { id: 502, state: "PENDING", user: { login: "reviewer-b" } },
      ],
      "repos/acme/widgets/issues/7/comments": [{ id: 601, created_at: "2026-05-01T10:25:00Z", user: { login: "reviewer-b" } }],
      "repos/acme/widgets/pulls/7/comments": [],
      "repos/acme/widgets/pulls/8/reviews?per_page=100": [],
      "repos/acme/widgets/issues/8/comments": [],
      "repos/acme/widgets/pulls/8/comments": [],
      "repos/acme/widgets/pulls/9/reviews?per_page=100": [],
      "repos/acme/widgets/issues/9/comments": [],
      "repos/acme/widgets/pulls/9/comments": [],
    },
  };
  const calls = [];
  const fakeGh = (table) => (args) => {
    calls.push(args);
    assert.equal(args[0], "api");
    const endpoint = args.at(-1);
    const response = table[endpoint] ?? table[endpoint.split("?")[0]];
    if (response === undefined) return { status: 1, stdout: "", stderr: `gh: Not Found (HTTP 404) ${endpoint}` };
    return { status: 0, stdout: JSON.stringify(response), stderr: "" };
  };
  const previewBaseline = pollGithubPullRequests(prRoot, { gh: fakeGh(fixtures.initial), now: "2026-05-01T09:30:00Z" });
  assert.deepEqual(previewBaseline.triggers.map((item) => item.status), ["baselined", "baselined"]);
  assert.equal(fs.existsSync(githubCursorPath(prRoot)), false, "preview writes no cursor");
  calls.length = 0;
  const baselinePoll = pollGithubPullRequests(prRoot, { gh: fakeGh(fixtures.initial), now: "2026-05-01T09:30:00Z", apply: true });
  assert.equal(baselinePoll.signals.length, 0);
  const cursorText = fs.readFileSync(githubCursorPath(prRoot), "utf8");
  assert.equal(JSON.parse(cursorText).triggers["pr-watch/reviews"].since, "2026-05-01T09:00:00.000Z");
  assert.doesNotMatch(cursorText, /token|authorization/i);
  assert.equal(calls.length, 1, "repeated endpoints are fetched once per poll");

  const laterPoll = pollGithubPullRequests(prRoot, { gh: fakeGh(fixtures.later), now: "2026-05-01T10:40:00Z", apply: true });
  assert.equal(laterPoll.status, "ok");
  const events = (triggerId) => laterPoll.signals.filter((item) => item.triggerId === triggerId).map((item) => `${item.signal.pullRequest.number}:${item.signal.pullRequest.event}`).sort();
  assert.deepEqual(events("reviews"), ["7:comment", "7:commit", "7:review", "8:merged", "9:opened"]);
  assert.deepEqual(events("mine"), ["8:merged"], "author and event filters apply");
  assert.equal(laterPoll.recorded, 6);
  const review = laterPoll.signals.find((item) => item.signal.pullRequest.event === "review").signal.pullRequest;
  assert.equal(review.actor, "reviewer-a");
  assert.equal(review.url, "https://github.com/acme/widgets/pull/7", "items without their own URL link the pull request");
  assert.equal(JSON.parse(fs.readFileSync(githubCursorPath(prRoot), "utf8")).triggers["pr-watch/reviews"].since, "2026-05-01T10:30:00.000Z");
  const replay = pollGithubPullRequests(prRoot, { gh: fakeGh(fixtures.later), now: "2026-05-01T10:45:00Z", apply: true });
  assert.equal(replay.signals.length, 0, "the cursor and seen keys prevent duplicate signals");
  assert.equal(loadWorkflow(prRoot, "pr-watch").signals.length, 6);

  // gh availability is reported, not guessed.
  const missing = pollGithubPullRequests(prRoot, { gh: () => ({ status: null, stdout: "", stderr: "spawn gh ENOENT", missing: true }) });
  assert.equal(missing.status, "gh-missing");
  assert.match(missing.message, /not installed/);
  const unauthenticated = pollGithubPullRequests(prRoot, { gh: () => ({ status: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login" }) });
  assert.equal(unauthenticated.status, "gh-unauthenticated");
  const failing = pollGithubPullRequests(prRoot, { gh: () => ({ status: 1, stdout: "", stderr: "HTTP 500" }) });
  assert.equal(failing.status, "partial");

  // The CLI uses the gh found on PATH; a fixture executable stands in for it.
  const fakeBin = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-fake-gh-"));
  roots.push(fakeBin);
  const fixtureFile = path.join(fakeBin, "fixture.json");
  fs.writeFileSync(fixtureFile, JSON.stringify(fixtures.initial));
  fs.writeFileSync(path.join(fakeBin, "gh"), `#!${process.execPath}\nconst fs = require("fs");\nconst table = JSON.parse(fs.readFileSync(${JSON.stringify(fixtureFile)}, "utf8"));\nconst endpoint = process.argv.at(-1);\nconst response = table[endpoint] ?? table[endpoint.split("?")[0]];\nif (response === undefined) { process.stderr.write("HTTP 404"); process.exit(1); }\nprocess.stdout.write(JSON.stringify(response));\n`, { mode: 0o755 });
  const cliRoot = tempCorpus();
  saveWorkflow(cliRoot, automation("cli-pr", [{ id: "prs", type: "pull-request", enabled: true, repo: "acme/widgets", coalesce: "5m" }]), { expectedRevision: null });
  const env = { ...process.env, PATH: `${fakeBin}${path.delimiter}${process.env.PATH}` };
  const cliPreview = run(["workflow", "poll", "--source", "github", "--dir", cliRoot, "--json"], { env });
  assert.equal(cliPreview.schema, "org2:workflow-poll:v1");
  assert.equal(cliPreview.applied, false);
  assert.deepEqual(cliPreview.triggers.map((item) => item.status), ["baselined"]);
  run(["workflow", "poll", "--source", "github", "--apply", "--now", "2026-05-01T09:30:00Z", "--dir", cliRoot, "--json"], { env });
  fs.writeFileSync(fixtureFile, JSON.stringify(fixtures.later));
  const cliLater = run(["workflow", "poll", "--source", "github", "--apply", "--now", "2026-05-01T10:40:00Z", "--dir", cliRoot, "--json"], { env });
  assert.equal(cliLater.recorded, 5);
  const cliDue = run(["workflow", "due", "--now", "2026-05-01T10:46:00Z", "--dir", cliRoot, "--json"]);
  assert.equal(cliDue.due.filter((item) => item.workflowId === "cli-pr").length, 1, "one coalesced attempt for five events");
  assert.equal(cliDue.due[0].signalIds.length, 5);
  const badSource = spawnSync(process.execPath, [cli, "workflow", "poll", "--source", "gitlab", "--dir", cliRoot], { encoding: "utf8" });
  assert.notEqual(badSource.status, 0);
  assert.match(badSource.stderr, /unsupported workflow poll source/);

  console.log("workflow event trigger tests passed");
} finally {
  for (const root of roots) fs.rmSync(root, { recursive: true, force: true });
}
