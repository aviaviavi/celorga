import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { PassThrough } from "node:stream";
import {
  AI_CHAT_INBOX_SCHEMA,
  queueAIChatInboxMessage,
} from "../dist/aiChatInbox.js";
import { serveMcp } from "../dist/mcpRuntime.js";
import { writeShardedV2Store } from "./helpers/ai-chat-sharded-fixture.mjs";

function runNode(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { encoding: "utf8" });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-ai-chat-inbox-"));
const transcript = path.join(root, ".org2", "openclaw-chat.json");
const threadID = "00000000-0000-4000-8000-000000000001";
const storedThreadID = threadID.toUpperCase();

try {
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  fs.writeFileSync(transcript, `${JSON.stringify({
    version: 6,
    selectedThreadID: storedThreadID,
    threads: [{
      id: storedThreadID,
      title: "Background delivery",
      createdAt: 0,
      updatedAt: 0,
      sessionKey: "agent:main:background",
      messages: [],
    }],
  }, null, 2)}\n`);

  const preview = queueAIChatInboxMessage(root, threadID, "  Finished the background export.  ", {
    authorLabel: "Example Reviewer",
    authorAgentRef: "agent-profile-example-reviewer",
    source: "run:export-42",
    idempotencyKey: "export-42-complete",
    now: new Date("2026-08-19T12:00:00Z"),
  });
  assert.equal(preview.applied, false);
  assert.equal(preview.changed, true);
  assert.equal(preview.deliveryStatus, "preview");
  assert.equal(preview.turnStatus, "not-requested");
  assert.equal(fs.existsSync(preview.file), false);
  assert.equal(preview.message.schema, AI_CHAT_INBOX_SCHEMA);
  assert.equal(preview.message.threadID, threadID);
  assert.equal(preview.message.content, "Finished the background export.");

  const applied = queueAIChatInboxMessage(root, threadID, preview.message.content, {
    authorLabel: preview.message.authorLabel,
    authorAgentRef: preview.message.authorAgentRef,
    source: preview.message.source,
    idempotencyKey: "export-42-complete",
    apply: true,
    now: new Date("2026-08-19T12:00:00Z"),
  });
  assert.equal(applied.applied, true);
  assert.equal(applied.deliveryStatus, "queued");
  assert.equal(fs.existsSync(applied.file), true);
  assert.deepEqual(JSON.parse(fs.readFileSync(applied.file, "utf8")), applied.message);

  const duplicate = queueAIChatInboxMessage(root, threadID, applied.message.content, {
    authorLabel: applied.message.authorLabel,
    authorAgentRef: applied.message.authorAgentRef,
    source: applied.message.source,
    idempotencyKey: "export-42-complete",
    apply: true,
  });
  assert.equal(duplicate.applied, false);
  assert.equal(duplicate.changed, false);
  assert.equal(duplicate.deliveryStatus, "queued");
  assert.equal(duplicate.message.id, applied.message.id);
  assert.throws(
    () => queueAIChatInboxMessage(root, threadID, "Conflicting background result", {
      authorLabel: applied.message.authorLabel,
      authorAgentRef: applied.message.authorAgentRef,
      source: applied.message.source,
      idempotencyKey: "export-42-complete",
      apply: true,
    }),
    /already queues a different message/,
  );
  assert.equal(
    JSON.parse(fs.readFileSync(applied.file, "utf8")).content,
    applied.message.content,
    "an idempotency conflict must never overwrite the first complete envelope",
  );

  assert.throws(
    () => queueAIChatInboxMessage(root, threadID, "界".repeat(180_000), {
      authorLabel: "Unicode worker",
    }),
    /envelope exceeds 512000 bytes/,
  );

  assert.throws(
    () => queueAIChatInboxMessage(root, "missing", "No destination"),
    /unknown OpenClaw thread/,
  );
  assert.throws(
    () => queueAIChatInboxMessage(root, threadID, "No author"),
    /author or agent ref is required/,
  );

  const cliPreview = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"),
    "thread", "post", threadID,
    "--message", "CLI background result",
    "--author", "Codex worker",
    "--idempotency-key", "cli-background-result",
    "--dir", root,
    "--json",
  ], { encoding: "utf8" });
  assert.equal(cliPreview.status, 0, cliPreview.stderr);
  const cliResult = JSON.parse(cliPreview.stdout);
  assert.equal(cliResult.applied, false);
  assert.equal(cliResult.message.authorLabel, "Codex worker");
  assert.equal(fs.existsSync(cliResult.file), false);

  const input = new PassThrough();
  const output = new PassThrough();
  let responseText = "";
  output.setEncoding("utf8");
  output.on("data", (chunk) => { responseText += chunk; });
  const serving = serveMcp(root, input, output);
  input.end(`${JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: {
      name: "org2_thread_post",
      arguments: {
        threadId: threadID,
        message: "MCP background result",
        author: "Workflow worker",
        agentRef: "agent-profile-workflow-worker",
        idempotencyKey: "mcp-background-result",
      },
    },
  })}\n`);
  await serving;
  const mcpResponse = JSON.parse(responseText.trim());
  assert.equal(mcpResponse.id, 1);
  const queued = JSON.parse(mcpResponse.result.content[0].text);
  assert.equal(queued.applied, true);
  assert.equal(queued.message.authorAgentRef, "agent-profile-workflow-worker");
  assert.equal(fs.existsSync(queued.file), true);

  const concurrentPreview = queueAIChatInboxMessage(root, threadID, "Concurrent result A", {
    authorLabel: "Concurrent worker",
    idempotencyKey: "concurrent-result",
  });
  const commonArguments = [
    path.resolve("dist/cli.js"), "thread", "post", threadID,
    "--message",
    "--author", "Concurrent worker",
    "--idempotency-key", "concurrent-result",
    "--dir", root,
    "--apply",
    "--json",
  ];
  const concurrent = await Promise.all([
    runNode([...commonArguments.slice(0, 5), "Concurrent result A", ...commonArguments.slice(5)]),
    runNode([...commonArguments.slice(0, 5), "Concurrent result B", ...commonArguments.slice(5)]),
  ]);
  assert.deepEqual(concurrent.map((result) => result.status).sort(), [0, 1]);
  assert.ok(
    ["Concurrent result A", "Concurrent result B"].includes(
      JSON.parse(fs.readFileSync(concurrentPreview.file, "utf8")).content,
    ),
  );

} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

const shardedRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-ai-chat-inbox-sharded-"));
try {
  const shardedThreadID = "00000000-0000-4000-8000-000000000201";
  const baseMetadata = {
    id: shardedThreadID.toUpperCase(),
    title: "Sharded background delivery",
    createdAt: 0,
    updatedAt: 0,
    runtime: "codex",
    destinationID: "codex",
    sessionKey: "agent:main:sharded-background",
    messages: [],
    storedMessageCount: 0,
    storedHasUnresolvedLatestDelivery: false,
    storedLatestDeliveryNeedsAttention: false,
    isPinned: false,
    isArchived: false,
    unreadMessageCount: 0,
  };
  writeShardedV2Store(shardedRoot, {
    commitID: "post-current",
    generation: 1,
    selectedThreadID: shardedThreadID.toUpperCase(),
    legacyPayload: { version: 6, threads: [] },
    threads: [{ metadata: baseMetadata }],
  });
  const options = {
    authorLabel: "Shard worker",
    authorAgentRef: "agent-profile-shard-worker",
    source: "run:sharded-delivery",
    idempotencyKey: "sharded-delivery",
    now: new Date("2026-08-20T12:00:00Z"),
  };
  const preview = queueAIChatInboxMessage(
    shardedRoot,
    shardedThreadID.toLowerCase(),
    "Delivered through a targeted shard lookup",
    options,
  );
  assert.equal(preview.changed, true);
  const applied = queueAIChatInboxMessage(
    shardedRoot,
    shardedThreadID.toLowerCase(),
    preview.message.content,
    { ...options, apply: true },
  );
  assert.equal(applied.applied, true);

  // Once the message is in the authoritative shard, idempotent retries are
  // recognized without reading every other thread or trusting stale legacy.
  fs.rmSync(applied.file);
  writeShardedV2Store(shardedRoot, {
    commitID: "post-delivered",
    generation: 2,
    selectedThreadID: shardedThreadID.toUpperCase(),
    legacyPayload: { version: 6, threads: [] },
    threads: [{
      metadata: { ...baseMetadata, storedMessageCount: 1 },
      messages: [{
        id: preview.message.id,
        role: "assistant",
        content: preview.message.content,
        authorLabel: preview.message.authorLabel,
        authorAgentRef: preview.message.authorAgentRef,
        source: preview.message.source,
      }],
    }],
  });
  const delivered = queueAIChatInboxMessage(
    shardedRoot,
    shardedThreadID.toLowerCase(),
    preview.message.content,
    { ...options, apply: true },
  );
  assert.equal(delivered.deliveryStatus, "delivered");
  assert.equal(delivered.turnStatus, "not-requested");
  assert.equal(delivered.applied, false);
  assert.equal(delivered.changed, false);
  assert.equal(fs.existsSync(delivered.file), false);
  const deliveredCLI = spawnSync(process.execPath, [
    path.resolve("dist/cli.js"), "thread", "post", shardedThreadID,
    "--message", preview.message.content,
    "--author", options.authorLabel,
    "--agent-ref", options.authorAgentRef,
    "--source", options.source,
    "--idempotency-key", options.idempotencyKey,
    "--dir", shardedRoot, "--apply",
  ], { encoding: "utf8" });
  assert.equal(deliveredCLI.status, 0, deliveredCLI.stderr);
  assert.match(deliveredCLI.stdout, /already delivered message/);
  assert.equal(fs.existsSync(delivered.file), false, "a delivered retry must not requeue the envelope");
} finally {
  fs.rmSync(shardedRoot, { recursive: true, force: true });
}

console.log("AI chat legacy and sharded inbox tests passed");
