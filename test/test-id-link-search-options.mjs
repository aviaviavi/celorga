#!/usr/bin/env node
// Org 10 `id:ID::SEARCH` links: one shared split/resolve rule across embeds,
// backlinks, the corpus compiler, agent context, export, mobile entries, and
// the language server, plus dedicated `<<target>>` search for file:: links.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  idLinkSearchSuffix,
  idLinkTargetId,
  parseIdLinkTarget,
  resolveIdLinkInText,
  resolveOrgSearchOption,
} from "../dist/linkSearch.js";
import { findBacklinksInText } from "../dist/backlinks.js";
import { compileCorpus } from "../dist/corpusCompile.js";
import { renderOrgDocumentToAppHtml } from "../dist/export.js";
import { parseOrgToCanonicalAst } from "../dist/parser.js";
import { resolveEntry } from "../dist/mobileDocument.js";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(repo, "dist", "cli.js");
const ID = "3f1c2b7a-9d4e-4c1b-8a2f-6e5d4c3b2a10";

const atlas = `#+TITLE: Atlas
* Plan
:PROPERTIES:
:ID: ${ID}
:END:
Intro.
** TODO [#B] Milestones [1/2] :work:
Window opens <<Launch Window>> here.
** Risks
:PROPERTIES:
:CUSTOM_ID: risk-list
:END:
#+NAME: budget-table
| a |
* Elsewhere
<<launch window>> outside the subtree.
`;

// Split rule.
assert.deepEqual(parseIdLinkTarget(`id:${ID}`), { id: ID });
assert.deepEqual(parseIdLinkTarget(`ID:${ID}::Launch Window`), { id: ID, search: "Launch Window" });
assert.deepEqual(parseIdLinkTarget("id:foo-123::42"), { id: "foo-123", search: "42" });
assert.equal(parseIdLinkTarget("id:::x"), null);
assert.equal(parseIdLinkTarget("file:a.org::x"), null);
assert.equal(idLinkTargetId(`id:${ID.toUpperCase()}::x`), ID);
assert.equal(idLinkSearchSuffix(`id:${ID}::*Risks`), "::*Risks");
assert.equal(idLinkSearchSuffix(`id:${ID}`), "");

// Search semantics: subtree first, then the file.
const line = (search) => resolveIdLinkInText(atlas, { id: ID, search })?.line ?? null;
assert.equal(resolveIdLinkInText(atlas, `id:${ID}`)?.line, 2);
assert.equal(line("launch window"), 8, "dedicated target inside the ID subtree wins");
assert.equal(resolveIdLinkInText(atlas, { id: ID, search: "launch window" })?.kind, "target");
assert.equal(line("*Milestones"), 7, "keyword, priority, cookie and tags are ignored");
assert.equal(line("Risks"), 9, "plain text falls back to a heading title");
assert.equal(line("#risk-list"), 11);
assert.equal(line("budget-table"), 13);
assert.equal(line("outside the"), 16, "plain text falls back to the first containing line");
assert.equal(line("3"), 3, "a number is a file line");
assert.equal(line("*Missing"), null);
assert.equal(resolveOrgSearchOption(atlas, "launch window")?.line, 8);
assert.equal(resolveOrgSearchOption(atlas, "*elsewhere")?.line, 15);
assert.equal(resolveOrgSearchOption("* A\nmention of beta here\n* B\n<<Beta>>\n", "beta")?.line, 4, "a dedicated target beats earlier text");
assert.equal(resolveOrgSearchOption("* A\nalpha text\n* DONE Alpha :x:\n", "ALPHA")?.line, 3, "a heading beats earlier text");
assert.equal(resolveOrgSearchOption("#+begin_example\n<<gamma>>\n#+end_example\ngamma\n", "gamma")?.kind, "text", "targets inside blocks are not targets");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-id-search-"));
const atlasFile = path.join(root, "atlas.org");
const sourceFile = path.join(root, "source.org");
fs.writeFileSync(atlasFile, atlas);
fs.writeFileSync(sourceFile, `* Notes
:PROPERTIES:
:ID: 11111111-2222-4333-8444-555555555555
:END:
See [[id:${ID}::Launch Window][the window]] and [[id:${ID}::7]].
#+EMBED: id:${ID}::*Risks
`);

// Embed resolution.
function embed(target) {
  const result = spawnSync(process.execPath, [cli, "embed", "resolve", "--target", target, "--file", sourceFile, "--dir", root], { encoding: "utf8" });
  return JSON.parse(result.stdout);
}
assert.equal(embed(`id:${ID}`).line, 2);
const windowEmbed = embed(`id:${ID}::Launch Window`);
assert.equal(windowEmbed.ok, true, JSON.stringify(windowEmbed));
assert.equal(windowEmbed.directive, `#+EMBED: id:${ID}::Launch Window`);
assert.equal(windowEmbed.line, 7, "embeds the heading section that contains the target");
assert.equal(windowEmbed.title, "Milestones [1/2]");
assert.equal(embed(`id:${ID.toUpperCase()}::*Risks`).line, 9);
assert.equal(embed(`id:${ID}::16`).line, 15);
const missing = embed(`id:${ID}::*Nowhere`);
assert.equal(missing.ok, false);
assert.match(missing.message, /not found/);

// Backlinks: a search option still links to the ID's node.
const backlinks = findBacklinksInText(fs.readFileSync(sourceFile, "utf8"), sourceFile, ID);
// Two bracket links plus the bare id: in the #+EMBED line.
assert.equal(backlinks.length, 3, JSON.stringify(backlinks));
const cliBacklinks = JSON.parse(spawnSync(process.execPath, [cli, "backlinks", "--id", ID, "--dir", root, "--recursive", "--format", "json"], { encoding: "utf8" }).stdout);
assert.equal((cliBacklinks.backlinks ?? cliBacklinks).length, 3, JSON.stringify(cliBacklinks));

