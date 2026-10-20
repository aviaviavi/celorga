import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createAgentRun, saveAgentRun } from "../dist/agentRun.js";
import { AGENT_PLAYBOOKS, renderAgentPlaybookPrompt } from "../dist/agentPlaybooks.js";

const cli = path.resolve("dist/cli.js");

function allFiles(root) {
  const result = [];
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const absolute = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(absolute);
      else result.push(path.relative(root, absolute));
    }
  };
  walk(root);
  return result.sort();
}

const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-doctor-handoff-"));
const root = path.join(sandbox, "corpus");
const home = path.join(sandbox, "home");
const bin = path.join(sandbox, "bin");
const record = path.join(sandbox, "launch-record.json");
fs.mkdirSync(path.join(root, "notes"), { recursive: true });
fs.mkdirSync(home);
fs.mkdirSync(bin);
fs.writeFileSync(path.join(root, "celorga.json"), JSON.stringify({
  corpus: { schema: "org2:corpus:v1", id: "handoff-fixture", name: "Handoff fixture", kind: "personal" },
}));
fs.writeFileSync(path.join(root, "notes", "a.org"), "* TODO Fictional task\n");
const incident = path.join(root, "raw", "diagnostics", "app", "2026", "01", "02", "20260102T030405Z-unresponsive-1-abc");
fs.mkdirSync(incident, { recursive: true });
fs.writeFileSync(path.join(incident, "incident.json"), "{}\n");
// A contradictory run: the handoff must still be produced when doctor fails.
saveAgentRun(root, createAgentRun({ id: "waiting-empty", goal: "Lost decision", status: "waiting-approval" }));

// Fake runtime: records argv, cwd, and the permission config, then exits 7.
const fake = path.join(bin, "fake-opencode");
fs.writeFileSync(fake, `#!/usr/bin/env node
require("fs").writeFileSync(${JSON.stringify(record)}, JSON.stringify({
  argv: process.argv.slice(2), cwd: process.cwd(), config: process.env.OPENCODE_CONFIG_CONTENT || null,
}));
process.exit(7);
`, { mode: 0o755 });

const env = {
  PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
  HOME: home,
  ORG2_OPENCODE_EXECUTABLE: fake,
  ORG2_CODEX_EXECUTABLE: path.join(bin, "missing-codex"),
  CELORGA_TEST_SECRET_SENTINEL: "sentinel-value-must-not-leak",
};

function doctor(...args) {
  return spawnSync(process.execPath, [cli, "doctor", "--dir", root, ...args], { encoding: "utf8", env, cwd: sandbox });
}

