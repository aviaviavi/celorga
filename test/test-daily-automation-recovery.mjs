import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-daily-recovery-"));
const cli = path.resolve("dist/cli.js");
const command = (...args) => {
  const result = spawnSync(process.execPath, [cli, ...args, "--dir", root, "--json"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
};
const occurrence = (day) => `2026-10-${day}T06:45:00.000Z`;
const dispatch = (day) => command("workflow", "run", "daily-repair", "--trigger", "schedule", "--scheduled-for", occurrence(day));
const due = (day) => command("workflow", "due", "--now", `2026-10-${day}T06:46:00Z`);

try {
  command("workflow", "create", "daily-repair", "--title", "Daily repair", "--prompt", "Repair today's items.",
    "--destination-ref", "missing-on-host", "--schedule", "45 23 * * *", "--timezone", "America/Los_Angeles",
    "--now", "2026-10-07T23:10:00Z");
  const first = dispatch("08").run;
  command("run", "fail", first.id, "--reason", "The configured AI destination is unavailable or disabled.");

  assert.equal(due("08").due.length, 0, "a failed occurrence is consumed, not repeatedly dispatched");
  const nextDay = due("09");
  assert.equal(nextDay.due[0].scheduledFor, occurrence("09"), "failure must not suppress the next day's occurrence");
  assert.equal(nextDay.skipped.length, 0);
  assert.deepEqual(dispatch("08").run, undefined, "the original failed occurrence remains deduplicated");
  assert.deepEqual(nextDay.failures, [{
    workflowId: "daily-repair", title: "Daily repair", runId: first.id,
    destinationRef: "missing-on-host", scheduledFor: occurrence("08"),
    failure: "The configured AI destination is unavailable or disabled.",
  }], "the scheduler must retain the last failure even when no new occurrence is due");
  assert.deepEqual(due("08").failures, nextDay.failures);

  const second = dispatch("09").run;
  assert.notEqual(second.id, first.id);
  assert.equal(second.logicalWorkId, first.logicalWorkId);
  assert.equal(second.attempt.number, 2);
  assert.deepEqual(due("09").failures, [], "a newer attempt supersedes an old failure warning");
  assert.equal(due("10").skipped[0].activeRunId, second.id, "queued work still prevents overlap");
  assert.equal(dispatch("10").activeRunId, second.id);

  command("run", "fail", second.id, "--reason", "Second day's dispatch failed.");
  assert.equal(due("10").failures[0].runId, second.id);
  assert.equal(due("10").due[0].scheduledFor, occurrence("10"));
  const third = dispatch("10").run;
  assert.equal(third.attempt.number, 3);
  command("run", "cancel", third.id);
  assert.equal(due("11").due[0].scheduledFor, occurrence("11"), "canceled attempts also permit the next day");
  assert.deepEqual(due("11").failures, []);

  // A blocked attempt is parked on a person; by default it must not stall
  // the next day's occurrence (Firebolt leads stalled Oct 13-15 this way).
  const fourth = dispatch("11").run;
  command("run", "start", fourth.id);
  command("run", "block", fourth.id, "--reason", "Restore the missing source partition, then resume this run.");
  const afterBlock = due("12");
  assert.equal(afterBlock.skipped.length, 0, "a blocked attempt must not hold the schedule slot by default");
  assert.equal(afterBlock.due[0].scheduledFor, occurrence("12"));
  const fifth = dispatch("12").run;
  assert.equal(fifth.attempt.number, 5);
  assert.equal(command("run", "show", fourth.id).status, "blocked", "the blocked attempt stays open for review");
  assert.equal(due("13").skipped[0].activeRunId, fifth.id, "a running attempt still prevents overlap");
  assert.equal(command("doctor").findings.some((item) => item.rule === "overlapping-active-attempts"), false,
    "a blocked attempt beside a newer running attempt is expected, not an overlap");

  // Approval-waiting attempts still hold the slot so a gated action cannot be requested twice.
  command("run", "approval-request", fifth.id, "--title", "Send batch", "--action", "Post the batch");
  assert.equal(command("run", "show", fifth.id).status, "waiting-approval");
  assert.equal(due("13").skipped[0].activeRunId, fifth.id, "waiting-approval still prevents overlap");
  command("run", "cancel", fifth.id);

  // Opting in with --when-blocked wait restores the hold, and re-saving only the cron keeps it.
  const scheduled = command("workflow", "schedule", "daily-repair", "--cron", "45 23 * * *",
    "--timezone", "America/Los_Angeles", "--when-blocked", "wait");
  assert.equal(scheduled.workflow.triggers.find((item) => item.type === "schedule").whenBlocked, "wait");
  // Re-saving a schedule moves its boundary to wall-clock time, so check due-ness well after it.
  const farDue = () => command("workflow", "due", "--now", "2099-01-01T07:00:00Z");
  const waiting = farDue();
  assert.equal(waiting.due.length, 0);
  assert.equal(waiting.skipped[0].activeRunId, fourth.id, "whenBlocked=wait holds the schedule for the blocked attempt");
  assert.equal(dispatch("13").activeRunId, fourth.id);
  const resaved = command("workflow", "schedule", "daily-repair", "--cron", "45 23 * * *", "--timezone", "America/Los_Angeles");
  assert.equal(resaved.workflow.triggers.find((item) => item.type === "schedule").whenBlocked, "wait");
  const restored = command("workflow", "schedule", "daily-repair", "--cron", "45 23 * * *",
    "--timezone", "America/Los_Angeles", "--when-blocked", "continue");
  assert.equal(restored.workflow.triggers.find((item) => item.type === "schedule").whenBlocked, undefined, "continue is the default and is not written");
  assert.equal(farDue().due.length, 1, "continue releases the blocked attempt's hold again");
  command("run", "cancel", fourth.id);

  command("workflow", "pause", "daily-repair");
  assert.deepEqual(due("11").due, []);
  assert.deepEqual(due("11").failures, []);
  console.log("daily automation recovery and persistent failure diagnostics ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
