import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const deliveryID = randomUUID();
const deviceID = randomUUID();
const event = stage => ({ deliveryID, deviceID, runID: "fixture-run", approvalID: "fixture-approval", fingerprint: "fixture-fingerprint", stage, simulated: false, headset: true, observedAt: new Date().toISOString() });
const played = () => [event("push-received"), event("playback-started"), event("playback-completed")];
const cases = [
  ["APNs acceptance alone", [event("apns-accepted")], false],
  ["simulated playback", played().map(e => e.stage === "playback-completed" ? { ...e, simulated: true } : e), false],
  ["an older delivery", played().map(e => ({ ...e, deliveryID: randomUUID() })), false],
  ["an old receipt for the same delivery", played().map(e => ({ ...e, observedAt: "2020-01-01T00:00:00Z" })), false],
  ["another device", played().map(e => ({ ...e, deviceID: randomUUID() })), false],
  ["a non-headset output", played().map(e => e.stage === "playback-completed" ? { ...e, headset: false } : e), false],
  ["no incoming-push receipt", played().filter(e => e.stage !== "push-received"), false],
  ["no audio buffers started", played().filter(e => e.stage !== "playback-started"), false],
  ["this delivery on the real headset", played(), true],
];
for (const [name, events, expected] of cases) {
  let probed = false;
  const server = http.createServer((request, response) => {
    assert.equal(request.headers.authorization, "Bearer synthetic-test-token");
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/v1/audio-approvals/probe") {
      probed = true;
      response.end(JSON.stringify({ deliveryID, deviceID }));
    } else if (request.url === "/v1/audio-approvals/diagnostics") {
      response.end(JSON.stringify(probed ? events : []));
    } else { response.writeHead(404); response.end("{}"); }
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const child = spawn(process.execPath, ["tools/test-audio-approvals-live.mjs", "--endpoint", `http://127.0.0.1:${server.address().port}`, "--token-env", "CELORGA_SYNTHETIC_PROBE_TOKEN", "--run", "fixture-run", "--approval", "fixture-approval", "--fingerprint", "fixture-fingerprint", "--wait", "1"], {
      cwd: root, env: { ...process.env, CELORGA_SYNTHETIC_PROBE_TOKEN: "synthetic-test-token" }, stdio: ["ignore", "pipe", "pipe"]
    });
    let output = "";
    child.stdout.on("data", data => { output += data; });
    child.stderr.on("data", data => { output += data; });
    const code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
    assert.equal(code, expected ? 0 : 1, `${name}: ${output}`);
    assert.ok(!output.includes("synthetic-test-token"), "Credentials must never enter output");
    const evidencePath = output.match(/Evidence: (.+\/result\.json)/)?.[1];
    assert.ok(evidencePath, `Missing evidence for ${name}`);
    assert.equal(JSON.parse(fs.readFileSync(evidencePath, "utf8")).passed, expected, name);
    fs.rmSync(path.dirname(evidencePath), { recursive: true });
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}
console.log(`Live playback probe passed ${cases.length} black-box checks; only the exact real-device headset receipt passes.`);
