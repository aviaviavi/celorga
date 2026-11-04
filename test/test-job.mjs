import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";

const cli = path.resolve("dist/cli.js");
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-job-"));
const root = path.join(scratch, "corpus");
const workdir = path.join(scratch, "work");
const env = { ...process.env, ORG2_INDEX_HOME: path.join(scratch, "index"), CELORGA_INDEX_HOME: path.join(scratch, "index") };
const threadID = "00000000-0000-4000-8000-0000000000a1";
const inbox = path.join(root, ".org2", "ai-chat-inbox");
const startedPids = [];

function celorga(args, options = {}) {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", env, ...options });
  return result;
}

function celorgaJSON(args) {
  const separator = args.indexOf("--");
  const result = celorga(separator < 0
    ? [...args, "--json"]
    : [...args.slice(0, separator), "--json", ...args.slice(separator)]);
  assert.equal(result.status, 0, `${args.join(" ")}\n${result.stderr}`);
  return JSON.parse(result.stdout);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForJob(id, predicate, timeoutMs = 90_000) {
  const deadline = Date.now() + timeoutMs;
  let status;
  while (Date.now() < deadline) {
    status = celorgaJSON(["job", "status", id, "--dir", root]);
    if (predicate(status)) return status;
    await sleep(250);
  }
  assert.fail(`job ${id} did not reach the expected state: ${JSON.stringify(status?.job)}`);
}

function inboxMessages() {
  if (!fs.existsSync(inbox)) return [];
  return fs.readdirSync(inbox)
    .filter((name) => name.endsWith(".json"))
    .map((name) => JSON.parse(fs.readFileSync(path.join(inbox, name), "utf8")));
}

function groupAlive(pid) {
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

const node = process.execPath;

try {
  fs.mkdirSync(path.join(root, ".org2"), { recursive: true });
  fs.mkdirSync(workdir, { recursive: true });
  fs.writeFileSync(path.join(root, ".org2", "openclaw-chat.json"), `${JSON.stringify({
    version: 6,
    selectedThreadID: threadID.toUpperCase(),
    threads: [{
      id: threadID.toUpperCase(),
      title: "Example build chat",
      createdAt: 0,
      updatedAt: 0,
      sessionKey: "agent:main:example",
      messages: [],
    }],
  }, null, 2)}\n`);

  // Help and general discovery.
  const help = celorga(["job", "--help"]);
  assert.equal(help.status, 0);
  assert.match(help.stdout, /celorga job start/);
  assert.match(celorga(["--help"]).stderr, /celorga job start\|list\|status\|stop/);
  const capabilities = JSON.parse(celorga(["agent", "capabilities"]).stdout);
  assert.ok(capabilities.workflows.some((workflow) => workflow.commands.includes("celorga job start")));

  // Preview without --apply writes nothing and starts nothing.
  const preview = celorgaJSON(["job", "start", "--dir", root, "--thread", threadID, "--label", "Example build", "--cwd", workdir, "--", node, "-e", "require('fs').writeFileSync('ran.txt', 'yes')"]);
  assert.equal(preview.applied, false);
  assert.equal(preview.job.state, "starting");
  assert.equal(preview.job.threadID, threadID);
  assert.equal(preview.job.authorLabel, "Background job");
  await sleep(500);
  assert.equal(fs.existsSync(path.join(workdir, "ran.txt")), false);
  assert.equal(fs.existsSync(path.dirname(preview.job.logFile)), false);
  assert.deepEqual(celorgaJSON(["job", "list", "--dir", root, "--all"]).jobs, []);

  // Validation happens before anything runs.
  assert.match(celorga(["job", "start", "--dir", root, "--thread", "missing-thread", "--apply", "--", node, "-e", ""]).stderr, /unknown OpenClaw thread/);
  assert.match(celorga(["job", "start", "--dir", root, "--apply"]).stderr, /requires -- COMMAND/);
  assert.match(celorga(["job", "status", "../escape", "--dir", root]).stderr, /invalid job ID/);
  assert.match(celorga(["job", "list", "--dir", root, "--bogus", "x"]).stderr, /does not accept --bogus/);

  // Start from a caller in its own process group, then kill that whole group:
  // the job must survive and report into the thread exactly once.
  const script = "console.log('compiling example'); console.log('* heading-like line'); setTimeout(() => { console.log('build finished'); }, 1500);";
  const caller = spawn("/bin/sh", ["-c", `"$0" "$@"; sleep 60`, node, cli, "job", "start", "--dir", root, "--thread", threadID, "--label", "Example build", "--cwd", workdir, "--agent-ref", "agent-profile-example", "--json", "--apply", "--", node, "-e", script], {
    detached: true,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let callerOutput = "";
  caller.stdout.setEncoding("utf8");
  caller.stdout.on("data", (chunk) => { callerOutput += chunk; });
  const startDeadline = Date.now() + 60_000;
  while (!callerOutput.trim().endsWith("}") && Date.now() < startDeadline) await sleep(100);
  const started = JSON.parse(callerOutput);
  process.kill(-caller.pid, "SIGKILL");
  assert.equal(started.applied, true);
  const jobID = started.job.id;
  assert.match(jobID, /^\d{8}-\d{6}-[0-9a-f]{6}$/);
  assert.equal(fs.existsSync(started.job.logFile), true);
  assert.ok(!started.job.logFile.startsWith(root), "job state stays out of the corpus");

  const running = celorgaJSON(["job", "list", "--dir", root, "--thread", threadID.toUpperCase()]);
  assert.ok(running.jobs.some((job) => job.id === jobID && job.running), JSON.stringify(running));
  assert.deepEqual(celorgaJSON(["job", "list", "--dir", root, "--thread", "00000000-0000-4000-8000-0000000000ff"]).jobs, []);

  const finished = await waitForJob(jobID, (status) => !status.job.running && status.job.delivery);
  startedPids.push(finished.job.pid);
  assert.equal(finished.job.state, "succeeded");
  assert.equal(finished.job.exitCode, 0);
  assert.equal(finished.job.delivery.status, "queued");
  assert.match(finished.logTail, /compiling example/);
  assert.match(finished.logTail, /build finished/);
  assert.equal(finished.job.label, "Example build");

  let messages = inboxMessages();
  assert.equal(messages.length, 1, "exactly one exit message");
  const [exitMessage] = messages;
  assert.equal(exitMessage.threadID, threadID);
  assert.equal(exitMessage.authorLabel, "Background job");
  assert.equal(exitMessage.authorAgentRef, "agent-profile-example");
  assert.equal(exitMessage.source, `job:${jobID}`);
  assert.equal(exitMessage.id, finished.job.delivery.messageID);
  assert.match(exitMessage.content, /^Background job \*Example build\* succeeded after/);
  assert.match(exitMessage.content, /#\+begin_example\n[\s\S]*build finished\n#\+end_example/);
  assert.match(exitMessage.content, /\n,\* heading-like line\n/, "log lines that look like headings are escaped");

  const statusText = celorga(["job", "status", jobID, "--dir", root]);
  assert.equal(statusText.status, 0);
  assert.match(statusText.stdout, /succeeded/);
  assert.match(statusText.stdout, /--- log tail ---\n[\s\S]*build finished/);
  assert.deepEqual(celorgaJSON(["job", "list", "--dir", root]).jobs, [], "finished jobs are hidden by default");
  assert.ok(celorgaJSON(["job", "list", "--dir", root, "--all"]).jobs.some((job) => job.id === jobID));

  // A failing job without a thread records its exit and posts nothing.
  const failing = celorgaJSON(["job", "start", "--dir", root, "--cwd", workdir, "--apply", "--", node, "-e", "console.error('example failure'); process.exit(3)"]);
  const failed = await waitForJob(failing.job.id, (status) => !status.job.running);
  assert.equal(failed.job.state, "failed");
  assert.equal(failed.job.exitCode, 3);
  assert.equal(failed.job.delivery, undefined);
  assert.match(failed.logTail, /example failure/);
  assert.equal(inboxMessages().length, 1);

  // A missing executable fails instead of hanging.
  const missing = celorgaJSON(["job", "start", "--dir", root, "--cwd", workdir, "--apply", "--", path.join(scratch, "no-such-tool")]);
  const missingStatus = await waitForJob(missing.job.id, (status) => !status.job.running);
  assert.equal(missingStatus.job.state, "failed");
  assert.equal(missingStatus.job.exitCode, 127);

  // Stop previews by default, then terminates the process group once.
  const server = celorgaJSON(["job", "start", "--dir", root, "--thread", threadID, "--label", "Example server", "--cwd", workdir, "--apply", "--", node, "-e", "console.log('listening'); setInterval(() => {}, 1000)"]);
  const serving = await waitForJob(server.job.id, (status) => status.job.state === "running");
  startedPids.push(serving.job.pid);
  const stopPreview = celorgaJSON(["job", "stop", server.job.id, "--dir", root]);
  assert.equal(stopPreview.applied, false);
  assert.equal(stopPreview.changed, true);
  assert.equal(celorgaJSON(["job", "status", server.job.id, "--dir", root]).job.state, "running");
  assert.equal(groupAlive(serving.job.pid), true);
  const stopped = celorgaJSON(["job", "stop", server.job.id, "--dir", root, "--grace", "2", "--apply"]);
  assert.equal(stopped.applied, true);
  const stoppedStatus = await waitForJob(server.job.id, (status) => status.job.state === "stopped" && status.job.delivery);
  assert.ok(stoppedStatus.job.stopRequestedAt);
  assert.equal(groupAlive(serving.job.pid), false);
  messages = inboxMessages();
  assert.equal(messages.length, 2);
  assert.ok(messages.some((message) => message.source === `job:${server.job.id}` && /\*Example server\* was stopped after/.test(message.content)));
  const again = celorgaJSON(["job", "stop", server.job.id, "--dir", root, "--apply"]);
  assert.equal(again.applied, false);
  assert.equal(again.changed, false);

  // A job whose supervisor died is reported as lost, not running.
  const dead = spawnSync(node, ["-e", "console.log(process.pid)"], { encoding: "utf8" });
  const deadPid = Number(dead.stdout.trim());
  const jobsDirectory = path.dirname(path.dirname(started.job.logFile));
  const lostID = "20260101-000000-abcdef";
  fs.mkdirSync(path.join(jobsDirectory, lostID), { recursive: true });
  fs.writeFileSync(path.join(jobsDirectory, lostID, "job.json"), JSON.stringify({
    ...finished.job,
    id: lostID,
    label: "Example lost job",
    threadID: undefined,
    state: "running",
    supervisorPid: deadPid,
    pid: deadPid,
    exitCode: undefined,
    endedAt: undefined,
    delivery: undefined,
    running: undefined,
    durationMs: undefined,
    logFile: path.join(jobsDirectory, lostID, "output.log"),
  }));
  const lost = celorgaJSON(["job", "status", lostID, "--dir", root]);
  assert.equal(lost.job.state, "lost");
  assert.equal(lost.job.running, false);
  assert.ok(!celorgaJSON(["job", "list", "--dir", root]).jobs.some((job) => job.id === lostID));
  const lostStop = celorgaJSON(["job", "stop", lostID, "--dir", root, "--grace", "0", "--apply"]);
  assert.equal(lostStop.applied, true);
  assert.equal(lostStop.job.state, "stopped");

  console.log("test-job: ok");
} finally {
  for (const pid of startedPids) {
    try { process.kill(-pid, "SIGKILL"); } catch {}
  }
  fs.rmSync(scratch, { recursive: true, force: true });
}
