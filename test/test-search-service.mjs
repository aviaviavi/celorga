#!/usr/bin/env node
// The app's long-lived search worker must answer exactly like
// `celorga search --index current` and pick up a rebuilt index.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { initializeCorpusIdentity } from "../dist/corpusIdentity.js";

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

  // Filters and line shortening answer exactly like `celorga search --match`.
  const longLine = `${"x".repeat(2000)} beacon ${"y".repeat(2000)}`;
  fs.writeFileSync(path.join(tmp, "work.org"), `#+title: Work

* TODO Beacon launch
Beacon body under an open task.
* DONE Beacon retro
Beacon body under a finished task.
* Notes
Plain beacon mention. Éclair BEACON accents.
${longLine}
`, "utf8");
  await new Promise((resolve) => setTimeout(resolve, 20));
  cli("index", "--dir", tmp, "--recursive", "--format", "json");
  for (const sort of ["best", "relevance", "scan"]) {
    const all = await ask({ id: `all-${sort}`, query: "beacon", ...query, sort });
    const expectedAll = JSON.parse(cli("search", "beacon", "--dir", tmp, "--recursive", "--limit", "50", "--context", "1", "--index", "current", "--sort", sort, "--format", "json"));
    // The worker refreshes its in-memory index from the files instead of
    // rereading the rewritten index, so only its build time may differ.
    assert.deepEqual({ ...all.payload, index: undefined }, { ...expectedAll, index: undefined }, `service matches the CLI for --sort ${sort}`);
    for (const matchKind of ["heading", "todo", "text"]) {
      const served = await ask({ id: `${matchKind}-${sort}`, query: "beacon", ...query, sort, matchKind });
      const expected = JSON.parse(cli("search", "beacon", "--dir", tmp, "--recursive", "--limit", "50", "--context", "1", "--index", "current", "--sort", sort, "--match", matchKind, "--format", "json"));
      assert.deepEqual({ ...served.payload, index: undefined }, { ...expected, index: undefined }, `--match ${matchKind} --sort ${sort}`);
    }
  }
  const headings = await ask({ id: "h", query: "beacon", ...query, matchKind: "heading" });
  assert.deepEqual(headings.payload.results.map((hit) => hit.heading).sort(), ["Beacon launch", "Beacon retro"]);
  const todos = await ask({ id: "t", query: "beacon", ...query, matchKind: "todo" });
  assert.deepEqual(todos.payload.results.map((hit) => hit.line).sort((a, b) => a - b), [3, 4]);
  const text = await ask({ id: "x", query: "beacon", ...query, matchKind: "text" });
  assert.ok(text.payload.results.every((hit) => hit.line !== hit.headingLine));
  const short = await ask({ id: "s", query: "beacon", ...query, maxLineLength: 120 });
  const longHit = short.payload.results.find((hit) => hit.snippet.includes("x".repeat(10)));
  assert.ok(longHit.snippet.length <= 122 && longHit.snippet.includes("beacon"), "a long line is shortened around the match");
  assert.ok(longHit.context.lines.every((line) => line.length <= 122));

  // Several corpora at once: like `celorga workspace search`, with the
  // mounted corpus's index kept current by the worker.
  const mounted = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-service-mounted-"));
  try {
    initializeCorpusIdentity(tmp, { id: "home-notes", name: "Home Notes", kind: "personal" }, { apply: true });
    initializeCorpusIdentity(mounted, { id: "team-notes", name: "Team Notes", kind: "shared" }, { apply: true });
    fs.writeFileSync(path.join(mounted, "team.org"), "* Beacon team plan\n", "utf8");
    const mounts = [tmp, mounted];
    const federated = await ask({ id: "f1", query: "beacon", ...query, mounts });
    const expectedFederated = JSON.parse(cli("workspace", "search", "beacon", "--mount", tmp, "--mount", mounted, "--recursive", "--limit", "50", "--context", "1", "--index", "auto", "--sort", "best", "--format", "json"));
    assert.deepEqual(federated.payload.results, expectedFederated.results);
    assert.deepEqual(federated.payload.corpora.map((corpus) => corpus.id), ["home-notes", "team-notes"]);
    assert.ok(federated.payload.results.some((hit) => hit.corpus.id === "team-notes"));
    // A new file in the mounted corpus shows up without anyone running `celorga index`.
    fs.writeFileSync(path.join(mounted, "later.org"), "* Lighthousekeeper notes\n", "utf8");
    await new Promise((resolve) => setTimeout(resolve, 5_200));
    const later = await ask({ id: "f2", query: "lighthousekeeper", ...query, mounts });
    assert.deepEqual(later.payload.results.map((hit) => hit.corpus.id), ["team-notes"]);
  } finally {
    fs.rmSync(mounted, { recursive: true, force: true });
  }
} finally {
  worker.stdin.end();
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.rmSync(indexHome, { recursive: true, force: true });
}
console.log("search service tests passed");
