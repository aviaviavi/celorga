import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  createAgentRun,
  decideAgentRunApproval,
  requestAgentRunApproval,
  saveAgentRun,
} from "../dist/agentRun.js";
import {
  appendWorkLedgerEvent,
  createWorkLedgerAccount,
  loadWorkLedgerAccount,
  summarizeWorkLedgerAccount,
  workLedgerAccountPath,
  workLedgerMutationLockPath,
} from "../dist/workLedger.js";

const cli = path.resolve("dist/cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-work-ledger-"));

function ledger(args) {
  return spawnSync(process.execPath, [cli, "ledger", ...args, "--dir", root, "--json"], { encoding: "utf8" });
}

try {
  const preview = ledger([
    "create", "account-outreach", "acme",
    "--title", "Acme Corp", "--alias", "Acme", "--identity", "domain:acme.example", "--identity", "name:acme corp",
    "--field", "segment=enterprise", "--context", "Curated account context.",
  ]);
  assert.equal(preview.status, 0, preview.stderr || preview.stdout);
  assert.equal(JSON.parse(preview.stdout).applied, false);
  assert.equal(fs.existsSync(workLedgerAccountPath(root, "account-outreach", "acme")), false);

  const created = ledger([
    "create", "account-outreach", "acme",
    "--title", "Acme Corp", "--alias", "Acme", "--identity", "domain:acme.example", "--identity", "name:acme corp",
    "--field", "segment=enterprise", "--context", "Curated account context.", "--apply",
  ]);
  assert.equal(created.status, 0, created.stderr || created.stdout);
  const createdResult = JSON.parse(created.stdout);
  assert.equal(createdResult.applied, true);
  assert.match(createdResult.file, /notes\/account-outreach\/accounts\/acme\.org$/);
  assert.match(createdResult.revision, /^sha256:[a-f0-9]{64}$/);
  assert.match(fs.readFileSync(createdResult.file, "utf8"), /:ORG2_ARTIFACT_ROLE: canonical/);

  const ledgerLock = workLedgerMutationLockPath(root, "account-outreach");
  fs.writeFileSync(ledgerLock, "{}\n", "utf8");
  const lockedUpdate = ledger(["update", "account-outreach", "acme", "--state", "paused", "--apply"]);
  assert.notEqual(lockedUpdate.status, 0);
  assert.match(lockedUpdate.stderr, /already being updated/);
  fs.unlinkSync(ledgerLock);

  const duplicateCreate = ledger(["create", "account-outreach", "acme", "--title", "Duplicate", "--apply"]);
  assert.notEqual(duplicateCreate.status, 0);
  assert.match(duplicateCreate.stderr, /already exists/);

  const shown = ledger(["show", "account-outreach", "acme", "--with-revision"]);
  assert.equal(shown.status, 0, shown.stderr || shown.stdout);
  const shownResult = JSON.parse(shown.stdout);
  assert.equal(shownResult.schema, "org2:work-ledger-snapshot:v1");
  assert.equal(shownResult.account.context, "Curated account context.");

  const resolvedByDomain = ledger(["resolve", "account-outreach", "--identity", "acme.example"]);
  assert.equal(resolvedByDomain.status, 0, resolvedByDomain.stderr || resolvedByDomain.stdout);
  assert.equal(JSON.parse(resolvedByDomain.stdout).matches[0].account.id, "acme");
  const resolvedByName = ledger(["resolve", "account-outreach", "--identity", "Acme Corp"]);
  assert.equal(resolvedByName.status, 0, resolvedByName.stderr || resolvedByName.stdout);
  assert.equal(JSON.parse(resolvedByName.stdout).matches[0].account.id, "acme");

  const updated = ledger([
    "update", "account-outreach", "acme", "--alias", "Acme Incorporated",
    "--field", "owner=avi", "--if-revision", shownResult.revision, "--apply",
  ]);
  assert.equal(updated.status, 0, updated.stderr || updated.stdout);
  assert.deepEqual(loadWorkLedgerAccount(root, "account-outreach", "acme").account.aliases, ["Acme", "Acme Incorporated"]);

  const staleUpdate = ledger([
    "update", "account-outreach", "acme", "--state", "paused",
    "--if-revision", shownResult.revision, "--apply",
  ]);
  assert.notEqual(staleUpdate.status, 0);
  assert.match(staleUpdate.stderr, /account revision changed/);

  const second = ledger([
    "create", "account-outreach", "other", "--title", "Other Corp",
    "--identity", "domain:other.example", "--field", "segment=smb", "--apply",
  ]);
  assert.equal(second.status, 0, second.stderr || second.stdout);
  const identityCollision = ledger([
    "update", "account-outreach", "other", "--identity", "domain:acme.example", "--apply",
  ]);
  assert.notEqual(identityCollision.status, 0);
  assert.match(identityCollision.stderr, /already claimed by acme/);

  let approvalRun = createAgentRun({ id: "acme-outreach", goal: "Prepare reviewed Acme outreach" });
  approvalRun = requestAgentRunApproval(approvalRun, {
    id: "send-acme",
    title: "Review Acme outreach",
    action: "Send the reviewed email\nProvider draft: gmail:gog:r-acme",
    riskClass: "external-action",
  });
  approvalRun = decideAgentRunApproval(approvalRun, "send-acme", "approved", { actor: "Avi" });
  saveAgentRun(root, approvalRun, { expectedRevision: null });

  const linked = ledger([
    "event", "account-outreach", "acme", "--type", "approval-linked",
    "--key", "approval:acme:r-acme", "--run", "acme-outreach", "--approval", "send-acme",
    "--decision-key", "gmail:gog:r-acme", "--actor", "Avi", "--apply",
  ]);
  assert.equal(linked.status, 0, linked.stderr || linked.stdout);

  const eligible = ledger(["list", "account-outreach", "--eligible", "--as-of", "2026-07-31T12:00:00Z"]);
  assert.equal(eligible.status, 0, eligible.stderr || eligible.stdout);
  assert.deepEqual(JSON.parse(eligible.stdout).accounts.map((account) => account.id), ["other"]);

  const missingReceipt = ledger([
    "event", "account-outreach", "acme", "--type", "outreach-sent", "--key", "send:acme:r-acme",
    "--run", "acme-outreach", "--approval", "send-acme", "--apply",
  ]);
  assert.notEqual(missingReceipt.status, 0);
  assert.match(missingReceipt.stderr, /externalId/);

  const sent = ledger([
    "event", "account-outreach", "acme", "--type", "outreach-sent", "--key", "send:acme:r-acme",
    "--run", "acme-outreach", "--approval", "send-acme", "--decision-key", "gmail:gog:r-acme",
    "--external-id", "gmail:message:m-acme", "--actor", "Avi", "--at", "2026-07-31T10:00:00Z", "--apply",
  ]);
  assert.equal(sent.status, 0, sent.stderr || sent.stdout);
  assert.equal(JSON.parse(sent.stdout).changed, true);
  const sentAgain = ledger([
    "event", "account-outreach", "acme", "--type", "outreach-sent", "--key", "send:acme:r-acme",
    "--run", "acme-outreach", "--approval", "send-acme", "--decision-key", "gmail:gog:r-acme",
    "--external-id", "gmail:message:m-acme", "--actor", "Avi", "--at", "2026-07-31T10:00:00Z", "--apply",
  ]);
  assert.equal(sentAgain.status, 0, sentAgain.stderr || sentAgain.stdout);
  assert.equal(JSON.parse(sentAgain.stdout).changed, false);
  assert.equal(loadWorkLedgerAccount(root, "account-outreach", "acme").account.events.filter((event) => event.type === "outreach-sent").length, 1);

  const eventCollision = ledger([
    "event", "account-outreach", "other", "--type", "note", "--key", "send:acme:r-acme", "--note", "Wrong account", "--apply",
  ]);
  assert.notEqual(eventCollision.status, 0);
  assert.match(eventCollision.stderr, /already recorded on acme/);

  const cooledDown = ledger([
    "list", "account-outreach", "--eligible", "--as-of", "2026-08-01T12:00:00Z", "--cooldown-days", "90",
  ]);
  assert.deepEqual(JSON.parse(cooledDown.stdout).accounts.map((account) => account.id), ["other"]);
  const segmentFilter = ledger(["list", "account-outreach", "--field", "segment=enterprise"]);
  assert.deepEqual(JSON.parse(segmentFilter.stdout).accounts.map((account) => account.id), ["acme"]);

  const accountFile = workLedgerAccountPath(root, "account-outreach", "acme");
  fs.writeFileSync(
    accountFile,
    fs.readFileSync(accountFile, "utf8").replace("Curated account context.", "Human-edited account context."),
    "utf8",
  );
  const afterDirectEdit = ledger([
    "event", "account-outreach", "acme", "--type", "note", "--key", "note:human-context",
    "--note", "Preserve the human edit", "--apply",
  ]);
  assert.equal(afterDirectEdit.status, 0, afterDirectEdit.stderr || afterDirectEdit.stdout);
  assert.equal(loadWorkLedgerAccount(root, "account-outreach", "acme").account.context, "Human-edited account context.");

  let overlapping = createWorkLedgerAccount({
    ledger: "account-outreach",
    id: "overlapping",
    title: "Overlapping Corp",
    now: "2026-07-31T08:00:00Z",
  });
  overlapping = appendWorkLedgerEvent(overlapping, {
    type: "approval-linked", idempotencyKey: "approval:overlapping:a",
    runId: "run-a", approvalId: "approval-a", at: "2026-07-31T09:00:00Z",
  }).account;
  overlapping = appendWorkLedgerEvent(overlapping, {
    type: "approval-linked", idempotencyKey: "approval:overlapping:b",
    runId: "run-b", approvalId: "approval-b", at: "2026-07-31T09:30:00Z",
  }).account;
  overlapping = appendWorkLedgerEvent(overlapping, {
    type: "outreach-sent", idempotencyKey: "send:overlapping:a",
    runId: "run-a", approvalId: "approval-a", externalId: "gmail:message:a",
    at: "2026-07-31T10:00:00Z",
  }).account;
  const overlappingSummary = summarizeWorkLedgerAccount({
    file: "overlapping.org2", revision: "sha256:test", raw: "", account: overlapping, sourceIssues: [],
  }, { asOf: "2026-08-01T10:00:00Z", cooldownDays: 0 });
  assert.equal(overlappingSummary.openWorkCount, 1);
  assert.equal(overlappingSummary.eligible, false);

  fs.writeFileSync(
    accountFile,
    fs.readFileSync(accountFile, "utf8").replace(" outreach-sent =", " outreach-sent-edited ="),
    "utf8",
  );
  const drifted = ledger(["show", "account-outreach", "acme", "--with-revision"]);
  assert.equal(drifted.status, 0, drifted.stderr || drifted.stdout);
  assert.deepEqual(JSON.parse(drifted.stdout).sourceIssues.map((issue) => issue.field), ["eventHistory"]);
  const driftedList = ledger(["list", "account-outreach", "--cooldown-days", "0"]);
  const driftedSummary = JSON.parse(driftedList.stdout).accounts.find((account) => account.id === "acme");
  assert.equal(driftedSummary.eligible, false);
  assert.equal(driftedSummary.eligibilityReason, "source event history requires reconciliation");
  const rejectedDrift = ledger([
    "event", "account-outreach", "acme", "--type", "note", "--key", "note:after-drift",
    "--note", "This must not overwrite ambiguous source", "--apply",
  ]);
  assert.notEqual(rejectedDrift.status, 0);
  assert.match(rejectedDrift.stderr, /out-of-band event-history changes/);

  console.log("Work ledger tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
