import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { loadAgentRunSnapshot, saveAgentRun, transitionAgentRun, updateAgentRunRuntime } from "../dist/agentRun.js";
import { loadWorkflow } from "../dist/agentWorkflow.js";
import { createGoal, loadGoalSnapshot, saveGoal } from "../dist/coordination.js";
import { parseGoalPlan } from "../dist/goalDrive.js";

const cli = path.resolve("dist/cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-goal-drive-"));

function celorga(...args) {
  const result = spawnSync(process.execPath, [cli, ...args, "--dir", root], { encoding: "utf8" });
  assert.equal(result.status, 0, `celorga ${args.join(" ")} failed:\n${result.stderr}\n${result.stdout}`);
  return result.stdout;
}

function json(...args) {
  return JSON.parse(celorga(...args, "--json"));
}

/** Simulates the scheduler starting one pass and the agent finishing it. */
function pass(now, { cost, edit } = {}) {
  const started = json("workflow", "run", "goal-drive-launch-newsletter", "--trigger", "schedule", "--scheduled-for", now, "--now", now);
  if (!started.run) return started;
  if (edit) edit();
  const snapshot = loadAgentRunSnapshot(root, started.run.id);
  let run = transitionAgentRun(snapshot.run, "running", { now });
  if (cost) run = updateAgentRunRuntime(run, { costUsedUsd: cost, tokensUsed: 1000, now });
  run = transitionAgentRun(run, "completed", { summary: "Pass finished.", now });
  saveAgentRun(root, run, { expectedRevision: snapshot.revision });
  return { ...started, checkpoint: json("goal", "checkpoint", "launch-newsletter", "--run", run.id, "--now", now, "--apply") };
}

function editGoal(transform) {
  const file = loadGoalSnapshot(root, "launch-newsletter").file;
  fs.writeFileSync(file, transform(fs.readFileSync(file, "utf8")));
}

