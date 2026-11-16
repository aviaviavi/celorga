#!/usr/bin/env node
// Corpus scans skip hidden folders, so a wiki kept entirely in one (such as a
// crucible project's .crucible/) looks empty from the folder above it. Celorga
// names the folder instead of silently finding nothing.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-hidden-corpus-"));
const corpus = path.join(root, "corpus");

function write(relative, content, base = corpus) {
  const file = path.join(base, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  return file;
}
function cli(args) {
  const child = spawnSync("node", ["dist/cli.js", ...args], { cwd: repo, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (child.status !== 0) throw new Error(`celorga ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  return child;
}

{
  const project = path.join(root, "project");
  write(".crucible/wiki/concepts/rate.org", "#+TITLE: Rate\n\nA note.\n", project);
  const empty = cli(["search", "Rate", "--dir", project, "--recursive", "--format", "json"]);
  assert.equal(JSON.parse(empty.stdout).results.length, 0);
  assert.match(empty.stderr, /celorga: \.crucible under .*project holds Org files that corpus scans skip, because they skip hidden folders\. Use --dir .*project\/\.crucible/);
  // Also when the project has visible notes of its own.
  write("readme.org", "#+TITLE: Readme\n", project);
  const mixed = cli(["search", "Readme", "--dir", project, "--recursive"]);
  assert.match(mixed.stderr, /\.crucible under .*project holds Org files/);
  const shown = JSON.parse(cli(["corpus", "show", "--dir", project, "--json"]).stdout);
  assert.deepEqual(shown.hiddenOrgDirectories, [path.join(project, ".crucible")]);
  // Scanning the hidden folder itself finds the notes, and the hint stays quiet.
  const inside = cli(["search", "Rate", "--dir", path.join(project, ".crucible"), "--recursive", "--format", "json"]);
  assert.equal(JSON.parse(inside.stdout).results.length > 0, true);
  assert.equal(inside.stderr, "");
  // Ordinary corpora print nothing extra.
  write("notes/plain.org", "#+TITLE: Plain\n\nRates.\n");
  assert.equal(cli(["search", "Rates", "--dir", corpus, "--recursive"]).stderr, "");
}

fs.rmSync(root, { recursive: true, force: true });
console.log("hidden corpus folder hint passed");
