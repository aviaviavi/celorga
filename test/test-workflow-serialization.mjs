import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { listWorkflows, loadWorkflow, parseWorkflowOrg, promptAutomation, renderWorkflowOrg, saveWorkflow, updateWorkflow, workflowPath } from "../dist/agentWorkflow.js";

const workflow = promptAutomation({
  id: "serialization-regression",
  title: "Serialization regression",
  instructions: "Summarize the project notes.",
  destinationRef: "builtin.codex",
  model: "gpt-5.6-sol",
  reasoningEffort: "high",
  agentRef: "project-reviewer",
  goalRef: "project-review",
  schedule: "every 4h",
  now: "2026-09-01T00:00:00Z",
});
const rendered = renderWorkflowOrg(workflow);
const preamble = ":PROPERTIES:\n:ID: 8512a350-cd37-4d5f-9434-3508406d8829\n:END:\n\n";
const header = rendered.slice(0, rendered.indexOf(workflow.description));

// A file identity drawer must not become the start of the description.
for (const newline of ["\n", "\r\n"]) {
  const source = (preamble + rendered).replaceAll("\n", newline);
  assert.deepEqual(parseWorkflowOrg(source), workflow);
}

// Visible fields still override JSON, including intentionally empty prose.
const edited = (preamble + rendered)
  .replace("* Serialization regression", "* Revised workflow")
  .replace(":WORKFLOW_STATE: active", ":WORKFLOW_STATE: paused")
  .replace(":MODEL: gpt-5.6-sol", ":MODEL: gpt-6-astra")
  .replace(":REASONING_EFFORT: high", ":REASONING_EFFORT: xhigh")
  .replace(workflow.description, "A maintained description.");
assert.equal(parseWorkflowOrg(edited).title, "Revised workflow");
assert.equal(parseWorkflowOrg(edited).state, "paused");
assert.equal(parseWorkflowOrg(edited).description, "A maintained description.");
assert.equal(parseWorkflowOrg(edited).model, "gpt-6-astra");
assert.equal(parseWorkflowOrg(edited).reasoningEffort, "xhigh");
assert.equal(parseWorkflowOrg(rendered.replace(workflow.description, "")).description, "");
assert.equal(parseWorkflowOrg(preamble.replace(":ID:", ":AGENT_REF: unrelated\n:ID:") + rendered).agentRef, workflow.agentRef);

// Repair only leading generated copies of this workflow's own header.
const corrupted = renderWorkflowOrg({ ...workflow, description: header.repeat(3) + workflow.description });
assert.deepEqual(parseWorkflowOrg(preamble + corrupted), workflow);
assert.equal(renderWorkflowOrg(parseWorkflowOrg(corrupted)), rendered);
const otherHeader = header.replace(":ORG2_WORKFLOW_ID: serialization-regression", ":ORG2_WORKFLOW_ID: other-workflow");
const meaningfulDescriptions = [
  otherHeader + "An example of another workflow.",
  "Notes about this workflow:\n\n" + header,
  "An ordinary drawer:\n:PROPERTIES:\n:OWNER: Me\n:END:\nKeep this prose.",
];
for (const description of meaningfulDescriptions) {
  assert.equal(parseWorkflowOrg(renderWorkflowOrg({ ...workflow, description })).description, description.trim());
}
assert.deepEqual(parseWorkflowOrg(`#+begin_src json :org2-workflow\n${JSON.stringify(workflow, null, 2)}\n#+end_src\n`), workflow);

// Built-in step-based workflows predate the instructions field. Listing them
// must preserve a string field rather than making native list decoding fail.
const legacy = { ...workflow };
delete legacy.instructions;
const legacySource = `#+begin_src json :org2-workflow\n${JSON.stringify(legacy)}\n#+end_src\n`;
assert.equal(parseWorkflowOrg(legacySource).instructions, "");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-workflow-serialization-"));
try {
  saveWorkflow(root, workflow, { expectedRevision: null });
  const file = workflowPath(root, workflow.id);
  // Syncthing conflicts preserve evidence; they must never become live bindings
  // or shadow the canonical schedule merely because they sort after its filename.
  const conflict = file.replace(/\.org2$/, ".sync-conflict-20261009-184637-DEVICE.org2");
  fs.writeFileSync(conflict, renderWorkflowOrg({ ...workflow, version: "0.0.1", state: "paused" }));
  assert.equal(listWorkflows(root).length, 1);
  assert.equal(listWorkflows(root)[0].version, workflow.version);
  assert.equal(listWorkflows(root)[0].state, "active");
  assert.ok(fs.existsSync(conflict), "conflict evidence is not deleted");
  fs.writeFileSync(file, preamble + corrupted);
  for (const action of ["pause", "activate", "pause"]) {
    // These are the same structured CLI actions used by the Mac app.
    const result = spawnSync(process.execPath, [
      path.resolve("dist/cli.js"), "workflow", action, workflow.id, "--dir", root, "--json",
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const source = fs.readFileSync(file, "utf8");
    assert.ok(source.startsWith(preamble));
    assert.equal(source.match(/^\* Serialization regression$/gm)?.length, 1);
    assert.equal(source.match(/^#\+TITLE: Org2 workflow package$/gm)?.length, 1);
    const saved = loadWorkflow(root, workflow.id);
    assert.equal(saved.description, workflow.description);
    assert.equal(saved.instructions, workflow.instructions);
    assert.deepEqual(saved.triggers, workflow.triggers);
    assert.equal(saved.agentRef, workflow.agentRef);
    assert.equal(saved.goalRef, workflow.goalRef);
    assert.equal(saved.destinationRef, workflow.destinationRef);
    assert.equal(saved.model, workflow.model);
    assert.equal(saved.reasoningEffort, workflow.reasoningEffort);
    assert.equal(saved.state, action === "pause" ? "paused" : "active");
  }
  // Copy metadata only under the same guarded write as the workflow update.
  assert.throws(() => updateWorkflow(root, workflow.id, (current) => {
    fs.appendFileSync(file, "\nConcurrent edit\n");
    return current;
  }), /changed after it was read/);
  assert.ok(fs.readFileSync(file, "utf8").endsWith("Concurrent edit\n"));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log("workflow serialization tests passed");
