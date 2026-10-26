import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { handleMcpMessage } from "../dist/mcpRuntime.js";

const cli = path.resolve("dist/cli.js");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-secret-request-"));
const corpus = path.join(tmp, "corpus");
const tools = path.join(tmp, "tools");
const argsLog = path.join(tmp, "gpg-args.jsonl");
const fakeGpg = path.join(tools, "gpg");
const fakeGpgConf = path.join(tools, "gpgconf");
const firstValue = "sk-synthetic-EXAMPLE-value-0001";
const rotatedValue = "sk-synthetic-EXAMPLE-value-0002";

fs.mkdirSync(path.join(corpus, ".org2"), { recursive: true });
fs.mkdirSync(path.join(corpus, "public-keys"), { recursive: true });
fs.mkdirSync(tools, { recursive: true });
fs.writeFileSync(path.join(corpus, "public-keys", "builder.asc"), "synthetic public key for tests\n");
fs.writeFileSync(path.join(corpus, "celorga.json"), `${JSON.stringify({
  secrets: {
    file: "secrets.org",
    agents: { "agent-profile-example-builder": { recipientFiles: ["public-keys/builder.asc"] } },
  },
}, null, 2)}\n`);
fs.writeFileSync(path.join(corpus, ".org2", "openclaw-chat.json"), `${JSON.stringify({
  version: 6,
  threads: [{ id: "00000000-0000-4000-8000-0000000000AA", title: "Example chat", createdAt: 0, updatedAt: 0, messages: [] }],
}, null, 2)}\n`);

// Deterministic stand-in for gpg: XOR "encryption" inside PGP armor, with every
// argument logged so the test can prove values never travel through argv.
fs.writeFileSync(fakeGpg, `#!/usr/bin/env node
import fs from "node:fs";
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(argsLog)}, JSON.stringify(args) + "\\n");
const input = fs.readFileSync(0);
if (args.includes("--decrypt")) {
  const hex = input.toString("utf8").split("\\n").filter((line) => /^[0-9a-f]+$/.test(line)).join("");
  process.stdout.write(Buffer.from(hex, "hex").map((byte) => byte ^ 0x5a));
} else {
  const hex = Buffer.from(input.map((byte) => byte ^ 0x5a)).toString("hex");
  process.stdout.write("-----BEGIN PGP MESSAGE-----\\n\\n" + hex.match(/.{1,64}/g).join("\\n") + "\\n-----END PGP MESSAGE-----\\n");
}
`);
fs.chmodSync(fakeGpg, 0o755);
fs.writeFileSync(fakeGpgConf, `#!/bin/sh
printf '%s\\n' 'default-key:0:0:use NAME as default secret key:1:1:NAME:::"self-example-key'
`);
fs.chmodSync(fakeGpgConf, 0o755);

function run(args, input) {
  const result = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", input: input ?? "" });
  for (const value of [firstValue, rotatedValue]) {
    assert.equal(result.stdout.includes(value), false, `stdout leaked a secret for ${args.join(" ")}`);
    assert.equal(result.stderr.includes(value), false, `stderr leaked a secret for ${args.join(" ")}`);
  }
  return result;
}
function runJSON(args, input) {
  const result = run([...args, "--dir", corpus, "--json"], input);
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
function filesUnder(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? filesUnder(full) : [full];
  });
}
function assertNoPlaintextOnDisk() {
  for (const file of [...filesUnder(corpus), argsLog]) {
    const text = fs.readFileSync(file, "utf8");
    assert.equal(text.includes(firstValue) || text.includes(rotatedValue), false, `plaintext secret written to ${file}`);
  }
}

