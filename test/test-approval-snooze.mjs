#!/usr/bin/env node
// Snoozing approvals: a snoozed approval stays pending with the same fingerprint, is hidden
// from the default `celorga approvals` queue until its time passes, and comes back without any
// background job. Headline approvals snooze the Org way, with a future SCHEDULED date.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  createAgentRun,
  isAgentRunApprovalSnoozed,
  loadAgentRun,
  requestAgentRunApproval,
  resolveApprovalSnoozeUntil,
  saveAgentRun,
  snoozeAgentRunApproval,
  validateAgentRun,
} from "../dist/agentRun.js";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-approval-snooze-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-approval-snooze-index-"));

function cli(args) {
  return execFileSync("node", ["dist/cli.js", ...args], {
    cwd: repo,
    encoding: "utf8",
    env: { ...process.env, ORG2_INDEX_HOME: indexHome },
  });
}

function cliFailure(args) {
  const result = spawnSync("node", ["dist/cli.js", ...args], {
    cwd: repo,
    encoding: "utf8",
    env: { ...process.env, ORG2_INDEX_HOME: indexHome },
  });
  assert.notEqual(result.status, 0, `expected failure: ${args.join(" ")}`);
  return `${result.stdout}${result.stderr}`;
}

function queue(extra = []) {
  return JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json", ...extra]));
}

