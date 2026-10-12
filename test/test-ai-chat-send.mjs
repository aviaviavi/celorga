import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { waitForThread, activityEventHistory } from "../dist/activityEvents.js";
import { explainActivity } from "../dist/activityState.js";
import { PassThrough } from "node:stream";
import { queueAIChatInboxMessage, AI_CHAT_SEND_SCHEMA } from "../dist/aiChatInbox.js";
import { serveMcp } from "../dist/mcpRuntime.js";

async function mcp(root, requests, options) {
  const input = new PassThrough();
  const output = new PassThrough();
  let text = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { text += chunk; });
  const serving = serveMcp(root, input, output, options);
  input.end(requests.map((request, index) => JSON.stringify({ jsonrpc: "2.0", id: index + 1, ...request })).join("\n") + "\n");
  await serving;
  return text.trim().split("\n").map((line) => JSON.parse(line));
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-single-send-"));
const singleID = "00000000-0000-4000-8000-0000000000a2";
const single = { id: singleID.toUpperCase(), runtime: "codex", destinationID: "builtin.codex", updatedAt: 0, messages: [] };
const file = path.join(root, ".org2", "openclaw-chat.json");
function save(thread = single) {
  fs.writeFileSync(file, JSON.stringify({ version: 6, threads: [thread] }));
}
function cli(...args) {
  return spawnSync(process.execPath, [path.resolve("dist/cli.js"), "thread", ...args, "--dir", root], { encoding: "utf8" });
}
try {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  save();
  const args = ["send", singleID, "--message", "Reply OK only.", "--idempotency-key", "probe"];
  const preview = cli(...args, "--json");
  assert.equal(preview.status, 0, preview.stderr);
  const planned = JSON.parse(preview.stdout);
  assert.equal(planned.deliveryStatus, "preview");
  assert.equal(planned.turnStatus, "unconfirmed");
  assert.equal(planned.message.schema, AI_CHAT_SEND_SCHEMA);
  assert.equal(planned.message.destinationID, "builtin.codex");
  assert.equal(planned.message.authorLabel, "CLI");
  assert.equal(fs.existsSync(planned.file), false);

  const applied = cli(...args, "--apply", "--json");
  assert.equal(applied.status, 0, applied.stderr);
  const queued = JSON.parse(applied.stdout);
  assert.equal(queued.deliveryStatus, "queued");
  assert.equal(queued.turnStatus, "unconfirmed");
  assert.equal(queued.message.id, planned.message.id);
  const bytes = fs.readFileSync(queued.file, "utf8");
  const wait = await waitForThread(root, singleID, "reply", { since: new Date(0), timeoutSeconds: 0.1, intervalMs: 10 });
  assert.equal(wait.outcome, "timeout", "a queued user send must not count as a reply");
  assert.equal(activityEventHistory(root, { since: new Date(0) }).some((event) => event.type === "thread.reply-received"), false);
  const activity = explainActivity(root, { thread: singleID });
  assert.equal(activity.items[0].state, "queued");

  const duplicate = cli(...args, "--apply");
  assert.equal(duplicate.status, 0, duplicate.stderr);
  assert.match(duplicate.stdout, /already queued single-agent send request/);
  assert.match(duplicate.stdout, /Turn start unconfirmed/);
  assert.equal(fs.readFileSync(queued.file, "utf8"), bytes);
  assert.throws(() => queueAIChatInboxMessage(root, singleID, "Different", {
    send: true, idempotencyKey: "probe", apply: true,
  }), /already queues a different message/);
  assert.throws(() => queueAIChatInboxMessage(root, singleID, "Reply OK only.", {
    authorLabel: "CLI", idempotencyKey: "probe", apply: true,
  }), /already queues a different message/);

  // Native UUIDs are uppercase in transcripts. A retry observes delivery,
  // never infers that delivery means a runtime turn actually started.
  fs.unlinkSync(queued.file);
  save({ ...single, messages: [{
    id: queued.message.id.toUpperCase(), role: "user", content: queued.message.content,
    targetDestinationID: "builtin.codex", provenance: { requestedByLabel: "CLI" },
  }] });
  const delivered = cli(...args, "--apply", "--json");
  assert.equal(delivered.status, 0, delivered.stderr);
  assert.equal(JSON.parse(delivered.stdout).deliveryStatus, "delivered");
  assert.equal(JSON.parse(delivered.stdout).turnStatus, "unconfirmed");
  assert.equal(fs.existsSync(queued.file), false);

  for (const [thread, pattern] of [
    [{ ...single, isSharedRoom: true }, /thread post --request-turn AGENT/],
    [{ ...single, destinationID: "" }, /no valid single-agent destination/],
    [{ ...single, runtime: "unsupported" }, /unsupported single-agent runtime/],
  ]) {
    save(thread);
    const rejected = cli(...args, "--apply");
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, pattern);
    assert.equal(fs.existsSync(queued.file), false);
  }
  save();
  for (const flag of ["--request-turn", "--agent-ref", "--source"]) {
    const rejected = cli(...args, flag, "codex", "--apply");
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /thread send accepts --author but not/);
  }
  const missing = cli("send", "missing", "--message", "OK", "--apply");
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /unknown OpenClaw thread/);
  const post = cli("post", singleID, "--message", "FYI", "--author", "CLI", "--json");
  assert.equal(post.status, 0, post.stderr);
  assert.equal(JSON.parse(post.stdout).turnStatus, "not-requested");

  // MCP clients can find a chat and start its agent's turn without the CLI.
  const [tools, listed, sent, rejected] = await mcp(root, [
    { method: "tools/list" },
    { method: "tools/call", params: { name: "celorga_thread_list", arguments: {} } },
    { method: "tools/call", params: { name: "celorga_thread_send", arguments: { threadId: singleID, message: "Over to you.", author: "Research agent", idempotencyKey: "mcp-handoff" } } },
    { method: "tools/call", params: { name: "celorga_thread_send", arguments: { threadId: "missing", message: "OK" } } },
  ]);
  const toolNames = tools.result.tools.map((tool) => tool.name);
  assert.ok(toolNames.includes("celorga_thread_send") && toolNames.includes("celorga_thread_list"));
  const listedThreads = JSON.parse(listed.result.content[0].text).threads;
  assert.deepEqual(listedThreads.map((thread) => [thread.id, thread.destinationId, thread.sharedRoom]), [[singleID, "builtin.codex", false]]);
  const mcpQueued = JSON.parse(sent.result.content[0].text);
  assert.equal(mcpQueued.applied, true);
  assert.equal(mcpQueued.message.schema, AI_CHAT_SEND_SCHEMA);
  assert.equal(mcpQueued.message.authorLabel, "Research agent");
  assert.equal(mcpQueued.turnStatus, "unconfirmed");
  assert.equal(fs.existsSync(mcpQueued.file), true);
  assert.ok(rejected.error || rejected.result?.isError, "an unknown thread must not queue a send");
  const [readOnlyTools] = await mcp(root, [{ method: "tools/list" }], { readOnly: true });
  assert.equal(readOnlyTools.result.tools.some((tool) => tool.name.startsWith("celorga_thread_")), false);
  console.log("single-agent send CLI tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