try {
  // Preview, apply, idempotent replay, conflicting replay.
  const requestArgs = ["secret", "request", "EXAMPLE_API_TOKEN", "--reason", "Call the example API for the weekly report",
    "--author", "Example Builder", "--agent-ref", "agent-profile-example-builder",
    "--thread", "00000000-0000-4000-8000-0000000000aa", "--idempotency-key", "weekly-report-token"];
  const preview = runJSON(requestArgs);
  assert.equal(preview.status, "preview");
  assert.equal(preview.applied, false);
  assert.equal(fs.existsSync(preview.file), false);
  assert.equal(preview.request.schema, "org2:secret-request:v1");
  assert.equal(preview.request.threadID, "00000000-0000-4000-8000-0000000000aa");
  assert.deepEqual(preview.request.destination, { file: "secrets.org" });
  assert.equal(preview.request.recipients.defaultKey, true);
  assert.deepEqual(preview.request.recipients.entries, [{ kind: "file", value: "public-keys/builder.asc", source: "agent" }]);

  const queued = runJSON([...requestArgs, "--apply"]);
  assert.equal(queued.applied, true);
  assert.equal(queued.status, "pending");
  assert.equal(queued.request.id, preview.request.id);
  assert.ok(queued.file.includes(path.join(".org2", "ai-chat-inbox", "secret-requests")));
  assert.equal(fs.statSync(queued.file).mode & 0o777, 0o600);
  const replay = runJSON([...requestArgs, "--apply"]);
  assert.equal(replay.applied, false);
  assert.equal(replay.status, "pending");
  const conflict = run([...requestArgs.map((arg) => (arg.startsWith("Call the") ? "A different reason" : arg)), "--apply", "--dir", corpus]);
  assert.notEqual(conflict.status, 0);
  assert.match(conflict.stderr, /already queues a different request/);
  const id = queued.request.id;

  const missingAuthor = run(["secret", "request", "EXAMPLE_API_TOKEN", "--reason", "x", "--dir", corpus]);
  assert.match(missingAuthor.stderr, /--author LABEL or --agent-ref REF/);
  const badName = run(["secret", "request", "bad-name", "--reason", "x", "--author", "A", "--dir", corpus]);
  assert.match(badName.stderr, /secret NAME must start/);
  const outside = run(["secret", "request", "OTHER", "--reason", "x", "--author", "A", "--recipient-file", "../escape.asc", "--dir", corpus]);
  assert.match(outside.stderr, /inside the active corpus/);

  assert.equal(runJSON(["secret", "status", id]).status, "pending");
  const pendingList = runJSON(["secret", "list"]);
  assert.deepEqual(pendingList.secrets, []);
  assert.equal(pendingList.pendingRequests[0].id, id);

  // --wait times out while pending.
  const waited = run([...requestArgs, "--apply", "--wait", "0.3", "--dir", corpus]);
  assert.equal(waited.status, 124);

  // Without the default key, the requesting agent's configured key is the only recipient.
  const agentOnly = run(["secret", "fulfill", id, "--value-stdin", "--apply", "--no-default-recipient-self", "--gpg-program", fakeGpg, "--dir", corpus], firstValue);
  assert.equal(agentOnly.status, 0, agentOnly.stderr);
  const firstArgs = fs.readFileSync(argsLog, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(firstArgs[0].includes("--recipient-file"));
  assert.equal(firstArgs[0].includes("self-example-key"), false);
  assert.equal(runJSON(["secret", "status", id]).status, "fulfilled");

  // A request with no configured recipients at all, and no default key, fails closed.
  const bareID = runJSON(["secret", "request", "BARE_TOKEN", "--reason", "Test fail-closed", "--author", "Example Builder", "--apply"]).request.id;
  const bare = run(["secret", "fulfill", bareID, "--value-stdin", "--apply", "--no-default-recipient-self", "--gpg-program", fakeGpg, "--dir", corpus], firstValue);
  assert.notEqual(bare.status, 0);
  assert.match(bare.stderr, /no encryption recipient/);
  assert.equal(runJSON(["secret", "status", bareID]).status, "pending");

  let secretsText = fs.readFileSync(path.join(corpus, "secrets.org"), "utf8");
  assert.match(secretsText, /^\* EXAMPLE_API_TOKEN :secret:crypt:$/m);
  assert.match(secretsText, /^:SECRET_NAME: EXAMPLE_API_TOKEN$/m);
  assert.match(secretsText, /^:CRYPT_RECIPIENT_FILES: public-keys\/builder\.asc$/m);
  assert.match(secretsText, /-----BEGIN PGP MESSAGE-----/);
  const headingID = /^:ID: (\S+)$/m.exec(secretsText)[1];
  assertNoPlaintextOnDisk();

  // exec injects the value into the child environment only.
  const hashFile = path.join(tmp, "child-hash.txt");
  const child = run(["secret", "exec", "EXAMPLE_API_TOKEN", "--env", "EXAMPLE_TOKEN", "--gpg-program", fakeGpg, "--dir", corpus, "--",
    process.execPath, "-e", `require("fs").writeFileSync(${JSON.stringify(hashFile)}, require("crypto").createHash("sha256").update(process.env.EXAMPLE_TOKEN || "").digest("hex")); process.exit(7)`]);
  assert.equal(child.status, 7, child.stderr);
  assert.equal(fs.readFileSync(hashFile, "utf8"), crypto.createHash("sha256").update(firstValue).digest("hex"));
  const missing = run(["secret", "exec", "UNKNOWN_TOKEN", "--gpg-program", fakeGpg, "--dir", corpus, "--", "true"]);
  assert.match(missing.stderr, /no secret named UNKNOWN_TOKEN/);

  // Rotation keeps one heading and its stable ID; the default key is used when enabled.
  const rotateID = runJSON(["secret", "request", "EXAMPLE_API_TOKEN", "--reason", "Rotate the example token", "--author", "Example Builder", "--apply"]).request.id;
  const fulfilled = runJSON(["secret", "fulfill", rotateID, "--value-stdin", "--apply", "--gpg-program", fakeGpg], `${rotatedValue}\n`);
  assert.equal(fulfilled.status, "fulfilled");
  assert.equal(fulfilled.rotated, true);
  assert.equal(fulfilled.headingID, headingID);
  assert.equal(fulfilled.recipients.defaultKey, "self-example-key");
  secretsText = fs.readFileSync(path.join(corpus, "secrets.org"), "utf8");
  assert.equal(secretsText.match(/^\* EXAMPLE_API_TOKEN /gm).length, 1);
  assert.equal(secretsText.includes(":CRYPT_RECIPIENT_FILES:"), false);
  const again = run(["secret", "fulfill", rotateID, "--value-stdin", "--apply", "--gpg-program", fakeGpg, "--dir", corpus], rotatedValue);
  assert.match(again.stderr, /already fulfilled/);
  assertNoPlaintextOnDisk();

  const listing = runJSON(["secret", "list"]);
  assert.deepEqual(listing.secrets.map((entry) => [entry.name, entry.id, entry.encrypted]), [["EXAMPLE_API_TOKEN", headingID, true]]);
  assert.deepEqual(listing.pendingRequests.map((request) => request.name), ["BARE_TOKEN"]);

  // Decline records state; a waiting requester sees exit 2.
  const declinePreview = runJSON(["secret", "decline", bareID]);
  assert.equal(declinePreview.status, "preview");
  assert.equal(runJSON(["secret", "decline", bareID, "--note", "Not now", "--apply"]).status, "declined");
  const status = runJSON(["secret", "status", bareID]);
  assert.equal(status.status, "declined");
  assert.equal(status.note, "Not now");
  const declinedWait = run(["secret", "request", "WAIT_TOKEN", "--reason", "Wait test", "--author", "Example Builder", "--idempotency-key", "w", "--apply", "--dir", corpus]);
  assert.equal(declinedWait.status, 0);
  const waitID = /queued secret request (\S+)/.exec(declinedWait.stdout)[1];
  runJSON(["secret", "decline", waitID, "--apply"]);
  assert.equal(run(["secret", "request", "WAIT_TOKEN", "--reason", "Wait test", "--author", "Example Builder", "--idempotency-key", "w", "--apply", "--wait", "1", "--dir", corpus]).status, 2);

  // MCP exposes request and status on the write-capable endpoint only.
  const listed = await handleMcpMessage(corpus, { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
  const names = listed.result.tools.map((tool) => tool.name);
  assert.ok(names.includes("celorga_secret_request") && names.includes("celorga_secret_status"));
  const readOnly = await handleMcpMessage(corpus, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }, { readOnly: true });
  assert.equal(readOnly.result.tools.some((tool) => tool.name.startsWith("celorga_secret")), false);
  const mcpQueued = await handleMcpMessage(corpus, { jsonrpc: "2.0", id: 3, method: "tools/call", params: {
    name: "celorga_secret_request",
    arguments: { name: "MCP_TOKEN", reason: "MCP test", author: "Example Builder", idempotencyKey: "mcp-1" },
  } });
  const mcpRequest = JSON.parse(mcpQueued.result.content[0].text);
  assert.equal(mcpRequest.status, "pending");
  const mcpStatus = await handleMcpMessage(corpus, { jsonrpc: "2.0", id: 4, method: "tools/call", params: {
    name: "celorga_secret_status", arguments: { requestId: mcpRequest.request.id },
  } });
  assert.equal(JSON.parse(mcpStatus.result.content[0].text).status, "pending");

  // No argument passed to gpg ever carried a value.
  for (const line of fs.readFileSync(argsLog, "utf8").trim().split("\n")) {
    const args = JSON.parse(line);
    assert.equal(args.some((arg) => arg.includes("synthetic-EXAMPLE")), false);
  }
  assertNoPlaintextOnDisk();
  console.log("secret request tests passed");
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
