#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  addAgentRunComment,
  createAgentRun,
  listAgentRuns,
  listAgentRunsWithApprovals,
  loadAgentRun,
  requestAgentRunApproval,
  saveAgentRun,
  transitionAgentRun,
} from "../dist/agentRun.js";

const repo = process.cwd();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-approvals-test-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "org2-approvals-index-home-"));
const note = path.join(tmp, "approvals.org2");
const conflict = path.join(tmp, "approvals.sync-conflict-20260626-100557-3XMYYT2.org2");
const versionsDir = path.join(tmp, ".stversions", "agents");
const versionedApproval = path.join(versionsDir, "approvals~20260706-100605.org2");
process.env.ORG2_INDEX_HOME = indexHome;

function cli(args) {
  return execFileSync("node", ["dist/cli.js", ...args], {
    cwd: repo,
    encoding: "utf8",
    env: { ...process.env, ORG2_INDEX_HOME: indexHome },
  });
}

fs.mkdirSync(versionsDir, { recursive: true });
fs.writeFileSync(note, `#+title: Approval queue

* TODO Review outreach copy
SCHEDULED: <2026-06-26 Fri>
:PROPERTIES:
:ID: approval-1
:STATUS: draft-needs-review
:END:
Send this once approved.

* DONE Review old item
:PROPERTIES:
:STATUS: draft-needs-review
:END:
Already closed.

* TODO [#B] Approve sending Mercor technographics data [[id:8f3c76e5-dd1f-4819-9738-7959b95c3649][overview]] draft
:PROPERTIES:
:ID: approval-priority
:STATUS: waiting-on-avi-approval
:END:
Approve before sending.

* TODO Approve final copy
:PROPERTIES:
:ID: duplicate-run-linked-approval
:STATUS: waiting-on-approval
:ORG2_RUN_ID: release-run
:END:
This is only a source projection of the canonical run approval.

* TODO Finish action outside Org2
:PROPERTIES:
:GMAIL_DRAFT_ID: r-completed-elsewhere
:END:
** TODO Approve obsolete action
:PROPERTIES:
:ID: completed-elsewhere-headline
:STATUS: draft-needs-review
:END:
Legacy projection of a decision that was completed elsewhere.
`, "utf8");

fs.writeFileSync(versionedApproval, `* TODO Review outreach copy
:PROPERTIES:
:ID: approval-1
:STATUS: draft-needs-review
:END:
Historical Syncthing snapshot.
`, "utf8");

fs.writeFileSync(conflict, `* TODO Review deleted sync artifact
:PROPERTIES:
:STATUS: draft-needs-review
:END:
`, "utf8");

cli(["run", "create", "--id", "release-run", "--goal", "Release the weekly brief", "--dir", tmp, "--json"]);
cli(["run", "start", "release-run", "--dir", tmp, "--json"]);
cli(["run", "approval-request", "release-run", "--title", "Approve recipients", "--action", "confirm recipient list", "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json"]);
cli(["run", "approval-request", "release-run", "--title", "Approve final copy", "--action", "send weekly brief", "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json"]);
assert.throws(
  () => cli(["run", "block", "release-run", "--reason", "The mail service is unavailable.", "--dir", tmp, "--json"]),
  (error) => String(error.stderr || error.message).includes("--separate-from-approval"),
);
assert.throws(
  () => cli([
    "run", "block", "release-run",
    "--reason", "Avi: explicitly approve the final copy or provide edits before publication.",
    "--separate-from-approval", "--dir", tmp, "--json",
  ]),
  (error) => String(error.stderr || error.message).includes("duplicates the pending approval boundary"),
);
assert.equal(loadAgentRun(tmp, "release-run").status, "waiting-approval");

cli(["run", "create", "--id", "completed-elsewhere-run", "--goal", "Finish outside Org2", "--dir", tmp, "--json"]);
cli(["run", "start", "completed-elsewhere-run", "--dir", tmp, "--json"]);
cli(["run", "approval-request", "completed-elsewhere-run", "--title", "Approve obsolete action", "--action", "perform obsolete action\nProvider draft: gmail:gog:r-completed-elsewhere", "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json"]);
cli(["run", "block", "completed-elsewhere-run", "--reason", "The action moved to another system.", "--separate-from-approval", "--dir", tmp, "--json"]);
cli(["run", "complete-external", "completed-elsewhere-run", "--summary", "Completed in the other system.", "--actor", "Avi", "--dir", tmp, "--json"]);

