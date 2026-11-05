#!/usr/bin/env node
// The search worker keeps the active corpus's index current itself: a
// `refresh` request builds the index when missing, rereads only changed
// files after that, and saves the result for the CLI and the next launch.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-refresh-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-refresh-index-"));
const env = { ...process.env, ORG2_INDEX_HOME: indexHome };
const cli = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8", env });

fs.writeFileSync(path.join(tmp, "notes.org"), "* TODO Harbor plan\nHarbor appears in the body.\n", "utf8");
fs.mkdirSync(path.join(tmp, "daily"));
fs.writeFileSync(path.join(tmp, "daily", "2026-01-02.org"), "* Morning\nNothing yet.\n", "utf8");

const worker = spawn("node", ["dist/search-service.js"], { env, stdio: ["pipe", "pipe", "inherit"] });
const lines = readline.createInterface({ input: worker.stdout })[Symbol.asyncIterator]();
async function ask(request) {
  worker.stdin.write(`${JSON.stringify(request)}\n`);
  const { value } = await lines.next();
  return JSON.parse(value);
}
const query = { rootDir: tmp, limit: 50, context: 1, sort: "best" };

try {
  // No `celorga index` has run: the refresh builds the index.
  const built = await ask({ id: "r1", rootDir: tmp, refresh: true });
  assert.equal(built.id, "r1");
  assert.equal(built.warmed, true);
  assert.equal(built.indexed.fileCount, 2);
  assert.equal(built.indexed.lineCount, 6);
  assert.equal(built.indexed.skippedFiles, 0);
  assert.equal(built.indexed.updatedFiles, 2);
  const harbor = await ask({ id: "q1", query: "harbor", ...query });
  assert.equal(harbor.payload.index.used, true);
  assert.equal(harbor.payload.results.length, 2);

  // Nothing changed: nothing is reread.
  const unchanged = await ask({ id: "r2", rootDir: tmp, refresh: true });
  assert.equal(unchanged.indexed.updatedFiles, 0);

  // One edited file and one new file are picked up by the next refresh.
  await new Promise((resolve) => setTimeout(resolve, 20));
  fs.appendFileSync(path.join(tmp, "daily", "2026-01-02.org"), "Harbor ferry at noon.\n", "utf8");
  fs.writeFileSync(path.join(tmp, "later.org"), "* Lighthouse\n", "utf8");
  const refreshed = await ask({ id: "r3", rootDir: tmp, refresh: true });
  assert.equal(refreshed.indexed.fileCount, 3);
  assert.equal(refreshed.indexed.updatedFiles, 2);
  const after = await ask({ id: "q2", query: "harbor", ...query });
  assert.equal(after.payload.results.length, 3);
  const lighthouse = await ask({ id: "q3", query: "lighthouse", ...query });
  assert.equal(lighthouse.payload.results.length, 1);

  // A removed file disappears.
  fs.rmSync(path.join(tmp, "later.org"));
  const removed = await ask({ id: "r4", rootDir: tmp, refresh: true });
  assert.equal(removed.indexed.fileCount, 2);
  assert.equal(removed.indexed.updatedFiles, 1);
  assert.deepEqual((await ask({ id: "q4", query: "lighthouse", ...query })).payload.results, []);
} finally {
  worker.stdin.end();
  await new Promise((resolve) => worker.once("exit", resolve));
}

try {
  // The worker saved its index on the way out; the CLI answers from it.
  const saved = JSON.parse(cli(
    "search", "harbor", "--dir", tmp, "--recursive", "--limit", "50", "--context", "1",
    "--index", "current", "--sort", "best", "--format", "json",
  ));
  assert.equal(saved.index.used, true);
  assert.equal(saved.results.length, 3);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.rmSync(indexHome, { recursive: true, force: true });
}
console.log("search service refresh tests passed");