try {
  // A goal file with user-owned parts that a structured save must keep.
  const goal = createGoal({ id: "launch-newsletter", title: "Launch the community newsletter", measures: ["First issue sent to subscribers"], now: "2030-01-01T00:00:00.000Z" });
  saveGoal(root, goal, { expectedRevision: null });
  const goalFile = loadGoalSnapshot(root, goal.id).file;
  const generated = fs.readFileSync(goalFile, "utf8");
  fs.writeFileSync(goalFile, [
    ":PROPERTIES:",
    ":ID: 11111111-2222-4333-8444-555555555555",
    ":END:",
    "",
    generated.replace("** Machine state", "** Working context\n- Keep the tone friendly.\n\n** Machine state"),
  ].join("\n"));

  // goal update must not drop sections Celorga does not generate.
  celorga("goal", "update", goal.id, "--description", "Ship issue one.", "--apply");
  let raw = fs.readFileSync(goalFile, "utf8");
  assert.match(raw, /^:PROPERTIES:\n:ID: 11111111-2222-4333-8444-555555555555\n:END:\n\n#\+TITLE:/);
  assert.match(raw, /\*\* Working context\n- Keep the tone friendly\./);
  assert.match(raw, /Ship issue one\./);

  // Preview writes nothing; apply records the drive, a Plan section, and a one-at-a-time driver workflow.
  const preview = json("goal", "drive", goal.id, "--every", "15m", "--stall-after", "2", "--daily-cost-limit", "1", "--permit", "Edit drafts in drafts/");
  assert.equal(preview.applied, false);
  assert.equal(fs.existsSync(path.join(root, "workflows", "goal-drive-launch-newsletter.org")), false);
  const started = json("goal", "drive", goal.id, "--every", "15m", "--stall-after", "2", "--daily-cost-limit", "1", "--permit", "Edit drafts in drafts/", "--apply");
  assert.equal(started.applied, true);
  assert.equal(started.status.mode, "plan");
  raw = fs.readFileSync(goalFile, "utf8");
  assert.match(raw, /\*\* Drive\n- State: driving/);
  assert.match(raw, /\*\* Plan\n/);
  assert.match(raw, /\*\* Working context/);
  assert.match(raw, /:ID: 11111111-2222-4333-8444-555555555555/);
  const workflow = loadWorkflow(root, "goal-drive-launch-newsletter");
  assert.equal(workflow.goalRef, goal.id);
  assert.equal(workflow.state, "active");
  const schedule = workflow.triggers.find((trigger) => trigger.type === "schedule");
  assert.equal(schedule.schedule, "every 15m");
  assert.equal(schedule.whenRunning, "wait");
  assert.equal(schedule.whenBlocked, "wait");
  assert.match(workflow.instructions, /celorga goal checkpoint launch-newsletter --run RUN_ID --apply/);
  assert.match(workflow.instructions, /Edit drafts in drafts\//);

  // Plan parsing: actors, terminal states, unknown actors, and checkboxes.
  const plan = parseGoalPlan([
    "* TODO Goal :goal:",
    "** Plan",
    "*** TODO Draft the first issue",
    "- [X] outline",
    "- [ ] body",
    "*** TODO Approve the sender address",
    ":PROPERTIES:",
    ":ACTOR: human",
    ":END:",
    "*** TODO Wait for the designer",
    ":PROPERTIES:",
    ":ACTOR: external",
    ":END:",
    "*** DONE Pick a name",
    "*** TODO Mystery",
    ":PROPERTIES:",
    ":ACTOR: robot",
    ":END:",
    "** Notes",
    "*** TODO Not a plan item",
  ].join("\n"));
  assert.deepEqual(plan.open, { agent: 1, human: 2, external: 1 });
  assert.equal(plan.done, 1);
  assert.deepEqual(plan.checkboxes, { checked: 1, total: 2 });
  assert.equal(plan.items.length, 5);
  assert.match(plan.issues[0], /unknown :ACTOR: robot/);
  // Checking a box is progress; prose notes are not.
  const planSource = ["* TODO Goal", "** Plan", "*** TODO Draft", "- [ ] outline"].join("\n");
  const baseline = parseGoalPlan(planSource).fingerprint;
  assert.notEqual(parseGoalPlan(planSource.replace("[ ]", "[X]")).fingerprint, baseline);
  assert.equal(parseGoalPlan(`${planSource}\nStill thinking about this.`).fingerprint, baseline);

  // First pass: plan mode. The agent writes two plan items, which counts as progress.
  const first = pass("2030-01-02T00:00:00.000Z", {
    cost: 0.4,
    edit: () => editGoal((text) => text.replace(/(\*\* Plan\n.*\n)/, "$1*** TODO Draft the first issue\n*** TODO Approve the sender address\n:PROPERTIES:\n:ACTOR: human\n:END:\n")),
  });
  assert.equal(first.checkpoint.progress, true);
  assert.equal(first.checkpoint.passesWithoutProgress, 0);
  // Checkpointing the same run again is a no-op.
  const again = json("goal", "checkpoint", goal.id, "--run", first.run.id, "--apply");
  assert.equal(again.idempotent, true);
  assert.equal(again.applied, false);

  let status = json("goal", "status", goal.id, "--now", "2030-01-02T00:20:00.000Z");
  assert.equal(status.mode, "work");
  assert.equal(status.next[0].title, "Draft the first issue");
  assert.equal(status.needsYou[0].title, "Approve the sender address");
  assert.equal(status.spend.passes, 1);
  assert.equal(status.spend.costUsd, 0.4);

  // Two passes without a plan change stall the drive (stall-after 2), and the scheduler then skips it.
  pass("2030-01-02T00:30:00.000Z", { cost: 0.1 });
  const stalled = pass("2030-01-02T01:00:00.000Z", { cost: 0.1 });
  assert.equal(stalled.checkpoint.stalled, true);
  assert.equal(stalled.checkpoint.state, "stalled");
  assert.match(fs.readFileSync(goalFile, "utf8"), /- State: stalled \(2 consecutive passes left the plan unchanged\)/);
  let due = json("workflow", "due", "--now", "2030-01-02T02:00:00.000Z");
  assert.equal(due.due.length, 0);
  assert.equal(due.skipped[0].goalDriveMode, "stalled");
  const skippedRun = json("workflow", "run", "goal-drive-launch-newsletter", "--trigger", "schedule", "--scheduled-for", "2030-01-02T02:00:00.000Z", "--now", "2030-01-02T02:00:00.000Z");
  assert.equal(skippedRun.eligible, false);
  assert.equal(skippedRun.goalDriveMode, "stalled");

  // --clear-permits removes standing permissions; --permit replaces them.
  assert.deepEqual(json("goal", "drive", goal.id, "--clear-permits").goal.drive.permissions, []);
  assert.deepEqual(json("goal", "drive", goal.id, "--permit", "Edit drafts in drafts/", "--permit", "Open pull requests").goal.drive.permissions, ["Edit drafts in drafts/", "Open pull requests"]);

  // Resume clears the stall. The daily budget ($0.6 spent of $1) still admits a pass.
  celorga("goal", "drive", goal.id, "--resume", "--apply");
  status = json("goal", "status", goal.id, "--now", "2030-01-02T02:00:00.000Z");
  assert.equal(status.mode, "work");
  assert.equal(status.drive.passesWithoutProgress, 0);

  // The agent finishes its only agent item; with a human item left and no plan change since, the drive waits.
  pass("2030-01-02T02:00:00.000Z", { cost: 0.5, edit: () => editGoal((text) => text.replace("*** TODO Draft the first issue", "*** DONE Draft the first issue")) });
  status = json("goal", "status", goal.id, "--now", "2030-01-02T02:20:00.000Z");
  assert.equal(status.eligible, false);
  assert.equal(status.mode, "over-budget");
  // A day later the budget window has passed, and the remaining human item holds the drive.
  status = json("goal", "status", goal.id, "--now", "2030-01-03T03:00:00.000Z");
  assert.equal(status.mode, "waiting");
  assert.match(status.reason, /waiting on 1 human and 0 external plan item/);
  due = json("workflow", "due", "--now", "2030-01-03T03:00:00.000Z");
  assert.equal(due.due.length, 0);
  assert.equal(due.skipped[0].goalDriveMode, "waiting");

  // A person handles the human item; the changed plan admits one replan pass.
  editGoal((text) => text.replace("*** TODO Approve the sender address", "*** DONE Approve the sender address"));
  status = json("goal", "status", goal.id, "--now", "2030-01-03T03:00:00.000Z");
  assert.equal(status.mode, "replan");
  assert.equal(status.eligible, true);
  due = json("workflow", "due", "--now", "2030-01-03T03:00:00.000Z");
  assert.equal(due.due[0].workflowId, "goal-drive-launch-newsletter");
  pass("2030-01-03T03:00:00.000Z");
  status = json("goal", "status", goal.id, "--now", "2030-01-03T03:20:00.000Z");
  assert.equal(status.mode, "complete");
  assert.equal(status.eligible, false);

  // Pause and stop are explicit; stop keeps the workflow file and run history but pauses its schedule.
  celorga("goal", "drive", goal.id, "--pause", "--apply");
  assert.equal(json("goal", "status", goal.id).mode, "paused");
  celorga("goal", "drive", goal.id, "--stop", "--apply");
  assert.equal(json("goal", "status", goal.id).mode, "not-driving");
  assert.equal(loadWorkflow(root, "goal-drive-launch-newsletter").state, "paused");
  raw = fs.readFileSync(goalFile, "utf8");
  assert.doesNotMatch(raw, /\*\* Drive\n/);
  assert.match(raw, /\*\* Plan\n/);
  assert.match(raw, /\*\* Working context/);

  // Ordinary automations are not gated by goal drives.
  celorga("workflow", "create", "plain-digest", "--title", "Plain digest", "--prompt", "Summarize.", "--schedule", "every 1h", "--goal-ref", goal.id, "--now", "2030-01-01T00:00:00.000Z");
  due = json("workflow", "due", "--now", "2030-01-04T00:00:00.000Z");
  assert.ok(due.due.some((item) => item.workflowId === "plain-digest"));

  // A non-active goal cannot be driven.
  const planned = createGoal({ id: "someday", title: "Someday", status: "planned" });
  saveGoal(root, planned, { expectedRevision: null });
  const refused = spawnSync(process.execPath, [cli, "goal", "drive", "someday", "--dir", root], { encoding: "utf8" });
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /set it active before driving it/);

  console.log("goal drive: ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
