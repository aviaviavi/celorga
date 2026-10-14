import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createAgentRun, renderAgentRunOrg, saveAgentRun, agentRunPath, listAgentRuns, loadAgentRun } from "../dist/agentRun.js";
import { goalPath, agentProfilePath } from "../dist/coordination.js";
import { workflowPath } from "../dist/agentWorkflow.js";
import { workLedgerAccountPath } from "../dist/workLedger.js";

// New durable records are always .org; legacy .org2 records keep updating in place.
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-org-record-ext-"));
try {
  const fresh = createAgentRun({ goal: "New run", now: "2026-10-14T00:00:00.000Z" });
  const freshFile = saveAgentRun(root, fresh);
  assert.equal(path.extname(freshFile), ".org");
  assert.equal(agentRunPath(root, fresh.id), freshFile);

  const legacy = createAgentRun({ goal: "Legacy run", now: "2026-10-14T00:00:00.000Z" });
  const legacyFile = path.join(path.dirname(freshFile), `${legacy.id}.org2`);
  fs.writeFileSync(legacyFile, renderAgentRunOrg(legacy));
  assert.equal(agentRunPath(root, legacy.id), legacyFile);
  legacy.goal = "Legacy run, updated";
  assert.equal(saveAgentRun(root, legacy), legacyFile);
  assert.equal(fs.existsSync(path.join(path.dirname(freshFile), `${legacy.id}.org`)), false);
  assert.equal(loadAgentRun(root, legacy.id).goal, "Legacy run, updated");
  assert.deepEqual(listAgentRuns(root).map((run) => run.id).sort(), [fresh.id, legacy.id].sort());

  assert.equal(path.extname(goalPath(root, "g")), ".org");
  assert.equal(path.extname(agentProfilePath(root, "p")), ".org");
  assert.equal(path.extname(workflowPath(root, "w")), ".org");
  assert.equal(path.extname(workLedgerAccountPath(root, "ledger", "acct")), ".org");

  const runsDir = path.dirname(freshFile);
  assert.deepEqual(fs.readdirSync(runsDir).filter((name) => name.endsWith(".org2")), [`${legacy.id}.org2`]);
  console.log("org record extension tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
