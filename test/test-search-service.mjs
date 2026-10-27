#!/usr/bin/env node
// The app's long-lived search worker must answer exactly like
// `celorga search --index current` and pick up a rebuilt index.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-service-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-service-index-"));
const env = { ...process.env, ORG2_INDEX_HOME: indexHome };
fs.writeFileSync(path.join(tmp, "notes.org"), `#+title: Fixture

* TODO Harbor plan :work:
Harbor appears in the body.

* Lighthouse notes
Nothing about the other word here.
`, "utf8");

const cli = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8", env });
cli("index", "--dir", tmp, "--recursive", "--format", "json");

const worker = spawn("node", ["dist/search-service.js"], { env, stdio: ["pipe", "pipe", "inherit"] });
const lines = readline.createInterface({ input: worker.stdout })[Symbol.asyncIterator]();
async function ask(request) {
  worker.stdin.write(`${JSON.stringify(request)}\n`);
  const { value } = await lines.next();
  return JSON.parse(value);
}

try {
  const warm = await ask({ id: "warm", rootDir: tmp });
  assert.deepEqual(warm, { id: "warm", warmed: true });

  const query = { rootDir: tmp, limit: 50, context: 1, sort: "best" };
  const harbor = await ask({ id: "q1", query: "harbor", ...query });
  assert.equal(harbor.id, "q1");
  const expected = JSON.parse(cli(
    "search", "harbor", "--dir", tmp, "--recursive", "--limit", "50", "--context", "1",
    "--index", "current", "--sort", "best", "--format", "json",
  ));
  assert.deepEqual(harbor.payload, expected);
  assert.equal(harbor.payload.results.length, 2);

  const none = await ask({ id: "q2", query: "zebra", ...query });
  assert.deepEqual(none.payload.results, []);

  // A rebuilt index replaces the cached one without restarting the worker.
  fs.appendFileSync(path.join(tmp, "notes.org"), "\n* Zebra crossing\n", "utf8");
  await new Promise((resolve) => setTimeout(resolve, 20));
  cli("index", "--dir", tmp, "--recursive", "--format", "json");
  const zebra = await ask({ id: "q3", query: "zebra", ...query });
  assert.equal(zebra.payload.results.length, 1);
  assert.equal(zebra.payload.results[0].heading, "Zebra crossing");

  const missing = await ask({ id: "q4", query: "x" });
  assert.equal(missing.id, "q4");
  assert.match(missing.error, /rootDir/);
} finally {
  worker.stdin.end();
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.rmSync(indexHome, { recursive: true, force: true });
}
console.log("search service tests passed");