const staleIndex = JSON.parse(cli(["index", "--dir", tmp, "--files", note, conflict, "--format", "json"]));
assert.equal(staleIndex.fileCount, 2);
fs.unlinkSync(conflict);

const payload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(payload.$schema, "org2:approvals:v2");
assert.equal(payload.index.used, true);
assert.equal(payload.index.rebuilt, true);
assert.equal(payload.count, 4);
assert.equal(payload.skippedCandidates ?? 0, 0);
const runItems = payload.items.filter((item) => item.kind === "run");
const headlineItems = payload.items.filter((item) => item.kind === "headline");
assert.equal(payload.items.some((item) => item.runId === "completed-elsewhere-run"), false);
assert.equal(payload.items.some((item) => item.idValue === "completed-elsewhere-headline"), false);
assert.equal(loadAgentRun(tmp, "completed-elsewhere-run").approvals[0].status, "pending");
assert.deepEqual(
  listAgentRunsWithApprovals(tmp).map((run) => run.id).sort(),
  ["completed-elsewhere-run", "release-run"],
);
assert.equal(runItems.length, 2);
assert.equal(runItems[0].runId, "release-run");
assert.equal(runItems[0].runGoal, "Release the weekly brief");
assert.equal(runItems[0].runStatus, "waiting-approval");
assert.equal(runItems[0].runPendingApprovalCount, 2);
assert.equal(runItems[0].runApprovalCount, 2);
assert.equal(runItems[0].runDecisionEffect, "Approving this leaves 1 other pending approval before the run can resume.");
assert.equal(headlineItems[0].title, "Review outreach copy");
assert.equal(headlineItems[0].line, 3);
assert.equal(headlineItems[0].idValue, "approval-1");
assert.equal(headlineItems[0].status, "draft-needs-review");
assert.equal(headlineItems[0].body, "Send this once approved.");
assert.doesNotMatch(headlineItems[0].file, /\.stversions/);
assert.deepEqual(headlineItems[0].properties, {
  ID: "approval-1",
  STATUS: "draft-needs-review",
});
assert.equal(headlineItems[1].title, "Approve sending Mercor technographics data overview draft");
assert.equal(headlineItems[1].idValue, "approval-priority");
assert.equal(headlineItems[1].status, "waiting-on-avi-approval");
assert.equal(payload.items.some((item) => item.idValue === "duplicate-run-linked-approval"), false);

const detailPayload = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--run-detail", "release-run", "--format", "json",
]));
assert.deepEqual(detailPayload.runDetails.map((run) => run.id), ["release-run"]);
assert.equal(detailPayload.runDetails[0].approvals.length, 2);

const originalReadFileSync = fs.readFileSync;
let cachedRunReads = 0;
fs.readFileSync = function countedReadFileSync(file, ...args) {
  if (String(file).startsWith(`${path.join(tmp, ".org2", "runs")}${path.sep}`)) cachedRunReads += 1;
  return originalReadFileSync.call(this, file, ...args);
};
try {
  assert.deepEqual(
    listAgentRunsWithApprovals(tmp).map((run) => run.id).sort(),
    ["completed-elsewhere-run", "release-run"],
  );
} finally {
  fs.readFileSync = originalReadFileSync;
}
assert.equal(cachedRunReads, 0, "a warm approval scan should not reopen unchanged run records");

saveAgentRun(tmp, addAgentRunComment(
  loadAgentRun(tmp, "release-run"),
  "test",
  "Change one run while retaining its approval boundary.",
));
let changedRunReads = 0;
fs.readFileSync = function countedReadFileSync(file, ...args) {
  if (String(file).startsWith(`${path.join(tmp, ".org2", "runs")}${path.sep}`)) changedRunReads += 1;
  return originalReadFileSync.call(this, file, ...args);
};
try {
  listAgentRunsWithApprovals(tmp);
} finally {
  fs.readFileSync = originalReadFileSync;
}
assert.equal(changedRunReads, 1, "an incremental approval scan should reopen only the changed run record");

