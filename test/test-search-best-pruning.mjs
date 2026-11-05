#!/usr/bin/env node
// `best` search visits files from the highest possible score down and stops
// once no remaining file can beat the current top results. It must return
// exactly the first results of the complete ranking, and must actually skip
// files that cannot make the cut.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildSearchIndex, searchIndexedCorpus } from "../dist/searchIndex.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-search-best-pruning-"));

function options(query, overrides = {}) {
  return {
    query,
    context: 1,
    limit: 10,
    todoFilters: new Set(),
    tagFilters: new Set(),
    fileZoneFilters: [],
    headingNeedle: "",
    sort: "best",
    dateFrom: "",
    dateTo: "",
    subtree: false,
    answerContext: false,
    ...overrides,
  };
}

function isoDay(daysAgo) {
  const date = new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000);
  return date.toISOString().slice(0, 10);
}

try {
  const files = [];
  // Daily notes spanning two years, so recency separates them sharply.
  for (let day = 0; day < 240; day += 3) {
    const file = path.join(tmp, "daily", `${isoDay(day)}.org`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, [
      `#+title: ${isoDay(day)}`,
      "Harbor mention before any heading.",
      `* Daily notes ${day}`,
      ...Array.from({ length: 20 }, (_, line) => `Harbor body line ${line}.`),
      day % 9 === 0 ? "* TODO Harbor follow-up" : "* DONE Harbor wrap-up",
      "More harbor text.",
      "* Unrelated heading",
      "Nothing to see.",
    ].join("\n"), "utf8");
    files.push(file);
  }
  // Undated notes ranked by modification time, some with dated subtrees,
  // exact heading matches, and headings whose visible text hides a link.
  for (let index = 0; index < 60; index += 1) {
    const file = path.join(tmp, "notes", `note-${String(index).padStart(3, "0")}.org`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, [
      "Preamble harbor.",
      // An exact heading match on an open TODO in an old note still beats
      // body mentions from recent days.
      index % 5 === 0 ? "* TODO harbor" : `* Topic ${index}`,
      index % 7 === 0 ? `SCHEDULED: <${isoDay(index * 11)} Mon>` : "",
      "Body harbor line.",
      index % 4 === 0 ? "* [[https://example.com/harbor][Port]] review" : "* Port review",
      "Port body.",
      index % 6 === 0 ? "* TODO Port audit" : "* Audit",
      "harbor port harbor",
    ].join("\n"), "utf8");
    const mtime = new Date(Date.now() - (200 + index * 5) * 24 * 60 * 60 * 1000);
    fs.utimesSync(file, mtime, mtime);
    files.push(file);
  }

  // Recently modified undated notes rank on their modification time, and
  // open TODOs on dated entries rank on the TODO bonus.
  for (let index = 0; index < 40; index += 1) {
    const fresh = path.join(tmp, "fresh", `fresh-${String(index).padStart(3, "0")}.org`);
    fs.mkdirSync(path.dirname(fresh), { recursive: true });
    fs.writeFileSync(fresh, "Harbor fresh mention.\nAnother harbor fresh mention.\n", "utf8");
    const mtime = new Date(Date.now() - index * 4 * 24 * 60 * 60 * 1000);
    fs.utimesSync(fresh, mtime, mtime);
    files.push(fresh);
    const todo = path.join(tmp, "todo", `todo-${String(index).padStart(3, "0")}.org`);
    fs.mkdirSync(path.dirname(todo), { recursive: true });
    fs.writeFileSync(todo, `* TODO Harbor watch ${index}\nSCHEDULED: <${isoDay(index * 5)} Mon>\nWatch the harbor.\n`, "utf8");
    files.push(todo);
  }

  const index = buildSearchIndex({ rootDir: tmp, files, recursive: true, includeArchives: false }).index;
  const reference = (query, overrides) =>
    searchIndexedCorpus(index, options(query, { ...overrides, limit: 1_000_000 }));

  for (const query of ["harbor", "Harbor", "port", "review", "harbor port", "audit", "e", "zzz-absent"]) {
    for (const matchKind of [undefined, "heading", "todo", "text"]) {
      const complete = reference(query, { matchKind });
      for (const limit of [1, 3, 10, 25, 50, 65, 80, 100, 120, 160, 200, 250, 300, 400]) {
        assert.deepEqual(
          searchIndexedCorpus(index, options(query, { limit, matchKind })),
          complete.slice(0, limit),
          `best ${JSON.stringify(query)} limit ${limit} match ${matchKind ?? "all"}`,
        );
      }
    }
  }

  // A common word only reads the files that can still make the top results.
  let visited = 0;
  const pruned = searchIndexedCorpus(index, options("harbor", { limit: 3 }), {
    mayContain: () => {
      visited += 1;
      return true;
    },
  });
  assert.equal(pruned.length, 3);
  assert.ok(visited < index.files.length / 2, `pruning should skip most files, visited ${visited} of ${index.files.length}`);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log("search best pruning tests passed");
