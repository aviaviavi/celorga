#!/usr/bin/env node
// A live probe passes only on the phone's real playback-completion callback for this
// unique delivery. APNs acceptance, old receipts, and simulated callbacks cannot pass it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const options = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const name = process.argv[i];
  if (!name.startsWith("--") || !process.argv[i + 1]) throw new Error("Every option requires a value.");
  options[name.slice(2)] = process.argv[i + 1];
}
for (const name of ["run", "approval", "fingerprint"]) {
  if (!options[name]) throw new Error(`--${name} is required; select a harmless pending test approval.`);
}
const waitSeconds = Number(options.wait || 60);
if (!(waitSeconds >= 1 && waitSeconds <= 120)) throw new Error("--wait must be 1–120 seconds.");
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-audio-live-"));
let endpoint = options.endpoint;
let token = options["token-env"] ? process.env[options["token-env"]] : null;
let temporaryPair = false;
const evidence = { passed: false, startedAt: new Date().toISOString(), events: [] };
async function call(route, body) {
  const response = await fetch(new URL(route, endpoint), {
    method: body === undefined ? "GET" : "POST",
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), "Content-Type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(15_000)
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({}));
    const known = {
      quiet: "The phone is in quiet mode; the probe did not override it.",
      snoozed: "This approval is snoozed; the probe did not override it.",
      "already-played": "This test approval was already played; select a fresh harmless approval.",
      "audio-busy": "A previous prompt is still in its answer window."
    };
    const error = new Error(known[failure.code] || `${route}: HTTP ${response.status}. Update the host and phone to a build supporting live playback receipts, and use an enrolled headset channel.`);
    error.code = failure.code;
    throw error;
  }
  return response.json();
}
try {
  if (!token) {
    const host = options["ssh-host"];
    const config = options["server-config"];
    if (!host || !/^[A-Za-z0-9_.@-]+$/.test(host) || host.startsWith("-") || !config) {
      throw new Error("Supply --endpoint and --token-env NAME, or --ssh-host HOST and --server-config PATH. Tokens must never appear in arguments.");
    }
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    let pair;
    try {
      pair = JSON.parse(execFileSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
        ["celorga", "server", "pair", "--config", config].map(quote).join(" ")], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    } catch { throw new Error("The native server pairing command failed; credential output was suppressed."); }
    endpoint ||= pair.endpoint;
    const paired = await call("/v1/pair", { code: pair.code, deviceName: "Temporary audio playback probe" });
    token = paired.accessToken;
    temporaryPair = true;
  }
  if (!endpoint || new URL(endpoint).protocol !== "http:") throw new Error("A paired Celorga HTTP endpoint is required.");
  await call("/v1/audio-approvals/diagnostics"); // Fail before sending if the receipt API is absent.
  let probe;
  const probeDeadline = Date.now() + waitSeconds * 1000;
  while (!probe) {
    try {
      probe = await call("/v1/audio-approvals/probe", {
        runID: options.run, approvalID: options.approval, fingerprint: options.fingerprint,
        ...(options["device-id"] ? { deviceID: options["device-id"] } : {})
      });
    } catch (error) {
      if (error.code !== "audio-busy" || Date.now() >= probeDeadline) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  evidence.delivery = probe;
  console.log(`Waiting for real phone playback, delivery ${probe.deliveryID}. Evidence: ${directory}`);
  const deadline = probeDeadline;
  while (Date.now() < deadline) {
    const events = await call("/v1/audio-approvals/diagnostics");
    evidence.events = events.filter(event => event.deliveryID === probe.deliveryID && event.deviceID === probe.deviceID);
    // A recent in-flight delivery may predate the probe's short-lived pairing handshake.
    // Older receipts and invalid/future clocks are not fresh evidence for this attempt.
    const recent = evidence.events.filter(event => {
      const observed = Date.parse(event.observedAt);
      return Number.isFinite(observed) && observed >= Date.parse(evidence.startedAt) - 30_000 && observed <= Date.now() + 5_000;
    });
    if (recent.some(event => event.stage === "push-received" && event.simulated === false)
        && recent.some(event => event.stage === "playback-started" && event.simulated === false && event.headset === true)
        && recent.some(event => event.stage === "playback-completed" && event.simulated === false && event.headset === true)) {
      evidence.passed = true;
      break;
    }
    if (evidence.events.some(event => event.stage === "playback-failed" && event.simulated === false)) break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  if (!evidence.passed) {
    const stages = evidence.events.map(event => event.detail ? `${event.stage} [${event.detail}]` : event.stage).join(" → ") || "none";
    throw new Error(`No matching physical-device playback completion. Confirmed stages: ${stages}`);
  }
  console.log("PASS: the real phone completed playback for this exact push. No approval decision was made by this probe.");
} catch (error) {
  evidence.error = error.message;
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
} finally {
  if (temporaryPair) {
    try { await call("/v1/device/revoke", {}); evidence.temporaryClientRevoked = true; }
    catch { evidence.temporaryClientRevoked = false; process.exitCode = 1; }
  }
  evidence.finishedAt = new Date().toISOString();
  fs.writeFileSync(path.join(directory, "result.json"), JSON.stringify(evidence, null, 2), { mode: 0o600 });
  console.log(`Evidence: ${directory}/result.json`);
}