fs.appendFileSync(note, `

* TODO Send shared provider draft
:PROPERTIES:
:GMAIL_DRAFT_ID: r-shared-provider-draft
:END:
** TODO Approve shared provider draft
:PROPERTIES:
:ID: shared-provider-headline
:STATUS: draft-needs-review
:END:
This heading is a legacy projection of the durable run approval.
`, "utf8");

const sharedRuns = [];
for (const runId of ["shared-provider-old", "shared-provider-current"]) {
  cli([
    "run", "create", "--id", runId, "--goal", "Send shared provider draft",
    "--context", "artifact:gmail:gog:r-shared-provider-draft",
    "--dir", tmp, "--json",
  ]);
  cli(["run", "start", runId, "--dir", tmp, "--json"]);
  sharedRuns.push(JSON.parse(cli([
    "run", "approval-request", runId,
    "--title", "Approve shared provider draft",
    "--action", "Send exact reviewed content\nProvider draft: gmail:gog:r-shared-provider-draft",
    "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
  ])));
}
const expectedSharedRun = [...sharedRuns]
  .sort((lhs, rhs) => {
    const requestedOrder = lhs.approvals.at(-1).requestedAt.localeCompare(rhs.approvals.at(-1).requestedAt);
    if (requestedOrder !== 0) return requestedOrder;
    return `${lhs.id}:${lhs.approvals.at(-1).id}`.localeCompare(`${rhs.id}:${rhs.approvals.at(-1).id}`);
  })
  .at(-1);

cli([
  "run", "create", "--id", "shared-provider-hook", "--goal", "Review shared provider draft",
  "--risk", "external-action", "--dir", tmp, "--json",
]);
cli([
  "run", "comment", "shared-provider-hook", "--author", "org2-lifecycle",
  "--body", "OPENCLAW_KEY: draft:gmail:gog:owner@example.com:r-shared-provider-draft\nOPENCLAW_KIND: external-draft",
  "--dir", tmp, "--json",
]);
cli(["run", "start", "shared-provider-hook", "--dir", tmp, "--json"]);
const reusedSharedRun = JSON.parse(cli([
  "run", "approval-request", "shared-provider-hook",
  "--title", "Approve shared provider draft from OpenClaw",
  "--action", "Send exact reviewed content\nProvider draft: gmail:gog:r-shared-provider-draft",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
assert.equal(reusedSharedRun.id, expectedSharedRun.id);
assert.equal(loadAgentRun(tmp, "shared-provider-hook").status, "canceled");

let legacySharedRun = createAgentRun({
  id: "shared-provider-legacy",
  goal: "Review legacy shared provider draft",
  riskClass: "external-action",
  now: "2026-01-01T00:00:00Z",
});
legacySharedRun = addAgentRunComment(
  legacySharedRun,
  "org2-lifecycle",
  "OPENCLAW_KEY: draft:gmail:gog:owner@example.com:r-shared-provider-draft\nOPENCLAW_KIND: external-draft",
  "2026-01-01T00:00:01Z",
);
legacySharedRun = transitionAgentRun(legacySharedRun, "running", { now: "2026-01-01T00:00:02Z" });
legacySharedRun = requestAgentRunApproval(legacySharedRun, {
  id: "legacy-shared-approval",
  title: "Approve legacy shared provider draft",
  action: "Send older reviewed content\nProvider draft: gmail:gog:r-shared-provider-draft",
  riskClass: "external-action",
  requestedRole: "owner",
  requestedAt: "2026-01-01T00:00:03Z",
});
saveAgentRun(tmp, legacySharedRun);

const unifiedPayload = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json",
]));
const sharedItems = unifiedPayload.items.filter((item) =>
  item.idValue === "shared-provider-headline"
    || item.action?.includes("Provider draft: gmail:gog:r-shared-provider-draft"));
assert.equal(sharedItems.length, 1);
assert.equal(sharedItems[0].kind, "run");
assert.equal(sharedItems[0].runId, expectedSharedRun.id);
assert.deepEqual(sharedItems[0].decisionKeys, ["artifact:gmail:gog:r-shared-provider-draft"]);