// --- Model ---------------------------------------------------------------
{
  const now = new Date("2026-10-26T12:00:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("2h", now), "2026-10-26T14:00:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("30m", now), "2026-10-26T12:30:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("1d", now), "2026-10-27T12:00:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("1w", now), "2026-11-02T12:00:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("2026-11-02T09:00:00Z", now), "2026-11-02T09:00:00.000Z");
  assert.equal(resolveApprovalSnoozeUntil("2026-11-02", now), new Date(2026, 10, 2).toISOString());
  assert.throws(() => resolveApprovalSnoozeUntil("soonish", now), /invalid snooze time/);

  let run = createAgentRun({ id: "model-run", goal: "Publish the changelog", now: "2026-10-26T10:00:00.000Z" });
  run = requestAgentRunApproval(run, { title: "Approve changelog", action: "publish changelog", riskClass: "external-action", requestedAt: "2026-10-26T10:00:00.000Z" });
  const approval = run.approvals[0];
  const snoozed = snoozeAgentRunApproval(run, approval.id, "2026-10-27T09:00:00.000Z", { actor: "reviewer", now: "2026-10-26T12:00:00.000Z" });
  const after = snoozed.approvals[0];
  assert.equal(after.status, "pending");
  assert.equal(after.fingerprint, approval.fingerprint, "snoozing must not change approval material");
  assert.equal(after.snoozedUntil, "2026-10-27T09:00:00.000Z");
  assert.equal(after.snoozedBy, "reviewer");
  assert.equal(snoozed.status, run.status, "snoozing does not move the run");
  assert.equal(snoozed.events.at(-1).type, "approval-snoozed");
  assert.equal(validateAgentRun(snoozed).valid, true);
  assert.equal(isAgentRunApprovalSnoozed(after, new Date("2026-10-27T08:59:00.000Z")), true);
  assert.equal(isAgentRunApprovalSnoozed(after, new Date("2026-10-27T09:00:00.000Z")), false, "wakes on time with no job");
  assert.throws(
    () => snoozeAgentRunApproval(run, approval.id, "2026-10-26T11:00:00.000Z", { now: "2026-10-26T12:00:00.000Z" }),
    /must be in the future/,
  );
  assert.throws(
    () => snoozeAgentRunApproval(run, approval.id, "2026-10-27T09:00:00.000Z", { fingerprint: "sha256:stale", now: "2026-10-26T12:00:00.000Z" }),
    /fingerprint/,
  );
  const woken = snoozeAgentRunApproval(snoozed, approval.id, null, { actor: "reviewer", now: "2026-10-26T13:00:00.000Z" });
  assert.equal(woken.approvals[0].snoozedUntil, undefined);
  assert.equal(woken.events.at(-1).type, "approval-woken");
  assert.equal(snoozeAgentRunApproval(woken, approval.id, null), woken, "waking an awake approval is a no-op");
}

// --- CLI: run approvals ----------------------------------------------------
{
  saveAgentRun(tmp, createAgentRun({ id: "snooze-run", goal: "Send the partner update" }), { expectedRevision: null });
  cli(["run", "approval-request", "snooze-run", "--title", "Approve partner update", "--action", "send partner update", "--risk", "external-action", "--dir", tmp, "--json"]);
  cli(["run", "approval-request", "snooze-run", "--title", "Approve invoice", "--action", "send invoice", "--risk", "external-action", "--dir", tmp, "--json"]);

  const before = queue();
  assert.equal(before.count, 2);
  assert.equal(before.snoozedCount, undefined);
  const target = before.items.find((item) => item.title === "Approve partner update");

  assert.match(cliFailure(["run", "approval-snooze", "snooze-run", target.approvalId, "--dir", tmp]), /exactly one of --until TIME or --wake/);

  const snoozedRun = JSON.parse(cli([
    "run", "approval-snooze", "snooze-run", target.approvalId,
    "--until", "3d", "--actor", "reviewer", "--fingerprint", target.fingerprint, "--dir", tmp, "--json",
  ]));
  const snoozedApproval = snoozedRun.approvals.find((approval) => approval.id === target.approvalId);
  assert.equal(snoozedApproval.status, "pending");
  assert.ok(Date.parse(snoozedApproval.snoozedUntil) > Date.now() + 2 * 24 * 3600 * 1000);

  const hidden = queue();
  assert.equal(hidden.count, 1, "snoozed approval leaves the default queue");
  assert.equal(hidden.snoozedCount, 1);
  assert.deepEqual(hidden.items.map((item) => item.title), ["Approve invoice"]);
  assert.match(
    cli(["approvals", "--dir", tmp, "--recursive", "--index", "never"]),
    /1 snoozed approval hidden; pass --include-snoozed/,
  );

  const all = queue(["--include-snoozed"]);
  assert.equal(all.count, 2);
  const listed = all.items.find((item) => item.approvalId === target.approvalId);
  assert.equal(listed.snoozedUntil, snoozedApproval.snoozedUntil);
  assert.equal(all.items.find((item) => item.title === "Approve invoice").snoozedUntil, undefined);

  // An expired snooze returns on its own: rewrite the time into the past through the model.
  const persisted = loadAgentRun(tmp, "snooze-run");
  const expired = {
    ...persisted,
    approvals: persisted.approvals.map((approval) => approval.id === target.approvalId
      ? { ...approval, snoozedUntil: "2020-01-01T00:00:00.000Z" }
      : approval),
  };
  saveAgentRun(tmp, expired);
  const returned = queue();
  assert.equal(returned.count, 2, "an expired snooze returns to the queue with no background job");
  assert.equal(returned.items.find((item) => item.approvalId === target.approvalId).snoozedUntil, undefined);

  cli(["run", "approval-snooze", "snooze-run", target.approvalId, "--until", "1w", "--dir", tmp, "--json"]);
  assert.equal(queue().count, 1);
  cli(["run", "approval-snooze", "snooze-run", target.approvalId, "--wake", "--actor", "reviewer", "--dir", tmp, "--json"]);
  assert.equal(queue().count, 2, "--wake returns the approval immediately");

  // Deciding still works for a snoozed approval.
  cli(["run", "approval-snooze", "snooze-run", target.approvalId, "--until", "1d", "--dir", tmp, "--json"]);
  cli(["run", "approval-decide", "snooze-run", target.approvalId, "--decision", "approved", "--actor", "reviewer", "--dir", tmp, "--json"]);
  const decided = queue(["--include-snoozed"]);
  assert.equal(decided.items.some((item) => item.approvalId === target.approvalId), false);
  assert.match(
    cliFailure(["run", "approval-snooze", "snooze-run", target.approvalId, "--until", "1d", "--dir", tmp]),
    /already approved/,
  );
}

// --- Headline approvals snooze with a future SCHEDULED date ------------------
{
  const pad = (value) => String(value).padStart(2, "0");
  const orgDate = (date) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  const future = new Date();
  future.setDate(future.getDate() + 10);
  const past = new Date();
  past.setDate(past.getDate() - 10);
  fs.writeFileSync(path.join(tmp, "review.org"), `* TODO Review launch post
SCHEDULED: <${orgDate(future)}>
:PROPERTIES:
:STATUS: draft-needs-review
:END:

* TODO Review pricing page
SCHEDULED: <${orgDate(past)}>
:PROPERTIES:
:STATUS: draft-needs-review
:END:

* TODO Review onboarding email
SCHEDULED: <${orgDate(past)} -20d>
:PROPERTIES:
:STATUS: draft-needs-review
:END:
`, "utf8");

  const titles = (payload) => payload.items.filter((item) => item.kind === "headline").map((item) => item.title).sort();
  assert.deepEqual(titles(queue()), ["Review pricing page"], "future SCHEDULED and a pending delay cookie hide headline approvals");
  const all = queue(["--include-snoozed"]);
  assert.deepEqual(titles(all), ["Review launch post", "Review onboarding email", "Review pricing page"]);
  const launch = all.items.find((item) => item.title === "Review launch post");
  assert.equal(launch.snoozedUntil, new Date(future.getFullYear(), future.getMonth(), future.getDate()).toISOString());
  const delayed = all.items.find((item) => item.title === "Review onboarding email");
  const delayedWake = new Date(past.getFullYear(), past.getMonth(), past.getDate());
  delayedWake.setDate(delayedWake.getDate() + 20);
  assert.equal(delayed.snoozedUntil, delayedWake.toISOString());
}

fs.rmSync(tmp, { recursive: true, force: true });
fs.rmSync(indexHome, { recursive: true, force: true });
console.log("approval snooze tests passed");
