#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "org2-search-test-"));
const indexHome = fs.mkdtempSync(path.join(os.tmpdir(), "org2-search-index-home-"));
process.env.ORG2_INDEX_HOME = indexHome;
const file = path.join(tmp, "notes.org2");
fs.writeFileSync(file, `#+title: Search Fixture

* TODO Alpha plan :work:urgent:
:PROPERTIES:
:ID: alpha-1
:END:
We decided to ship the cited search slice.

** DONE Alpha archive :work:
The old alpha note is done.

* Beta note :personal:
Waiting on a beta reply.
`, "utf8");

const relevanceFile = path.join(tmp, "relevance.org2");
fs.writeFileSync(relevanceFile, `${Array.from({ length: 60 }, (_, index) => `Mercor historical mention ${index + 1}`).join("\n")}

* Mercor account notes
Mercor appears in this ordinary entry.

* TODO Follow up with Mercor after review
Mercor appears again in the task body.
`, "utf8");

const run = (...args) => execFileSync("node", ["dist/cli.js", ...args], { encoding: "utf8" });

const text = run("search", "cited", "--file", file);
assert.match(text, /notes\.org2:7 Alpha plan \[TODO :work: :urgent:\]/);
assert.match(text, /We decided to ship the cited search slice\./);

const filtered = run("search", "old", "--file", file, "--todo", "DONE", "--tag", "work", "--format", "json");
const payload = JSON.parse(filtered);
assert.equal(payload.$schema, "org2:search:v1");
assert.equal(payload.query, "old");
assert.equal(payload.results.length, 1);
assert.equal(payload.results[0].line, 10);
assert.equal(payload.results[0].heading, "Alpha archive");
assert.equal(payload.results[0].todo, "DONE");
assert.deepEqual(payload.results[0].tags, ["work"]);

const indexBuild = JSON.parse(run("index", "--dir", tmp, "--recursive", "--format", "json"));
assert.equal(indexBuild.$schema, "org2:index:v1");
assert.equal(indexBuild.kind, "search");
assert.ok(indexBuild.path.startsWith(indexHome + path.sep), `expected index under ${indexHome}, got ${indexBuild.path}`);
assert.ok(!indexBuild.path.startsWith(tmp + path.sep), `index should not be written inside corpus root: ${indexBuild.path}`);
assert.equal(fs.existsSync(path.join(tmp, ".org2", "index", "search-v1.json")), false);
assert.ok(fs.existsSync(indexBuild.path));
assert.ok(fs.existsSync(`${indexBuild.path}.v8`));
assert.ok(indexBuild.fileCount >= 1);

const indexedSearch = JSON.parse(run("search", "cited", "--dir", tmp, "--recursive", "--index", "auto", "--format", "json"));
assert.equal(indexedSearch.$schema, "org2:search:v1");
assert.equal(indexedSearch.index.used, true);
assert.equal(indexedSearch.results[0].heading, "Alpha plan");

fs.writeFileSync(`${indexBuild.path}.v8`, "corrupt binary cache", "utf8");
const fallbackSearch = JSON.parse(run("search", "cited", "--dir", tmp, "--recursive", "--index", "current", "--format", "json"));
assert.equal(fallbackSearch.index.used, true);
assert.equal(fallbackSearch.results[0].heading, "Alpha plan");

fs.appendFileSync(file, "\nInstant incremental marker.\n", "utf8");
const incrementalBuild = JSON.parse(run(
  "index", "--dir", tmp, "--recursive", "--file", file, "--incremental", "--format", "json",
));
assert.equal(incrementalBuild.incremental, true);
assert.equal(incrementalBuild.updatedFiles, 1);
const incrementalSearch = JSON.parse(run("search", "instant incremental", "--dir", tmp, "--recursive", "--index", "auto", "--format", "json"));
assert.equal(incrementalSearch.index.used, true);
assert.equal(incrementalSearch.results.length, 1);
const currentIndexSearch = JSON.parse(run("search", "instant incremental", "--dir", tmp, "--recursive", "--index", "current", "--format", "json"));
assert.equal(currentIndexSearch.index.mode, "current");
assert.equal(currentIndexSearch.index.used, true);
assert.equal(currentIndexSearch.results.length, 1);

const deletedFile = path.join(tmp, "deleted.org2");
fs.writeFileSync(deletedFile, "* Deleted index marker\n", "utf8");
run("index", "--dir", tmp, "--recursive", "--file", deletedFile, "--incremental", "--format", "json");
fs.unlinkSync(deletedFile);
const incrementalDelete = JSON.parse(run("index", "--dir", tmp, "--recursive", "--file", deletedFile, "--incremental", "--format", "json"));
assert.equal(incrementalDelete.incremental, true);
const deletedSearch = JSON.parse(run("search", "deleted index marker", "--dir", tmp, "--recursive", "--index", "auto", "--format", "json"));
assert.equal(deletedSearch.index.used, true);
assert.equal(deletedSearch.results.length, 0);

const relevanceSearch = JSON.parse(run(
  "search",
  "Mercor",
  "--dir",
  tmp,
  "--recursive",
  "--index",
  "auto",
  "--sort",
  "relevance",
  "--limit",
  "5",
  "--format",
  "json",
));
assert.equal(relevanceSearch.sort, "relevance");
assert.equal(relevanceSearch.results[0].heading, "Follow up with Mercor after review");
assert.equal(relevanceSearch.results[0].todo, "TODO");
assert.equal(relevanceSearch.results[0].line, relevanceSearch.results[0].headingLine);
assert.equal(relevanceSearch.results[2].heading, "Mercor account notes");