cli([
  "run", "approval-decide", sharedItems[0].runId, sharedItems[0].approvalId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner",
  "--fingerprint", sharedItems[0].fingerprint, "--dir", tmp, "--json",
]);
const afterSharedDecision = JSON.parse(cli([
  "approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json",
]));
assert.equal(afterSharedDecision.items.filter((item) =>
  item.idValue === "shared-provider-headline"
    || item.action?.includes("Provider draft: gmail:gog:r-shared-provider-draft")).length, 0);
const reconciledLegacyRun = loadAgentRun(tmp, "shared-provider-legacy");
assert.equal(reconciledLegacyRun.status, "canceled");
assert.equal(reconciledLegacyRun.approvals[0].status, "canceled");
assert.match(reconciledLegacyRun.approvals[0].receipt, /Superseded by approval/);
const resolvedSharedApproval = JSON.parse(cli([
  "run", "approval-resolve",
  "--decision-key", "gmail:gog:r-shared-provider-draft",
  "--dir", tmp, "--json",
]));
assert.equal(resolvedSharedApproval.found, true);
assert.equal(resolvedSharedApproval.canonical.runId, expectedSharedRun.id);
assert.equal(resolvedSharedApproval.canonical.approval.status, "approved");
assert.equal(resolvedSharedApproval.projections.some((projection) =>
  projection.runId === "shared-provider-legacy"
    && projection.approvalStatus === "canceled"), true);

let postDecisionDuplicate = createAgentRun({
  id: "shared-provider-post-decision",
  goal: "Review stale shared provider draft",
  riskClass: "external-action",
  now: "2026-01-02T00:00:00Z",
});
postDecisionDuplicate = addAgentRunComment(
  postDecisionDuplicate,
  "org2-lifecycle",
  "OPENCLAW_KEY: draft:gmail:gog:owner@example.com:r-shared-provider-draft\nOPENCLAW_KIND: external-draft",
  "2026-01-02T00:00:01Z",
);
postDecisionDuplicate = transitionAgentRun(postDecisionDuplicate, "running", { now: "2026-01-02T00:00:02Z" });
postDecisionDuplicate = requestAgentRunApproval(postDecisionDuplicate, {
  id: "post-decision-shared-approval",
  title: "Approve stale shared provider draft",
  action: "Send stale reviewed content\nProvider draft: gmail:gog:r-shared-provider-draft",
  riskClass: "external-action",
  requestedRole: "owner",
  requestedAt: "2026-01-02T00:00:03Z",
});
saveAgentRun(tmp, postDecisionDuplicate);
const reconciliationPreview = JSON.parse(cli([
  "run", "approval-reconcile", "--dir", tmp, "--json",
]));
assert.equal(reconciliationPreview.applied, false);
assert.equal(reconciliationPreview.changed, true);
assert.equal(loadAgentRun(tmp, "shared-provider-post-decision").status, "waiting-approval");
const reconciliation = JSON.parse(cli([
  "run", "approval-reconcile", "--apply", "--dir", tmp, "--json",
]));
assert.equal(reconciliation.applied, true);
assert.equal(reconciliation.updates.some((update) =>
  update.runId === "shared-provider-post-decision" && update.runClosed), true);
assert.equal(loadAgentRun(tmp, "shared-provider-post-decision").status, "canceled");

