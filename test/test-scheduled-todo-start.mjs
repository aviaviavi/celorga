#!/usr/bin/env node
// An assigned TODO that opts in with :AGENT_START: scheduled starts one
// durable run when its SCHEDULED time passes, through `workflow due` and
// `workflow start-todo`. Times use an injected clock in UTC.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  latestScheduledOccurrence,
  parseScheduledTimestamp,
  scheduledTodoIdempotencyKey,
} from "../dist/scheduledTodoStart.js";

process.env.TZ = "UTC";
const cli = path.resolve("dist/cli.js");
const env = { ...process.env, TZ: "UTC" };
const run = (args) => {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", env });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
};

// Occurrence rules.
const once = parseScheduledTimestamp("<2026-11-05 Thu 09:00>");
assert.equal(latestScheduledOccurrence(once, new Date("2026-11-05T08:59:00Z")), null);
assert.equal(latestScheduledOccurrence(once, new Date("2026-11-05T09:00:00Z")).toISOString(), "2026-11-05T09:00:00.000Z");
assert.equal(parseScheduledTimestamp("<2026-11-05 Thu>"), null, "a date without a time of day is not startable");
assert.equal(parseScheduledTimestamp("[2026-11-05 Thu 09:00]"), null, "inactive timestamps do not schedule");
const daily = parseScheduledTimestamp("<2026-11-01 Sun 07:30 +1d>");
assert.equal(latestScheduledOccurrence(daily, new Date("2026-11-04T08:00:00Z")).toISOString(), "2026-11-04T07:30:00.000Z");
assert.equal(latestScheduledOccurrence(daily, new Date("2026-11-04T07:00:00Z")).toISOString(), "2026-11-03T07:30:00.000Z");
const monthly = parseScheduledTimestamp("<2026-01-15 Thu 10:00 .+1m>");
assert.equal(latestScheduledOccurrence(monthly, new Date("2026-04-20T00:00:00Z")).toISOString(), "2026-04-15T10:00:00.000Z");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-scheduled-start-"));
fs.writeFileSync(path.join(root, "celorga.json"), "{}\n");
fs.mkdirSync(path.join(root, "notes"));
const tasks = path.join(root, "notes", "tasks.org");
fs.writeFileSync(tasks, `#+TITLE: Synthetic tasks

* TODO Draft the launch checklist
SCHEDULED: <2026-11-05 Thu 09:00>
:PROPERTIES:
:ID: 0d6c1e1a-1111-4a1a-8a1a-000000000001
:AGENT_REF: research-assistant
:GOAL_REF: spring-launch
:AGENT_START: scheduled
:END:
Collect the open items.

* TODO Review the weekly metrics
SCHEDULED: <2026-11-01 Sun 07:30 +1d>
:PROPERTIES:
:ID: 0d6c1e1a-2222-4a1a-8a1a-000000000002
:AGENT_REF: metrics-analyst
:AGENT_START: scheduled
:END:

* TODO Not opted in
SCHEDULED: <2026-11-01 Sun 08:00>
:PROPERTIES:
:ID: 0d6c1e1a-3333-4a1a-8a1a-000000000003
:AGENT_REF: research-assistant
:END:

* TODO No worker named
SCHEDULED: <2026-11-01 Sun 08:00>
:PROPERTIES:
:ID: 0d6c1e1a-4444-4a1a-8a1a-000000000004
:AGENT_START: scheduled
:END:

* DONE Already finished
SCHEDULED: <2026-11-01 Sun 08:00>
:PROPERTIES:
:ID: 0d6c1e1a-5555-4a1a-8a1a-000000000005
:AGENT_REF: research-assistant
:AGENT_START: scheduled
:END:

* TODO Missing an ID
SCHEDULED: <2026-11-01 Sun 08:00>
:PROPERTIES:
:AGENT_REF: research-assistant
:AGENT_START: scheduled
:END:

* TODO Date only
SCHEDULED: <2026-11-01 Sun>
:PROPERTIES:
:ID: 0d6c1e1a-6666-4a1a-8a1a-000000000006
:AGENT_REF: research-assistant
:AGENT_START: scheduled
:END:
`);

const due = (now) => run(["workflow", "due", "--now", now, "--dir", root, "--json"]).scheduledTodoStarts;
const LAUNCH = "0d6c1e1a-1111-4a1a-8a1a-000000000001";
const METRICS = "0d6c1e1a-2222-4a1a-8a1a-000000000002";

// Before the launch item's time only the daily repeater is due, once, for
// its latest missed occurrence.
let list = due("2026-11-05T08:59:00Z");
assert.deepEqual(list.due.map((item) => [item.id, item.scheduledFor]), [[METRICS, "2026-11-05T07:30:00.000Z"]]);
assert.equal(list.due[0].kind, "scheduled-todo-start");
assert.equal(list.due[0].idempotencyKey, scheduledTodoIdempotencyKey(METRICS, "2026-11-05T07:30:00.000Z"));
const reasons = Object.fromEntries(list.notStartable.map((item) => [item.title, item.reason]));
assert.deepEqual(Object.keys(reasons).sort(), ["Date only", "Missing an ID", "No worker named"]);
assert.match(reasons["Missing an ID"], /Add an :ID:/);
assert.match(reasons["No worker named"], /AGENT_REF/);
assert.match(reasons["Date only"], /time of day/);
assert.ok(!JSON.stringify(list).includes("Not opted in"));
assert.ok(!JSON.stringify(list).includes("Already finished"));