// `best` blends match quality with a strong recency bias: a passing mention
// today outranks an exact heading match from years ago.
const bestRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-search-best-"));
const isoDay = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const today = isoDay(new Date());
const yearsAgo = isoDay(new Date(Date.now() - 900 * 24 * 60 * 60 * 1000));
fs.writeFileSync(path.join(bestRoot, `${yearsAgo}.org2`), `* TODO Zephyrine\nOld exact heading match.\n`, "utf8");
fs.writeFileSync(path.join(bestRoot, `${today}.org2`), `* Standup\nWe mentioned zephyrine in passing today.\n`, "utf8");
fs.writeFileSync(path.join(bestRoot, "links.org2"), `* [[https://zephyrine.example][Bookmarks]]\nA hidden link target only.\n`, "utf8");
fs.utimesSync(path.join(bestRoot, "links.org2"), new Date(0), new Date(0));
for (const indexMode of ["rebuild", "never"]) {
  const bestSearch = JSON.parse(run(
    "search", "zephyrine", "--dir", bestRoot, "--recursive", "--index", indexMode, "--sort", "best", "--format", "json",
  ));
  assert.equal(bestSearch.sort, "best");
  assert.deepEqual(
    bestSearch.results.map((result) => path.basename(result.file)),
    [`${today}.org2`, `${yearsAgo}.org2`, "links.org2"],
    `best ranking with --index ${indexMode}`,
  );
}
fs.rmSync(bestRoot, { recursive: true, force: true });

fs.appendFileSync(file, "\nIndexed freshness marker.\n", "utf8");
const staleIndexSearch = JSON.parse(run("search", "freshness marker", "--dir", tmp, "--recursive", "--index", "auto", "--format", "json"));
assert.equal(staleIndexSearch.index.used, false);
assert.equal(staleIndexSearch.index.stale, true);
assert.equal(staleIndexSearch.results.length, 1);
assert.match(staleIndexSearch.results[0].snippet, /Indexed freshness marker/);

const rebuiltIndexSearch = JSON.parse(run("search", "freshness marker", "--dir", tmp, "--recursive", "--index", "rebuild", "--format", "json"));
assert.equal(rebuiltIndexSearch.index.used, true);
assert.equal(rebuiltIndexSearch.results.length, 1);

const queryAlias = run("query", "waiting", "--file", file, "--format", "json");
const aliasPayload = JSON.parse(queryAlias);
assert.equal(aliasPayload.$schema, "org2:search:v1");
assert.equal(aliasPayload.results[0].heading, "Beta note");

const meetingsDir = path.join(tmp, "meetings");
const rawDir = path.join(tmp, "raw");
fs.mkdirSync(meetingsDir);
fs.mkdirSync(rawDir);
fs.writeFileSync(path.join(rawDir, "2026-05-18.org2"), `* Raw Chris Martin note
Chris Martin mentioned an older vendor context.
`, "utf8");
fs.writeFileSync(path.join(meetingsDir, "2026-05-19.org2"), `#+title: Daily

* Meeting with Chris Martin :work:
SCHEDULED: <2026-05-19 Tue>
We talked with Chris Martin about timeline risks.

** Sibling detail
This sibling should stay inside the meeting subtree.

* Other
Chris Martin appears here but is a separate subtree.
`, "utf8");
fs.writeFileSync(path.join(meetingsDir, "undated.org2"), `* TODO Follow-up with Chris Martin :work:
<2026-05-20 Wed>
Chris Martin asked for a cited recap.

* Later unrelated
No matching text here.
`, "utf8");

const subtreeJson = run(
  "query",
  "Chris Martin",
  "--dir",
  tmp,
  "--recursive",
  "--subtree",
  "--sort",
  "date-desc",
  "--date-from",
  "2026-05-19",
  "--file-zone",
  "meetings",
  "--format",
  "json",
);
const subtreePayload = JSON.parse(subtreeJson);
assert.equal(subtreePayload.$schema, "org2:search:v1");
assert.equal(subtreePayload.mode, "subtree");
assert.equal(subtreePayload.results.length, 3);
assert.equal(subtreePayload.results[0].heading, "Follow-up with Chris Martin");
assert.equal(subtreePayload.results[0].date, "2026-05-20");
assert.deepEqual(subtreePayload.results[0].sourceRange, { startLine: 1, endLine: 4 });
assert.equal(subtreePayload.results[0].matchedLines[0].line, 1);
assert.equal(subtreePayload.results[1].heading, "Meeting with Chris Martin");
assert.equal(subtreePayload.results[1].date, "2026-05-19");
assert.deepEqual(subtreePayload.results[1].headingAncestry.map((h) => h.title), ["Meeting with Chris Martin"]);
assert.match(subtreePayload.results[1].context.lines.join("\n"), /Sibling detail/);
assert.equal(subtreePayload.results[2].heading, "Other");
assert.ok(subtreePayload.results.every((r) => r.file.includes(`${path.sep}meetings${path.sep}`)));
assert.ok(!subtreePayload.results.some((r) => r.file.includes(`${path.sep}raw${path.sep}`)));

const answerContextJson = run("query", "cited recap", "--file", path.join(meetingsDir, "undated.org2"), "--answer-context", "--format", "json");
const answerContextPayload = JSON.parse(answerContextJson);
assert.match(answerContextPayload.results[0].answerContext, /Follow-up with Chris Martin/);