cli(["run", "create", "--id", "revision-run", "--goal", "Release revised copy", "--dir", tmp, "--json"]);
cli(["run", "start", "revision-run", "--dir", tmp, "--json"]);
let revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve original copy", "--action", "send original copy",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
cli([
  "run", "approval-decide", "revision-run", revisionRun.approvals.at(-1).id,
  "--decision", "revised", "--actor", "Avi", "--role", "owner",
  "--note", "Make the opening more direct and remove the internal acronym.",
  "--dir", tmp, "--json",
]);
assert.equal(
  JSON.parse(cli(["run", "show", "revision-run", "--dir", tmp, "--json"]))
    .approvals.at(-1).decisionNote,
  "Make the opening more direct and remove the internal acronym.",
);
revisionRun = JSON.parse(cli([
  "run", "approval-request", "revision-run",
  "--title", "Approve revised copy", "--action", "send revised copy",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
const replacementApprovalId = revisionRun.approvals.at(-1).id;
const replacementPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const replacementItem = replacementPayload.items.find((item) => item.runId === "revision-run");
assert.equal(replacementItem.runStatus, "waiting-approval");
assert.equal(replacementItem.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");
revisionRun = JSON.parse(cli([
  "run", "approval-decide", "revision-run", replacementApprovalId,
  "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
]));
assert.equal(revisionRun.status, "running");
assert.deepEqual(revisionRun.approvals.map((approval) => approval.status), ["revised", "approved"]);

for (const decision of ["rejected", "canceled"]) {
  const runId = `${decision}-approval-run`;
  cli(["run", "create", "--id", runId, "--goal", `Stop after ${decision} approval`, "--dir", tmp, "--json"]);
  cli(["run", "start", runId, "--dir", tmp, "--json"]);
  const pendingRun = JSON.parse(cli([
    "run", "approval-request", runId,
    "--title", "Approve protected action", "--action", "perform protected action",
    "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
  ]));
  const decidedRun = JSON.parse(cli([
    "run", "approval-decide", runId, pendingRun.approvals.at(-1).id,
    "--decision", decision, "--actor", "Avi", "--role", "owner",
    "--note", `The approval was ${decision}.`, "--dir", tmp, "--json",
  ]));
  assert.equal(decidedRun.status, "running");
  assert.equal(decidedRun.approvals.at(-1).status, decision);
  assert.equal(loadAgentRun(tmp, runId).status, "running");
}

cli(["run", "create", "--id", "independent-batch-run", "--goal", "Review independent recipient drafts", "--dir", tmp, "--json"]);
cli(["run", "start", "independent-batch-run", "--dir", tmp, "--json"]);
const firstBatchBoundary = JSON.parse(cli([
  "run", "approval-request", "independent-batch-run",
  "--title", "Approve first recipient", "--action", "send first draft",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
const secondBatchBoundary = JSON.parse(cli([
  "run", "approval-request", "independent-batch-run",
  "--title", "Approve second recipient", "--action", "send second draft",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
const rejectedBatchBoundary = JSON.parse(cli([
  "run", "approval-decide", "independent-batch-run", firstBatchBoundary.approvals.at(-1).id,
  "--decision", "rejected", "--actor", "Avi", "--role", "owner",
  "--note", "Skip only this recipient.", "--dir", tmp, "--json",
]));
assert.equal(rejectedBatchBoundary.status, "waiting-approval");
assert.deepEqual(rejectedBatchBoundary.approvals.map((approval) => approval.status), ["rejected", "pending"]);
const afterBatchRejection = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]));
assert.equal(afterBatchRejection.items.some((item) =>
  item.runId === "independent-batch-run" && item.approvalId === secondBatchBoundary.approvals.at(-1).id), true);
const completedBatchBoundary = JSON.parse(cli([
  "run", "approval-decide", "independent-batch-run", secondBatchBoundary.approvals.at(-1).id,
  "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
]));
assert.equal(completedBatchBoundary.status, "running");

cli(["run", "create", "--id", "sync-conflict-run", "--goal", "Send one canonical provider draft", "--dir", tmp, "--json"]);
cli(["run", "start", "sync-conflict-run", "--dir", tmp, "--json"]);
const syncConflictPending = JSON.parse(cli([
  "run", "approval-request", "sync-conflict-run",
  "--title", "Approve canonical provider draft",
  "--action", "Send exact reviewed content\nProvider draft: gmail:gog:r-sync-conflict-draft",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
const syncConflictCopy = path.join(
  tmp,
  ".org2",
  "runs",
  "sync-conflict-run.sync-conflict-20260812-122403-JWVPXCO.org2",
);
fs.copyFileSync(path.join(tmp, ".org2", "runs", "sync-conflict-run.org2"), syncConflictCopy);
cli([
  "run", "approval-decide", "sync-conflict-run", syncConflictPending.approvals.at(-1).id,
  "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
]);
assert.equal(listAgentRuns(tmp).filter((run) => run.id === "sync-conflict-run").length, 1);
assert.equal(listAgentRuns(tmp).find((run) => run.id === "sync-conflict-run").status, "running");
const resolvedSyncConflictApproval = JSON.parse(cli([
  "run", "approval-resolve",
  "--decision-key", "gmail:gog:r-sync-conflict-draft",
  "--dir", tmp, "--json",
]));
assert.equal(resolvedSyncConflictApproval.canonical.runId, "sync-conflict-run");
assert.equal(resolvedSyncConflictApproval.canonical.runStatus, "running");
assert.equal(resolvedSyncConflictApproval.canonical.approval.status, "approved");
assert.equal(resolvedSyncConflictApproval.projections.length, 1);

cli(["run", "create", "--id", "retry-pending-boundary", "--goal", "Recover a canceled review queue", "--dir", tmp, "--json"]);
cli(["run", "start", "retry-pending-boundary", "--dir", tmp, "--json"]);
const retryApprovalBoundary = JSON.parse(cli([
  "run", "approval-request", "retry-pending-boundary",
  "--title", "Approve recovered action", "--action", "perform recovered action",
  "--risk", "external-action", "--role", "owner", "--dir", tmp, "--json",
]));
cli(["run", "cancel", "retry-pending-boundary", "--dir", tmp, "--json"]);
const retriedPendingBoundary = JSON.parse(cli([
  "run", "retry", "retry-pending-boundary", "--actor", "Avi", "--dir", tmp, "--json",
]));
assert.equal(retriedPendingBoundary.status, "waiting-approval");
assert.equal(retriedPendingBoundary.approvals.at(-1).status, "pending");
cli([
  "run", "approval-decide", "retry-pending-boundary", retryApprovalBoundary.approvals.at(-1).id,
  "--decision", "canceled", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json",
]);

const scannedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--index", "never", "--format", "json"]));
assert.equal(scannedPayload.index.used, false);
assert.equal(scannedPayload.count, 4);
assert.doesNotMatch(scannedPayload.items.find((item) => item.kind === "headline").file, /\.stversions/);

const indexedPayload = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
assert.equal(indexedPayload.index.used, true);
assert.equal(indexedPayload.index.rebuilt, undefined);
assert.equal(indexedPayload.count, 4);

const text = cli(["approvals", "--dir", tmp, "--recursive"]);
assert.match(text, /approvals\.org2:3 TODO Review outreach copy \[draft-needs-review\]/);
assert.match(text, /TODO Approve sending Mercor technographics data overview draft \[waiting-on-avi-approval\]/);
assert.match(text, /run:release-run:.+ Approve .+ \[pending; 2 pending for run\]/);

const approvalToDecide = runItems[0].approvalId;
cli(["run", "approval-decide", "release-run", approvalToDecide, "--decision", "approved", "--actor", "Avi", "--role", "owner", "--dir", tmp, "--json"]);
const afterDecision = JSON.parse(cli(["approvals", "--dir", tmp, "--recursive", "--format", "json"]));
const remainingRunApproval = afterDecision.items.find((item) => item.kind === "run");
assert.equal(afterDecision.count, 3);
assert.equal(remainingRunApproval.runId, "release-run");
assert.equal(remainingRunApproval.runPendingApprovalCount, 1);
assert.equal(remainingRunApproval.runDecisionEffect, "This is the last pending approval; approving it resumes the run.");

// Explicit priority: stored only when urgent, outside the fingerprint, and validated.
{
  const base = createAgentRun({ id: "priority-run", title: "Priority", goal: "Priority", status: "running" });
  const material = { title: "Send now", action: "send the reply", riskClass: "external-action" };
  const urgent = requestAgentRunApproval(base, { ...material, priority: "urgent" }).approvals.at(-1);
  const normal = requestAgentRunApproval(base, { ...material }).approvals.at(-1);
  assert.equal(urgent.priority, "urgent");
  assert.equal(normal.priority, undefined, "normal priority is the absent default");
  assert.equal(urgent.fingerprint, normal.fingerprint, "urgency changes when a person is asked, not what is approved");
  assert.throws(() => requestAgentRunApproval(base, { ...material, priority: "asap" }), /invalid approval priority/);
}

console.log("✓ cli approvals");
