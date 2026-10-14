import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  addAgentRunComment,
  createAgentRun,
  requestAgentRunApproval,
  saveAgentRun,
  transitionAgentRun,
} from "../dist/agentRun.js";
import {
  appendWorkLedgerEvent,
  createWorkLedgerAccount,
  saveWorkLedgerAccount,
  workLedgerMutationLockPath,
} from "../dist/workLedger.js";

const cli = path.resolve("dist/cli.js");

function allFiles(root) {
  const result = new Map();
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const absolute = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(absolute);
      else result.set(path.relative(root, absolute), fs.readFileSync(absolute, "utf8"));
    }
  };
  walk(root);
  return result;
}

function runDoctor(root, json = true) {
  return spawnSync(process.execPath, [cli, "doctor", "--dir", root, ...(json ? ["--json"] : [])], {
    encoding: "utf8",
  });
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-doctor-"));
try {
  let terminalPending = createAgentRun({ id: "terminal-pending", goal: "Send an approved update" });
  terminalPending = requestAgentRunApproval(terminalPending, {
    id: "terminal-approval",
    title: "Send update",
    action: "Send the reviewed update",
    riskClass: "external-action",
  });
  saveAgentRun(root, transitionAgentRun(terminalPending, "canceled"));

  saveAgentRun(root, createAgentRun({
    id: "waiting-empty",
    goal: "Wait for a decision that was lost",
    status: "waiting-approval",
  }));

  let providerMissing = createAgentRun({ id: "provider-missing", goal: "Send a provider-backed email" });
  providerMissing = requestAgentRunApproval(providerMissing, {
    id: "provider-approval",
    title: "Review outreach email",
    action: "Send the drafted email to the account",
    riskClass: "external-action",
  });
  saveAgentRun(root, providerMissing);

  let approvalMisclassified = transitionAgentRun(
    createAgentRun({ id: "approval-misclassified", goal: "Keep approval waiting state canonical" }),
    "running",
  );
  approvalMisclassified = requestAgentRunApproval(approvalMisclassified, {
    id: "approval-misclassified-decision",
    title: "Approve exact daily update",
    action: "Publish the exact reviewed daily update",
    riskClass: "external-action",
  });
  saveAgentRun(root, {
    ...approvalMisclassified,
    status: "blocked",
    blockedReason: "Avi: explicitly approve the exact daily update or provide edits before publication.",
  });

  for (const id of ["duplicate-provider-one", "duplicate-provider-two"]) {
    let run = createAgentRun({ id, goal: "Review one representation of a provider draft" });
    run = requestAgentRunApproval(run, {
      id: `${id}-approval`,
      title: "Review exact email",
      action: "Send exact email\nProvider draft: gmail:gog:r-duplicate",
      riskClass: "external-action",
    });
    saveAgentRun(root, run);
  }

  for (const id of ["attempt-one", "attempt-two"]) {
    saveAgentRun(root, createAgentRun({
      id,
      goal: "Execute one logical reconciliation attempt",
      status: "running",
      logicalWorkId: "workflow:account-outreach:daily",
      attempt: { id: `${id}-attempt`, number: 1 },
    }));
  }

  for (const [id, hour] of [["unmanaged-cron-one", "08"], ["unmanaged-cron-two", "09"]]) {
    let cron = createAgentRun({ id, goal: "Run legacy Account Outreach cron" });
    cron = addAgentRunComment(
      cron,
      "org2-lifecycle",
      `OPENCLAW_KEY: cron:account-outreach-job:2026-07-31T${hour}:00:00Z\nOPENCLAW_KIND: cron`,
    );
    saveAgentRun(root, cron);
  }

  let readableDrift = createAgentRun({ id: "readable-drift", goal: "Detect a direct readable-header edit" });
  saveAgentRun(root, readableDrift);
  const readableDriftFile = path.join(root, ".org2", "runs", "readable-drift.org");
  fs.writeFileSync(
    readableDriftFile,
    fs.readFileSync(readableDriftFile, "utf8").replace(":RUN_STATUS: queued", ":RUN_STATUS: running"),
    "utf8",
  );
  fs.writeFileSync(`${readableDriftFile}.lock`, "{}\n", "utf8");

  fs.writeFileSync(path.join(root, "daily.org2"), `#+TITLE: Doctor fixture

* TODO Review provider email
:PROPERTIES:
:ORG2_RUN_ID: provider-missing
:ORG2_APPROVAL_ID: provider-approval
:ORG2_REVIEW_STATUS: review-required
:END:

* TODO Missing run projection
:PROPERTIES:
:ORG2_RUN_ID: no-such-run
:ORG2_REVIEW_STATUS: review-required
:END:

* TODO Send approved email
:PROPERTIES:
:STATUS: waiting-on-approval
:END:
** DONE Approve email
:PROPERTIES:
:STATUS: approved
:END:

* TODO Duplicate account outreach
* TODO Duplicate account outreach

* TODO First draft projection
:PROPERTIES:
:GMAIL_DRAFT_ID: r-same-draft
:END:
* TODO Second draft projection
:PROPERTIES:
:GMAIL_DRAFT_ID: r-same-draft
:END:
`, "utf8");

  for (const [id, title] of [["duplicate-ledger-one", "Duplicate Ledger One"], ["duplicate-ledger-two", "Duplicate Ledger Two"]]) {
    let account = createWorkLedgerAccount({
      ledger: "account-outreach",
      id,
      title,
      identityKeys: ["domain:duplicate.example"],
    });
    account = appendWorkLedgerEvent(account, {
      idempotencyKey: "shared-event-key",
      type: "outreach-sent",
      externalId: `gmail:${id}`,
      runId: "provider-missing",
      approvalId: "provider-approval",
    }).account;
    const saved = saveWorkLedgerAccount(root, account, { expectedRevision: null });
    if (id === "duplicate-ledger-one") {
      fs.writeFileSync(saved.file, saved.raw.replace(" outreach-sent =", " outreach-sent-edited ="), "utf8");
    }
  }
  fs.writeFileSync(workLedgerMutationLockPath(root, "account-outreach"), "{}\n", "utf8");

  const before = allFiles(root);
  const result = runDoctor(root);
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const report = JSON.parse(result.stdout);
  assert.equal(report.$schema, "org2:agentic-doctor:v1");
  assert.equal(report.readOnly, true);
  assert.equal(report.ok, false);
  assert.equal(report.summary.runFiles, 11);
  assert.equal(report.summary.validRuns, 11);
  assert.equal(report.summary.ledgerFiles, 2);
  assert.equal(report.summary.validLedgerAccounts, 2);
  assert.equal(report.summary.corpusFiles, 3);
  assert.equal(report.summary.linkedHeadlines, 2);
  const rules = new Set(report.findings.map((finding) => finding.rule));
  for (const rule of [
    "terminal-run-pending-approval",
    "waiting-run-without-pending-approval",
    "provider-approval-missing-decision-key",
    "duplicate-pending-decision-key",
    "duplicate-workflow-attempt-number",
    "overlapping-active-attempts",
    "unmanaged-openclaw-cron-series",
    "run-readable-state-diverged",
    "run-write-lock-present",
    "duplicate-headline-run-approval-projection",
    "approval-boundary-misclassified-as-separate-block",
    "headline-run-reference-missing",
    "approved-child-parent-still-waiting",
    "duplicate-open-headline-title",
    "duplicate-open-provider-draft",
    "duplicate-ledger-identity-key",
    "duplicate-ledger-event-key",
    "ledger-outreach-without-approved-decision",
    "ledger-source-state-drift",
    "ledger-write-lock-present",
  ]) assert.ok(rules.has(rule), `missing expected doctor rule: ${rule}`);
  assert.equal(
    report.findings.find((finding) => finding.rule === "duplicate-headline-run-approval-projection")?.severity,
    "error",
  );
  assert.deepEqual(allFiles(root), before, "doctor must not mutate corpus files");

  const textResult = runDoctor(root, false);
  assert.equal(textResult.status, 1, textResult.stderr || textResult.stdout);
  assert.match(textResult.stdout, /^Celorga agentic workspace doctor$/m);
  assert.match(textResult.stdout, /ERROR terminal-run-pending-approval/);

  const cleanRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-doctor-clean-"));
  try {
    const clean = runDoctor(cleanRoot);
    assert.equal(clean.status, 0, clean.stderr || clean.stdout);
    const cleanReport = JSON.parse(clean.stdout);
    assert.equal(cleanReport.ok, true);
    assert.equal(cleanReport.summary.findingCount, 0);

    const missing = runDoctor(path.join(cleanRoot, "missing-corpus"));
    assert.equal(missing.status, 1, missing.stderr || missing.stdout);
    const missingReport = JSON.parse(missing.stdout);
    assert.equal(missingReport.ok, false);
    assert.equal(missingReport.findings[0].rule, "corpus-root-unreadable");
  } finally {
    fs.rmSync(cleanRoot, { recursive: true, force: true });
  }

  console.log("Agentic workspace doctor tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
