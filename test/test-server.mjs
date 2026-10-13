import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync, spawn } from "node:child_process";
import { validateServerConfiguration, serverLaunchAgent, serverControl, drainServer } from "../dist/serverCli.js";
import { acquireWorkflowDispatchLock, assignAutomationHost, automationHostRef } from "../dist/automationHost.js";
import { initializeCorpusIdentity } from "../dist/corpusIdentity.js";
import { loadAgentRun, saveAgentRun, transitionAgentRun } from "../dist/agentRun.js";

const headlessServerSource = fs.readFileSync(
  path.resolve("apps/macos/Org2Workspace/Sources/OpenOrgServer/main.swift"),
  "utf8",
);
assert.match(
  headlessServerSource,
  /filesystemAccess != \.readOnly,[\s\S]*Org2Workspace\.openClawLocalEditsEnabled\.v1/,
  "the headless filesystem policy must also control OpenClaw local edits",
);
const workspaceStoreSource = fs.readFileSync(
  path.resolve("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/WorkspaceStore.swift"),
  "utf8",
);
assert.match(
  workspaceStoreSource,
  /bootstrapHeadless\([\s\S]*if openClawLocalEditsEnabled \{\s*startOpenClawLocalEditNode\(\)/,
  "the headless bootstrap must start the enabled OpenClaw local edit bridge",
);

const temporary = fs.mkdtempSync(path.join(process.platform === "darwin" ? "/tmp" : os.tmpdir(), "org2-server-test-"));
const corpus = path.join(temporary, "corpus");
const cli = path.resolve("dist/cli.js");
const configFile = path.join(temporary, "state/server.json");
function run(...args) {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
async function concurrent(...args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cli, ...args]);
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

try {
  fs.mkdirSync(corpus);
  initializeCorpusIdentity(corpus, { id: "server-test", name: "Server test", kind: "project" }, { apply: true });
  assert.equal(automationHostRef(corpus), "desktop");
  assert.equal(assignAutomationHost(corpus, "press", false).applied, false);
  assert.equal(automationHostRef(corpus), "desktop", "ownership previews must not mutate the corpus");
  assignAutomationHost(corpus, "press", true);
  assert.equal(automationHostRef(corpus), "press");
  const before = fs.readFileSync(path.join(corpus, "celorga.json"), "utf8");
  assert.throws(() => assignAutomationHost(corpus, "../bad", true));
  assert.equal(fs.readFileSync(path.join(corpus, "celorga.json"), "utf8"), before);

  const init = run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2", "--config", configFile);
  assert.equal(init.applied, false);
  assert.equal(fs.existsSync(configFile), false);
  const config = init.config;
  assert.equal(config.localAgentFilesystemAccess, "workspaceWrite");
  assert.equal(config.chatRepairIntervalSeconds, 120);
  const legacyRepair = { ...config };
  delete legacyRepair.chatRepairIntervalSeconds;
  assert.equal(validateServerConfiguration(legacyRepair, configFile).chatRepairIntervalSeconds, 120);
  for (const seconds of [-1, 9, 86401, "NaN"]) {
    assert.throws(() => validateServerConfiguration({ ...config, chatRepairIntervalSeconds: seconds }, configFile), /repair interval/);
  }
  assert.deepEqual(config.mcp, { enabled: false, port: 48923, allowedOrigins: [], accessTokens: [] });
  const fullAccessInit = run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2",
    "--filesystem-access", "full-access", "--config", configFile);
  assert.equal(fullAccessInit.config.localAgentFilesystemAccess, "fullAccess");
  const piInit = run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2",
    "--destination", "pi", "--config", configFile);
  assert.deepEqual(piInit.config.destinations[0], {
    id: "builtin.pi", name: "Pi", mention: "pi", adapter: "piLocal", endpoint: "", agentID: "", workspaceRoot: "", isEnabled: true,
  });
  const openCodeInit = run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2",
    "--destination", "opencode", "--config", configFile);
  assert.deepEqual(openCodeInit.config.destinations[0], {
    id: "builtin.opencode", name: "OpenCode", mention: "opencode", adapter: "openCodeLocal", endpoint: "", agentID: "", workspaceRoot: "", isEnabled: true,
  });
  assert.equal(validateServerConfiguration({ ...config, destinations: [{ ...config.destinations[0], adapter: "piRemote" }] }, configFile).destinations[0].adapter, "piRemote");
  assert.equal(validateServerConfiguration({ ...config, destinations: [{ ...config.destinations[0], adapter: "openCodeRemote" }] }, configFile).destinations[0].adapter, "openCodeRemote");
  assert.equal(validateServerConfiguration(config, configFile).hostRef, "press");
  const legacyConfig = { ...config };
  delete legacyConfig.localAgentFilesystemAccess;
  assert.equal(validateServerConfiguration(legacyConfig, configFile).localAgentFilesystemAccess, "workspaceWrite");
  const legacyMcpConfig = { ...config };
  delete legacyMcpConfig.mcp;
  assert.deepEqual(validateServerConfiguration(legacyMcpConfig, configFile).mcp, { enabled: false, port: 48923, allowedOrigins: [], accessTokens: [] });
  assert.throws(() => validateServerConfiguration({ ...config, localAgentFilesystemAccess: "root" }, configFile), /read-only/);
  assert.throws(() => validateServerConfiguration({ ...config, localAgentFilesystemAccess: false }, configFile), /read-only/);
  assert.throws(() => validateServerConfiguration({ ...config, bindHost: "0.0.0.0" }, configFile), /Tailscale/);
  assert.throws(() => validateServerConfiguration({ ...config, port: 0 }, configFile), /port/);
  assert.throws(() => validateServerConfiguration({ ...config, mcp: { ...config.mcp, port: config.port } }, configFile), /different/);
  assert.throws(() => validateServerConfiguration({ ...config, mcp: { ...config.mcp, enabled: true } }, configFile), /access token/);
  assert.throws(() => validateServerConfiguration(config, path.join(corpus, "server.json")), /machine-local/);
  fs.symlinkSync(corpus, path.join(temporary, "corpus-link"));
  assert.throws(() => validateServerConfiguration(config, path.join(temporary, "corpus-link/server.json")), /machine-local/);
  run("server", "init", "--dir", corpus, "--host-ref", "press", "--bind", "100.64.1.2", "--config", configFile, "--apply");
  assert.equal(fs.statSync(configFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(configFile)).mode & 0o777, 0o700);
  const repairPreview = run("server", "chat-repair", "--interval", "900", "--config", configFile);
  assert.equal(repairPreview.applied, false);
  assert.equal(repairPreview.chatRepairIntervalSeconds, 900);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).chatRepairIntervalSeconds, 120);
  const repairApplied = run("server", "chat-repair", "--interval", "off", "--config", configFile, "--apply");
  assert.equal(repairApplied.restartRequired, true);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).chatRepairIntervalSeconds, 0);
  const permissionsPreview = run("server", "permissions", "--filesystem-access", "full-access", "--config", configFile);
  assert.equal(permissionsPreview.applied, false);
  assert.equal(permissionsPreview.previousFilesystemAccess, "workspaceWrite");
  assert.equal(permissionsPreview.filesystemAccess, "fullAccess");
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).localAgentFilesystemAccess, "workspaceWrite");
  const permissionsApplied = run("server", "permissions", "--filesystem-access", "full-access", "--config", configFile, "--apply");
  assert.equal(permissionsApplied.applied, true);
  assert.equal(permissionsApplied.restartRequired, true);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).localAgentFilesystemAccess, "fullAccess");
  assert.equal(fs.statSync(configFile).mode & 0o777, 0o600);
  const tokenPreview = run("server", "token", "create", "--name", "ChatGPT", "--config", configFile);
  assert.equal(tokenPreview.applied, false);
  assert.equal(tokenPreview.enablesMcp, true);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).mcp.enabled, false);
  const createdToken = run("server", "token", "create", "--name", "ChatGPT", "--config", configFile, "--apply");
  assert.equal(createdToken.applied, true);
  assert.match(createdToken.accessToken, /^org2_[A-Za-z0-9_-]+$/);
  assert.equal(createdToken.token.scopes[0], "corpus:read");
  const configuredMcp = JSON.parse(fs.readFileSync(configFile, "utf8")).mcp;
  assert.equal(configuredMcp.enabled, true);
  assert.equal(configuredMcp.accessTokens.length, 1);
  assert.equal(configuredMcp.accessTokens[0].tokenHash.length, 64);
  assert.equal(JSON.stringify(configuredMcp).includes(createdToken.accessToken), false, "plaintext tokens must never be stored");
  const listedTokens = run("server", "token", "list", "--config", configFile);
  assert.equal(listedTokens.mcp.tokens[0].id, createdToken.token.id);
  assert.equal(JSON.stringify(listedTokens).includes("tokenHash"), false);
  const disabledMcp = run("server", "mcp", "disable", "--config", configFile, "--apply");
  assert.equal(disabledMcp.mcp.enabled, false);
  const enabledMcp = run("server", "mcp", "enable", "--mcp-port", "49001", "--allow-origin", "https://chatgpt.com", "--config", configFile, "--apply");
  assert.equal(enabledMcp.mcp.enabled, true);
  assert.equal(enabledMcp.mcp.endpoint, "http://100.64.1.2:49001/mcp");
  assert.deepEqual(enabledMcp.mcp.allowedOrigins, ["https://chatgpt.com"]);
  const revokePreview = run("server", "token", "revoke", "--id", createdToken.token.id, "--config", configFile);
  assert.equal(revokePreview.applied, false);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).mcp.accessTokens.length, 1);
  const revokedToken = run("server", "token", "revoke", "--id", createdToken.token.id, "--config", configFile, "--apply");
  assert.equal(revokedToken.applied, true);
  assert.equal(revokedToken.disablesMcp, true);
  assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).mcp.enabled, false);
  const plist = serverLaunchAgent(configFile, { ...config, name: "A & B", repoRoot: "/tmp/a&b" });
  assert.match(plist, /\/tmp\/a&amp;b\/dist\/cli.js/);
  assert.match(plist, /SuccessfulExit/);

  run("workflow", "create", "scheduled", "--title", "Test schedule", "--prompt", "Report ready", "--schedule", "every 1m",
    "--destination-ref", "builtin.codex", "--now", "2026-09-01T00:00:00.000Z", "--dir", corpus, "--json");
  const now = "2026-09-01T00:05:00.000Z";
  const desktopDue = run("workflow", "due", "--dir", corpus, "--now", now, "--json");
  assert.equal(desktopDue.due.length, 0, "desktop must skip a server-owned corpus");
  assert.equal(desktopDue.hostRef, "press");
  const due = run("workflow", "due", "--host-ref", "press", "--dir", corpus, "--now", now, "--json");
  assert.equal(due.due.length, 1);
  assert.equal(due.hostRef, "press");
  const occurrence = due.due[0].scheduledFor;
  const args = ["workflow", "run", "scheduled", "--trigger", "schedule", "--scheduled-for", occurrence, "--dir", corpus, "--json"];
  assert.equal(run(...args).eligible, false, "ownership must be rechecked at dispatch time");
  const results = await Promise.all([concurrent(...args, "--host-ref", "press"), concurrent(...args, "--host-ref", "press")]);
  const created = results.filter((result) => result.code === 0).map((result) => JSON.parse(result.stdout)).filter((result) => result.run);
  assert.equal(created.length, 1, JSON.stringify(results));
  const runID = created[0].run.id;
  saveAgentRun(corpus, transitionAgentRun(loadAgentRun(corpus, runID), "failed", { reason: "test finished" }));
  const duplicate = run(...args, "--host-ref", "press");
  assert.equal(duplicate.eligible, false);
  assert.match(duplicate.reason, /occurrence already/);
  const release = acquireWorkflowDispatchLock(corpus, "scheduled");
  assert.throws(() => acquireWorkflowDispatchLock(corpus, "scheduled"), /EEXIST/);
  const unrelated = acquireWorkflowDispatchLock(corpus, "independent");
  unrelated();
  release();
  acquireWorkflowDispatchLock(corpus, "scheduled")();
  if (process.platform === "darwin") {
    const worker = path.join(temporary, "fake-worker.mjs");
    fs.writeFileSync(worker, `#!/usr/bin/env node
import readline from 'node:readline';
console.log(JSON.stringify({event:'ready'}));
for await (const line of readline.createInterface({input:process.stdin})) {
 const request=JSON.parse(line);
 if (request.command==='retry-message' || request.command==='stop-thread') { console.log(JSON.stringify({id:request.id,result:{command:request.command,messageID:request.messageID,threadID:request.threadID}})); continue; }
 console.log(JSON.stringify({id:request.id,result:request.command==='stop'?{stopped:true}:{listening:true}}));
 if(request.command==='stop') process.exit(0);
}
`, { mode: 0o700 });
    fs.writeFileSync(configFile, JSON.stringify({ ...config, executable: worker }));
    // A returned stop result must mean launchd can start the service again,
    // not merely that the native child has queued its final response.
    for (let attempt = 0; attempt < 2; attempt++) {
      const supervisor = spawn(process.execPath, [cli, "server", "start", "--config", configFile]);
      const exited = new Promise((resolve) => supervisor.once("exit", resolve));
      let errors = "";
      supervisor.stderr.on("data", (data) => { errors += data; });
      try {
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error(`Server did not start: ${errors}`)), 10_000);
          supervisor.stdout.on("data", (data) => {
            if (data.toString().includes('"event":"ready"')) { clearTimeout(timer); resolve(); }
          });
          supervisor.once("error", reject);
        });
        assert.equal((await serverControl(configFile, "status")).listening, true);
        assert.deepEqual(await serverControl(configFile, "retry-message", { messageID: "exact-message" }),
          { command: "retry-message", messageID: "exact-message" });
        assert.deepEqual(await serverControl(configFile, "stop-thread", { threadID: "exact-thread" }),
          { command: "stop-thread", threadID: "exact-thread" });
        assert.deepEqual(await serverControl(configFile, "not-a-command"), { error: "Unknown control command" });
        const stopped = await concurrent("server", "stop", "--config", configFile);
        assert.equal(stopped.code, 0, stopped.stderr);
        assert.equal(JSON.parse(stopped.stdout).stopped, true);
        assert.equal(await exited, 0, errors);
        assert.throws(() => process.kill(supervisor.pid, 0), { code: "ESRCH" });
      } finally {
        if (supervisor.exitCode === null) supervisor.kill();
      }
    }
  }
  // Draining waits for running turns before a restart, and reports a timeout.
  {
    const calls = [];
    let running = 2;
    const control = async (command) => {
      calls.push(command);
      if (command === "drain") return { draining: true, runningThreads: running };
      running = Math.max(0, running - 1);
      return { runningThreads: running, draining: true };
    };
    assert.deepEqual(await drainServer("unused", 30, control, 5), { drained: true, remaining: 0, waitedSeconds: 0 });
    assert.deepEqual(calls, ["drain", "status", "status"]);
    const stuck = await drainServer("unused", 0.05, async (command) => ({ runningThreads: 1, draining: command === "drain" || true }), 10);
    assert.equal(stuck.drained, false);
    assert.equal(stuck.remaining, 1);
    await assert.rejects(drainServer("unused", 1, async () => ({ error: "Server worker is starting or unavailable" })), /starting or unavailable/);
  }
  if (process.platform === "darwin") {
    const worker = path.join(temporary, "draining-worker.mjs");
    const log = path.join(temporary, "draining-worker.log");
    fs.writeFileSync(worker, `#!/usr/bin/env node
import fs from 'node:fs';
import readline from 'node:readline';
let running = 1;
let draining = false;
console.log(JSON.stringify({event:'ready'}));
for await (const line of readline.createInterface({input:process.stdin})) {
 const request=JSON.parse(line);
 fs.appendFileSync(${JSON.stringify(log)}, request.command + (draining ? ':draining' : '') + '\\n');
 if (request.command==='drain') { draining = true; console.log(JSON.stringify({id:request.id,result:{draining:true,runningThreads:running}})); continue; }
 if (request.command==='status') { if (draining) running = 0; console.log(JSON.stringify({id:request.id,result:{listening:true,draining,runningThreads:running}})); continue; }
 console.log(JSON.stringify({id:request.id,result:request.command==='stop'?{stopped:true}:{}}));
 if(request.command==='stop') process.exit(0);
}
`, { mode: 0o700 });
    fs.writeFileSync(configFile, JSON.stringify({ ...config, executable: worker }));
    const supervisor = spawn(process.execPath, [cli, "server", "start", "--config", configFile]);
    const exited = new Promise((resolve) => supervisor.once("exit", resolve));
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("Server did not start")), 10_000);
        supervisor.stdout.on("data", (data) => { if (data.toString().includes('"event":"ready"')) { clearTimeout(timer); resolve(); } });
      });
      const stopped = await concurrent("server", "stop", "--drain", "--drain-timeout", "20", "--config", configFile);
      assert.equal(stopped.code, 0, stopped.stderr);
      const result = JSON.parse(stopped.stdout);
      assert.equal(result.stopped, true);
      assert.equal(result.drain.drained, true);
      assert.equal(await exited, 0);
      assert.deepEqual(fs.readFileSync(log, "utf8").trim().split("\n"), ["drain", "status:draining", "stop:draining"]);
    } finally {
      if (supervisor.exitCode === null) supervisor.kill();
    }
  }
  console.log("server configuration, ownership, and concurrent dispatch tests passed");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