// After 09:00 the launch item is due too. Preview writes nothing.
list = due("2026-11-05T09:01:00Z");
assert.deepEqual(list.due.map((item) => item.id), [LAUNCH, METRICS]);
const preview = run(["workflow", "start-todo", "--id", LAUNCH, "--now", "2026-11-05T09:01:00Z", "--dir", root, "--json"]);
assert.equal(preview.status, "preview");
assert.equal(preview.applied, false);
assert.match(preview.prompt, /^Start work on this TODO from my corpus\./);
assert.equal(fs.readFileSync(tasks, "utf8").includes("ORG2_RUN_ID"), false);
assert.equal(run(["run", "list", "--dir", root, "--json"]).runs?.length ?? 0, 0);

// Apply starts exactly one run and links the heading the way Start work does.
const started = run(["workflow", "start-todo", "--id", LAUNCH, "--scheduled-for", list.due[0].scheduledFor, "--now", "2026-11-05T09:01:00Z", "--apply", "--dir", root, "--json"]);
assert.equal(started.status, "started", JSON.stringify(started));
assert.equal(started.run.status, "running");
assert.equal(started.run.agentRef, "research-assistant");
assert.equal(started.run.goalRef, "spring-launch");
assert.equal(started.run.logicalWorkId, `scheduled-start:${LAUNCH}`);
assert.equal(started.run.attempt.scheduledFor, "2026-11-05T09:00:00.000Z");
assert.deepEqual(started.run.context.map((item) => item.ref), [`id:${LAUNCH}`]);
assert.equal(started.heading.changed, true);
const linkedText = fs.readFileSync(tasks, "utf8");
assert.match(linkedText, new RegExp(`\\* IN_PROGRESS Draft the launch checklist[\\s\\S]*?:ORG2_RUN_ID: ${started.run.id}`));

// Not twice: the occurrence is now skipped, and a repeated start is refused.
list = due("2026-11-05T09:30:00Z");
assert.deepEqual(list.due.map((item) => item.id), [METRICS]);
assert.equal(list.skipped.find((item) => item.id === LAUNCH)?.activeRunId, started.run.id);
const again = run(["workflow", "start-todo", "--id", LAUNCH, "--now", "2026-11-05T09:30:00Z", "--apply", "--dir", root, "--json"]);
assert.equal(again.status, "skipped");
assert.equal(run(["run", "list", "--dir", root, "--json"]).runs.length, 1);

// The repeater starts once for its latest missed occurrence; while that run
// is live, the next day's occurrence waits instead of starting a second run.
const metrics = run(["workflow", "start-todo", "--id", METRICS, "--now", "2026-11-05T09:30:00Z", "--apply", "--dir", root, "--json"]);
assert.equal(metrics.status, "started");
assert.equal(metrics.run.attempt.scheduledFor, "2026-11-05T07:30:00.000Z");
list = due("2026-11-06T08:00:00Z");
assert.equal(list.due.length, 0, JSON.stringify(list.due));
assert.match(list.skipped.find((item) => item.id === METRICS).reason, /already has running run/);
// Once that run finishes, the next occurrence (and only the latest) is due.
run(["run", "complete", metrics.run.id, "--summary", "Reviewed the synthetic metrics.", "--dir", root, "--json"]);
list = due("2026-11-08T08:00:00Z");
assert.deepEqual(list.due.map((item) => [item.id, item.scheduledFor]), [[METRICS, "2026-11-08T07:30:00.000Z"]]);

// A done TODO is ignored even when it opts in.
assert.match(fs.readFileSync(tasks, "utf8"), /\* IN_PROGRESS Review the weekly metrics/);
fs.writeFileSync(tasks, fs.readFileSync(tasks, "utf8").replace("* IN_PROGRESS Review the weekly metrics", "* DONE Review the weekly metrics"));
assert.equal(due("2026-11-08T08:00:00Z").due.length, 0);

// The automation owner gate applies, like workflow schedules.
fs.writeFileSync(path.join(root, "celorga.json"), `${JSON.stringify({ automationHostRef: "server" })}\n`);
const notOwner = run(["workflow", "start-todo", "--id", METRICS, "--apply", "--dir", root, "--json"]);
assert.equal(notOwner.status, "not-owner");
fs.writeFileSync(path.join(root, "celorga.json"), "{}\n");

// `todo assign --start scheduled` opts a heading in.
const assignFile = path.join(root, "notes", "assign.org");
fs.writeFileSync(assignFile, "* TODO Prepare the board summary\nSCHEDULED: <2026-12-01 Tue 10:00>\n");
const assigned = run(["todo", "assign", "--file", assignFile, "--line", "1", "--assignee", "Research Assistant", "--agent-ref", "research-assistant", "--start", "scheduled", "--apply", "--format", "json"]);
assert.equal(assigned.agentStart, "scheduled");
assert.match(fs.readFileSync(assignFile, "utf8"), /:AGENT_START: scheduled/);
const badStart = spawnSync(process.execPath, [cli, "todo", "assign", "--file", assignFile, "--line", "1", "--assignee", "X", "--start", "now", "--format", "json"], { encoding: "utf8", env });
assert.notEqual(badStart.status, 0);

console.log("✓ scheduled TODO starts");
