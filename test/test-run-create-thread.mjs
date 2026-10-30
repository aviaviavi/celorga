#!/usr/bin/env node
// A run created from an AI chat records that chat (and an explicit
// destination) so resuming it returns to the same agent instead of a default.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { linkedThreadID } from "../dist/activityState.js";
import { loadAgentRun } from "../dist/agentRun.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist", "cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-run-create-thread-"));
const celorga = (...args) => spawnSync(process.execPath, [cli, ...args, "--dir", root], { encoding: "utf8" });

try {
  const thread = "AAAAAAAA-0000-4000-8000-000000000001";
  const created = celorga("run", "create", "--goal", "Draft the report", "--owner", "Example agent",
    "--thread", thread, "--destination-ref", "dest.example", "--json");
  assert.equal(created.status, 0, created.stderr);
  const { run } = JSON.parse(created.stdout);
  assert.equal(run.destinationRef, "dest.example");
  const saved = loadAgentRun(root, run.id);
  assert.equal(saved.destinationRef, "dest.example");
  assert.equal(linkedThreadID(saved), thread.toLowerCase());
  assert.equal(saved.comments.at(-1).body, `AI destination: dest.example\nAI chat thread: ${thread.toLowerCase()}`);
  assert.equal(saved.comments.at(-1).author, "Example agent");

  const plain = JSON.parse(celorga("run", "create", "--goal", "No chat", "--json").stdout).run;
  assert.equal(loadAgentRun(root, plain.id).comments.length, 0, "a run without --thread records no chat link");

  const invalid = celorga("run", "create", "--goal", "Bad link", "--thread", "not-a-thread", "--json");
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /--thread must be an AI chat thread UUID/u);
  console.log("run create thread link tests passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
