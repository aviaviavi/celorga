#!/usr/bin/env node
// `celorga files` and the search worker's file search: what gets indexed,
// matching and ranking, grouping of repeat downloads and copies, folder
// configuration, and live updates while the worker runs.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "celorga-file-search-")));
const home = path.join(tmp, "home");
const filesHome = path.join(tmp, "files-home");
const env = { ...process.env, HOME: home, ORG2_FILES_HOME: filesHome, CELORGA_FILES_HOME: filesHome };
const day = 86_400_000;
const now = Date.now();

function write(relative, content = "x", ageDays = 1) {
  const file = path.join(home, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  const time = new Date(now - ageDays * day);
  fs.utimesSync(file, time, time);
  return file;
}

// Repeat downloads of one report, plus the same report filed in Documents.
write("Downloads/Quarterly Report.pdf", "report v1", 40);
write("Downloads/Quarterly Report (1).pdf", "report v1", 30);
write("Downloads/Quarterly Report (2).pdf", "report v2", 2);
write("Documents/Quarterly Report.pdf", "report v1", 20);
// Real names that only look like Safari's "-2" copies.
write("Documents/Invoice-12.pdf", "a", 5);
write("Documents/Invoice-13.pdf", "b", 5);
write("Documents/SOC 2 Report.pdf", "soc", 3);
write("Documents/rsocket.txt", "r", 1);
write("Desktop/Harbor Budget.xlsx", "budget", 1);
write("Desktop/Deck.key/Index.zip", "zip", 1);
// Source repositories: indexed, ranked lower, README.md never grouped.
write("dev/alpha/.git/HEAD", "ref", 1);
write("dev/alpha/README.md", "alpha", 1);
write("dev/alpha/harbor_budget.ts", "code", 1);
write("dev/beta/.git/HEAD", "ref", 1);
write("dev/beta/README.md", "beta", 1);
// Skipped: dependencies, hidden folders, ~/Library outside cloud storage.
write("dev/alpha/node_modules/harbor/index.js", "dep", 1);
write(".secret/harbor.txt", "hidden", 1);
write("Library/Caches/harbor-cache.db", "cache", 1);
// Included: cloud storage under ~/Library.
write("Library/CloudStorage/Dropbox/Shared/Harbor Contract.pdf", "contract", 4);

const cli = (...args) => execFileSync("node", ["dist/cli.js", "files", ...args], { cwd: process.cwd(), encoding: "utf8", env });
const search = (...args) => JSON.parse(cli("search", ...args, "--json"));
const names = (payload) => payload.results.map((hit) => hit.name);

try {
  // Help and default config.
  assert.match(cli("--help"), /celorga files: find files on this Mac/);
  const status = JSON.parse(cli("status", "--json"));
  assert.equal(status.builtAt, null);
  assert.deepEqual(status.config.roots, ["~", "~/Library/Mobile Documents/com~apple~CloudDocs", "~/Library/CloudStorage"]);

  // The first search builds and saves the index.
  const harbor = search("harbor");
  assert.equal(harbor.schema, "org2:file-search-result:v1");
  assert.ok(fs.existsSync(path.join(filesHome, "index-v1.json")), "index is saved");
  assert.ok(harbor.index.builtAt, "index reports when it was built");
  const harborNames = names(harbor);
  assert.ok(harborNames.includes("Harbor Budget.xlsx"));
  assert.ok(harborNames.includes("Harbor Contract.pdf"), "cloud storage under ~/Library is searched");
  assert.ok(!harborNames.includes("harbor-cache.db"), "the rest of ~/Library is skipped");
  assert.ok(!harborNames.includes("harbor.txt"), "hidden folders are skipped");
  assert.ok(!harbor.results.some((hit) => hit.path.includes("node_modules")), "node_modules is skipped");
  assert.ok(harborNames.indexOf("Harbor Budget.xlsx") < harborNames.indexOf("harbor_budget.ts"), "documents outrank code in a repository");

  // Folder-shaped documents are one result.
  const deck = search("deck");
  assert.deepEqual(names(deck), ["Deck.key"]);
  assert.equal(deck.results[0].kind, "presentation");
  assert.equal(search("index zip").results.length, 0, "package contents are not indexed");

  // Repeat downloads and filed copies come back as one family, newest first.
  const report = search("quarterly report");
  assert.equal(report.results.length, 1);
  const family = report.results[0];
  assert.equal(family.name, "Quarterly Report (2).pdf");
  assert.equal(family.copyCount, 3);
  assert.deepEqual(family.copies.map((copy) => path.relative(home, copy.path)), [
    "Documents/Quarterly Report.pdf",
    "Downloads/Quarterly Report (1).pdf",
    "Downloads/Quarterly Report.pdf",
  ]);
  // Same size as the newest file is checked byte for byte.
  assert.deepEqual(family.copies.map((copy) => copy.identical), [false, false, false]);
  assert.equal(search("quarterly report", "--no-group").results.length, 4);

  // "Invoice-12" and "Invoice-13" are separate documents.
  assert.deepEqual(names(search("invoice")).sort(), ["Invoice-12.pdf", "Invoice-13.pdf"]);
  const indexMode = fs.statSync(path.join(filesHome, "index-v1.json")).mode & 0o777;
  assert.equal(indexMode, 0o600, "the index of file names is private");

  // README.md in two repositories stays two results.
  assert.equal(search("readme").results.length, 2);

  // Word starts and joined words match; the middle of a short word does not.
  assert.deepEqual(names(search("soc2")), ["SOC 2 Report.pdf"]);
  assert.deepEqual(names(search("soc")), ["SOC 2 Report.pdf"]);
  // Folder words narrow results.
  assert.deepEqual(names(search("desktop harbor")), ["Harbor Budget.xlsx"]);

  // Kind and extension filters, as flags or in the query.
  assert.deepEqual(names(search("harbor", "--kind", "sheet")), ["Harbor Budget.xlsx"]);
  assert.deepEqual(names(search("harbor kind:pdf")), ["Harbor Contract.pdf"]);
  assert.deepEqual(names(search("harbor .xlsx")), ["Harbor Budget.xlsx"]);

  // Text output names the newest file and counts the older copies.
  assert.match(cli("search", "quarterly"), /Quarterly Report \(2\)\.pdf .*\+3 older copies/);

  // Config previews until --apply; a new folder set rebuilds the index.
  const preview = JSON.parse(cli("config", "--remove-root", "~", "--add-root", path.join(home, "Desktop"), "--json"));
  assert.equal(preview.apply, false);
  assert.equal(preview.changed, true);
  assert.ok(!fs.existsSync(path.join(filesHome, "config.json")), "preview writes nothing");
  JSON.parse(cli("config", "--remove-root", "~", "--add-root", path.join(home, "Desktop"), "--exclude", "Deck.key", "--apply", "--json"));
  const saved = JSON.parse(fs.readFileSync(path.join(filesHome, "config.json"), "utf8"));
  assert.deepEqual(saved.roots, ["~/Library/Mobile Documents/com~apple~CloudDocs", "~/Library/CloudStorage", "~/Desktop"]);
  assert.deepEqual(saved.exclude, ["Deck.key"]);
  assert.deepEqual(names(search("harbor")).sort(), ["Harbor Budget.xlsx", "Harbor Contract.pdf"]);
  assert.equal(search("deck").results.length, 0, "an excluded name is skipped");
  cli("config", "--reset", "--apply");
  assert.ok(names(search("quarterly")).length > 0, "reset restores the default folders");

  // The app's worker answers file searches and keeps the index current.
  const worker = spawn("node", ["dist/search-service.js"], { env, stdio: ["pipe", "pipe", "inherit"] });
  const lines = readline.createInterface({ input: worker.stdout })[Symbol.asyncIterator]();
  const ask = async (request) => {
    worker.stdin.write(`${JSON.stringify(request)}\n`);
    const { value } = await lines.next();
    return JSON.parse(value);
  };
  const until = async (predicate, label) => {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const response = await ask({ id: "poll", files: { query: "lighthouse" } });
      if (predicate(response)) return response;
      if (Date.now() > deadline) assert.fail(`timed out waiting for ${label}: ${JSON.stringify(response)}`);
      await new Promise((resolve) => setTimeout(resolve, 150));
    }
  };
  try {
    const warm = await ask({ id: "warm", files: {} });
    assert.equal(warm.id, "warm");
    assert.deepEqual(warm.files.results, []);
    const quarterly = await ask({ id: "q1", files: { query: "quarterly report", limit: 10 } });
    assert.equal(quarterly.id, "q1");
    assert.equal(quarterly.files.results[0].copyCount, 3);

    const created = write("Documents/Lighthouse Plan.pdf", "new", 0);
    const found = await until((response) => response.files.results.length === 1, "a new file");
    assert.equal(found.files.results[0].path, created);
    fs.rmSync(created);
    await until((response) => response.files.results.length === 0, "a deleted file");

    // A new folder full of files is walked when it appears.
    fs.mkdirSync(path.join(home, "Documents", "Lighthouse Project", "drafts"), { recursive: true });
    fs.writeFileSync(path.join(home, "Documents", "Lighthouse Project", "drafts", "outline.txt"), "x");
    const folder = await until((response) => response.files.results.some((hit) => hit.name === "Lighthouse Project"), "a new folder");
    assert.equal(folder.files.results.find((hit) => hit.name === "Lighthouse Project").kind, "folder");
    const outline = await ask({ id: "q2", files: { query: "lighthouse outline" } });
    assert.deepEqual(outline.files.results.map((hit) => hit.name), ["outline.txt"]);

    // A file that was indexed before the worker started disappears when deleted.
    assert.deepEqual((await ask({ id: "q4", files: { query: "invoice 13" } })).files.results.map((hit) => hit.name), ["Invoice-13.pdf"]);
    fs.rmSync(path.join(home, "Documents", "Invoice-13.pdf"));
    const deadline = Date.now() + 10_000;
    let invoices;
    do {
      await new Promise((resolve) => setTimeout(resolve, 150));
      invoices = (await ask({ id: "q5", files: { query: "invoice" } })).files.results.map((hit) => hit.name);
    } while (invoices.includes("Invoice-13.pdf") && Date.now() < deadline);
    assert.deepEqual(invoices, ["Invoice-12.pdf"]);

    const bad = await ask({ id: "q3", files: { query: "x", kinds: ["nonsense"] } });
    assert.equal(bad.id, "q3");
    assert.ok(Array.isArray(bad.files.results), "unknown kinds are ignored");
  } finally {
    worker.stdin.end();
    worker.kill();
  }

  // Without a saved index, the worker builds one in the background and
  // answers from what it has so far.
  fs.rmSync(path.join(filesHome, "index-v1.json"));
  const fresh = spawn("node", ["dist/search-service.js"], { env, stdio: ["pipe", "pipe", "inherit"] });
  const freshLines = readline.createInterface({ input: fresh.stdout })[Symbol.asyncIterator]();
  try {
    fresh.stdin.write(`${JSON.stringify({ id: "w", files: {} })}\n`);
    const first = JSON.parse((await freshLines.next()).value);
    assert.equal(first.files.index.building, true);
    const deadline = Date.now() + 10_000;
    let response;
    do {
      await new Promise((resolve) => setTimeout(resolve, 100));
      fresh.stdin.write(`${JSON.stringify({ id: "f", files: { query: "harbor budget" } })}\n`);
      response = JSON.parse((await freshLines.next()).value);
    } while (response.files.index.building && Date.now() < deadline);
    assert.equal(response.files.index.building, false);
    assert.equal(response.files.results[0].name, "Harbor Budget.xlsx");
    assert.ok(fs.existsSync(path.join(filesHome, "index-v1.json")), "the worker saves the index it built");
  } finally {
    fresh.stdin.end();
    fresh.kill();
  }

  console.log("file search tests passed");
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