// Corpus compile classifies the links as id links and records backlinks.
const corpus = compileCorpus([atlasFile, sourceFile], { rootDir: root });
const notes = corpus.nodes.find((node) => node.title === "Notes");
assert.deepEqual(notes.links.filter((link) => link.type === "id").map((link) => link.target), [`id:${ID}::7`, `id:${ID}::Launch Window`, `id:${ID}`]);
const plan = corpus.nodes.find((node) => node.id === ID);
assert.equal(plan.backlinks.length, 3);

// Graph audit does not report the search option as an unresolved ID.
const audit = spawnSync(process.execPath, [cli, "graph", "audit", "--dir", root, "--recursive", "--format", "json"], { encoding: "utf8" });
assert.ok(audit.stdout.trim().startsWith("{"), audit.stderr || audit.stdout);
assert.equal(audit.stdout.match(/unresolved-id-link/g), null, audit.stdout);

// App HTML keeps the full target for native routing.
const html = renderOrgDocumentToAppHtml(parseOrgToCanonicalAst(`[[id:${ID}::Launch Window][go]]\n`, { sourceRanges: true })).html;
assert.ok(html.includes(`target=${encodeURIComponent(`id:${ID}::Launch Window`)}`), html);

// Mobile entry selection picks the heading that contains the match.
assert.equal(resolveEntry(atlas, "atlas.org", `id:${ID}::launch window`).entry.line, 7);
assert.equal(resolveEntry(atlas, "atlas.org", `id:${ID}`).entry.line, 2);
assert.throws(() => resolveEntry(atlas, "atlas.org", `id:${ID}::*Nowhere`), /no longer exists/);

// Language server: definition lands on the match; hover names the search;
// rename keeps the search option.
const lspSource = `* Source\nTarget: [[id:${ID}::Launch Window][w]]\nHeading: [[id:${ID}::*Risks]]\nFile: [[file:atlas.org::launch window]]\n`;
const sourceUri = pathToFileURL(path.join(root, "lsp-source.org")).toString();
const atlasUri = pathToFileURL(atlasFile).toString();
const server = spawn(process.execPath, [path.join(repo, "dist", "lsp.js")]);
const responses = new Map();
let buffer = "";
server.stdout.on("data", (chunk) => {
  buffer += chunk.toString();
  for (;;) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const length = Number(/Content-Length: (\d+)/.exec(buffer.slice(0, headerEnd))?.[1] ?? 0);
    if (buffer.length < headerEnd + 4 + length) return;
    const message = JSON.parse(buffer.slice(headerEnd + 4, headerEnd + 4 + length));
    buffer = buffer.slice(headerEnd + 4 + length);
    if (message.id !== undefined) responses.set(message.id, message);
  }
});
const send = (message) => {
  const content = JSON.stringify({ jsonrpc: "2.0", ...message });
  server.stdin.write(`Content-Length: ${Buffer.byteLength(content)}\r\n\r\n${content}`);
};
const request = async (id, method, params) => {
  send({ id, method, params });
  const deadline = Date.now() + 5000;
  while (!responses.has(id)) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${method}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return responses.get(id).result;
};
const positionOf = (needle) => {
  const lines = lspSource.split("\n");
  const index = lines.findIndex((text) => text.includes(needle));
  return { line: index, character: lines[index].indexOf(needle) + 4 };
};
try {
  await request(1, "initialize", { processId: process.pid, rootUri: pathToFileURL(root).toString(), capabilities: {} });
  send({ method: "textDocument/didOpen", params: { textDocument: { uri: sourceUri, languageId: "org", version: 1, text: lspSource } } });
  send({ method: "textDocument/didOpen", params: { textDocument: { uri: atlasUri, languageId: "org", version: 1, text: atlas } } });
  const definition = async (id, needle) => {
    const result = await request(id, "textDocument/definition", { textDocument: { uri: sourceUri }, position: positionOf(needle) });
    const location = Array.isArray(result) ? result[0] : result;
    assert.equal(location?.uri, atlasUri, JSON.stringify(result));
    return location.range.start.line;
  };
  assert.equal(await definition(10, `id:${ID}::Launch Window`), 7);
  assert.equal(await definition(11, `id:${ID}::*Risks`), 8);
  assert.equal(await definition(12, "file:atlas.org::launch window"), 7, "file:: plain text matches the dedicated target");
  const hover = await request(20, "textDocument/hover", { textDocument: { uri: sourceUri }, position: positionOf(`id:${ID}::Launch Window`) });
  assert.match(JSON.stringify(hover), /Launch Window/);
  const references = await request(30, "textDocument/references", {
    textDocument: { uri: atlasUri },
    position: { line: 3, character: 6 },
    context: { includeDeclaration: false },
  });
  assert.equal((references ?? []).filter((ref) => ref.uri === sourceUri).length, 2, JSON.stringify(references));
  const NEW_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  const rename = await request(40, "textDocument/rename", {
    textDocument: { uri: atlasUri },
    position: { line: 3, character: 6 },
    newName: NEW_ID,
  });
  const sourceEdits = rename?.changes?.[sourceUri] ?? [];
  assert.deepEqual(sourceEdits.map((edit) => edit.newText).sort(), [`id:${NEW_ID}::*Risks`, `id:${NEW_ID}::Launch Window`]);
  await request(99, "shutdown", {});
} finally {
  server.kill();
}

console.log("✓ id: links with Org 10 search options");