try {
  const before = allFiles(root);

  // Plain doctor keeps its existing contract: read-only, nonzero on contradictions.
  const plain = doctor("--json");
  assert.equal(plain.status, 1, plain.stderr);
  assert.equal(JSON.parse(plain.stdout).$schema, "org2:agentic-doctor:v1");

  // Machine evidence is bounded, read-only, and leaks no environment values.
  const machine = doctor("--machine", "--json");
  assert.equal(machine.status, 0, machine.stderr);
  const evidence = JSON.parse(machine.stdout);
  assert.equal(evidence.$schema, "celorga:doctor-machine-evidence:v1");
  assert.equal(evidence.readOnly, true);
  assert.equal(evidence.corpus.valid, true);
  assert.equal(evidence.corpus.id, "handoff-fixture");
  assert.equal(evidence.workspace.ok, false);
  assert.ok(evidence.workspace.findings.length <= 20);
  assert.ok(evidence.workspace.findings.some((item) => item.runId === "waiting-empty"));
  assert.deepEqual(evidence.diagnostics.recentIncidents, ["raw/diagnostics/app/2026/01/02/20260102T030405Z-unresponsive-1-abc"]);
  assert.deepEqual(evidence.app.bundles.filter((bundle) => bundle.location === "user"), []);
  const opencode = evidence.runtimes.find((runtime) => runtime.id === "opencode");
  assert.deepEqual(opencode, { id: "opencode", name: "OpenCode", found: true, source: "env" });
  assert.equal(evidence.runtimes.find((runtime) => runtime.id === "codex").found, false);
  assert.ok(!machine.stdout.includes("sentinel-value-must-not-leak"));
  assert.ok(!machine.stdout.includes(fake), "resolved executable paths stay local");
  assert.deepEqual(allFiles(root), before);

  // Handoff preview: explicit runtime, permission posture, no writes, never recurring.
  const preview = doctor("--handoff", "opencode", "--json");
  assert.equal(preview.status, 0, preview.stderr);
  const previewJson = JSON.parse(preview.stdout);
  assert.equal(previewJson.applied, false);
  assert.equal(previewJson.launched, false);
  const handoff = previewJson.handoff;
  assert.equal(handoff.$schema, "celorga:doctor-handoff:v1");
  assert.equal(handoff.recurring, false);
  assert.deepEqual(handoff.playbook, { id: "troubleshoot", version: 1, title: "Troubleshoot this Celorga installation" });
  assert.equal(handoff.runtime.found, true);
  assert.equal(handoff.launch.argv[0], "opencode");
  assert.equal(handoff.launch.argv[1], root);
  assert.equal(handoff.launch.argv[2], "--prompt");
  assert.equal(handoff.launch.argv[3], handoff.prompt);
  assert.match(handoff.prompt, /Playbook: Troubleshoot this Celorga installation/);
  assert.match(handoff.prompt, /create recurring automations or scheduled jobs/);
  assert.match(handoff.prompt, /waiting-empty/);
  assert.deepEqual(JSON.parse(handoff.launch.env.OPENCODE_CONFIG_CONTENT).permission,
    { edit: "ask", bash: "ask", external_directory: "ask" });
  assert.ok(!preview.stdout.includes("sentinel-value-must-not-leak"));
  assert.deepEqual(allFiles(root), before);

  const text = doctor("--handoff", "opencode");
  assert.equal(text.status, 0, text.stderr);
  assert.match(text.stdout, /Preview only\. Pass --apply/);
  assert.match(text.stdout, /No recurring job is created\./);

  // --apply writes exactly one packet into the review zone.
  const applied = doctor("--handoff", "opencode", "--apply", "--json");
  assert.equal(applied.status, 0, applied.stderr);
  const appliedJson = JSON.parse(applied.stdout);
  assert.equal(appliedJson.applied, true);
  const added = allFiles(root).filter((file) => !before.includes(file));
  assert.equal(added.length, 1);
  assert.match(added[0], /^views\/diagnostics\/handoffs\/\d{8}T\d{6}Z-opencode\.json$/);
  assert.equal(appliedJson.handoff.handoffFile, added[0]);
  const stored = fs.readFileSync(path.join(root, added[0]), "utf8");
  assert.equal(JSON.parse(stored).recurring, false);
  assert.equal(JSON.parse(stored).launch.cwd, ".");
  assert.ok(!stored.includes(root), "stored packet carries no machine-local corpus path");
  assert.ok(!stored.includes("sentinel-value-must-not-leak"));

  // --launch starts the selected runtime exactly once in the foreground and
  // propagates its exit status. Nothing is scheduled anywhere under HOME.
  const filesBeforeLaunch = allFiles(root);
  const launched = doctor("--handoff", "opencode", "--launch");
  assert.equal(launched.status, 7, launched.stderr);
  assert.match(launched.stderr, /Starting OpenCode once in this terminal/);
  const seen = JSON.parse(fs.readFileSync(record, "utf8"));
  assert.equal(seen.argv[0], root);
  assert.equal(seen.argv[1], "--prompt");
  assert.match(seen.argv[2], /Celorga troubleshooting handoff\./);
  assert.equal(fs.realpathSync(seen.cwd), fs.realpathSync(root));
  assert.equal(JSON.parse(seen.config).permission.edit, "ask");
  assert.deepEqual(allFiles(root), filesBeforeLaunch);
  assert.deepEqual(allFiles(home), [], "no launch agent, cron, or other scheduled job is created");

  // A missing selected runtime is reported, not substituted.
  const missing = doctor("--handoff", "codex", "--json");
  assert.equal(missing.status, 0, missing.stderr);
  const missingJson = JSON.parse(missing.stdout).handoff;
  assert.equal(missingJson.runtime.found, false);
  assert.match(missingJson.unavailableReason, /ORG2_CODEX_EXECUTABLE/);
  assert.deepEqual(missingJson.launch.argv.slice(0, 5), ["codex", "--sandbox", "read-only", "--cd", root]);
  const missingLaunch = doctor("--handoff", "codex", "--launch");
  assert.notEqual(missingLaunch.status, 0);
  assert.match(missingLaunch.stderr, /ORG2_CODEX_EXECUTABLE/);

  // OpenClaw is prepare-only.
  const openclaw = JSON.parse(doctor("--handoff", "openclaw", "--json").stdout).handoff;
  assert.equal(openclaw.launch, null);
  assert.equal(openclaw.runtime.launchSupported, false);
  assert.notEqual(doctor("--handoff", "openclaw", "--launch").status, 0);

  // The selected agent profile's default runtime chooses the handoff target.
  const profile = spawnSync(process.execPath, [cli, "agent-profile", "create", "fixture-helper", "--name", "Fixture helper",
    "--default-runtime", "claude", "--dir", root, "--apply"], { encoding: "utf8", env });
  assert.equal(profile.status, 0, profile.stderr);
  const byProfile = JSON.parse(doctor("--agent-ref", "fixture-helper", "--json").stdout).handoff;
  assert.equal(byProfile.agentRef, "fixture-helper");
  assert.equal(byProfile.runtime.id, "claude");
  assert.deepEqual(byProfile.launch.argv.slice(0, 3), ["claude", "--permission-mode", "plan"]);
  assert.match(byProfile.prompt, /Selected agent profile: fixture-helper/);

  // Invalid combinations fail closed.
  assert.match(doctor("--launch").stderr, /require --handoff/);
  assert.match(doctor("--handoff", "nonsense").stderr, /--handoff must be one of/);
  assert.match(doctor("--handoff", "opencode", "--playbook", "onboarding").stderr, /extension point/);

  // Extension points are documented but not runnable yet.
  assert.deepEqual(
    AGENT_PLAYBOOKS.map((playbook) => [playbook.id, playbook.status]),
    [["troubleshoot", "available"], ["onboarding", "extension-point"], ["stalled-work-review", "extension-point"], ["release-preparation", "extension-point"]],
  );
  for (const playbook of AGENT_PLAYBOOKS) {
    assert.ok(playbook.operations.length > 0, playbook.id);
    if (playbook.status === "extension-point") assert.throws(() => renderAgentPlaybookPrompt(playbook), /extension point/);
  }

  console.log("doctor handoff tests passed");
} finally {
  fs.rmSync(sandbox, { recursive: true, force: true });
}
