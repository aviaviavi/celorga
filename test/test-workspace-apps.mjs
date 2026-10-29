#!/usr/bin/env node
// Optional workspace apps: built-in apps stay hidden until a corpus turns them
// on, plugins can contribute sandboxed app surfaces, and enablement is portable
// corpus intent in celorga.json.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { validatePluginManifest } from "../dist/pluginRuntime.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-apps-"));
const corpus = path.join(root, "corpus");
const pluginRepository = path.join(root, "plugin-repository");
const pluginHome = path.join(root, "plugin-home");
fs.mkdirSync(corpus, { recursive: true });
fs.mkdirSync(pluginRepository, { recursive: true });

function run(command, args, options = {}) {
  const child = spawnSync(command, args, {
    cwd: options.cwd || repo,
    env: { ...process.env, ORG2_PLUGIN_HOME: pluginHome, ORG2_INDEX_HOME: path.join(root, "index") },
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (options.allowFailure !== true && child.status !== 0) throw new Error(`${command} ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  return child;
}
const cli = (args, options) => run("node", ["dist/cli.js", ...args, "--dir", corpus], options);
const json = (args) => JSON.parse(cli(args).stdout);
const git = (args) => run("git", args, { cwd: pluginRepository }).stdout.trim();
const config = () => JSON.parse(fs.readFileSync(path.join(corpus, "celorga.json"), "utf8"));

try {
  // Surface contributions are validated like every other contribution.
  const base = { $schema: "org2:plugin-manifest:v1", id: "x", name: "X", version: "1.0.0" };
  assert.throws(() => validatePluginManifest({ ...base, contributes: { surfaces: [{ id: "s", title: "S", entry: "s.mjs", capabilities: ["write-corpus"] }] } }), /never a capability/);
  assert.throws(() => validatePluginManifest({ ...base, contributes: { surfaces: [{ id: "s", entry: "s.mjs" }] } }), /title/);
  assert.throws(() => validatePluginManifest({ ...base, contributes: { surfaces: [{ id: "s", title: "S", symbol: "Not A Symbol", entry: "s.mjs" }] } }), /SF Symbol/);
  assert.throws(() => validatePluginManifest({ ...base, contributes: { surfaces: [{ id: "s", title: "S", entry: "s.mjs", extra: true }] } }), /extra/);
  const valid = validatePluginManifest({ ...base, contributes: { surfaces: [{ id: "Board", title: "Board", symbol: "square.grid.2x2", entry: "s.mjs", capabilities: ["read-corpus"] }] } });
  assert.deepEqual(valid.contributes.surfaces, [{ id: "board", title: "Board", symbol: "square.grid.2x2", entry: "s.mjs", capabilities: ["read-corpus"] }]);

  // Built-in apps are off by default; People & Companies is suggested once the
  // corpus has people or companies.
  fs.writeFileSync(path.join(corpus, "celorga.json"), `${JSON.stringify({ corpus: { name: "Example" }, agendaFiles: ["notes/*.org"] }, null, 2)}\n`);
  fs.mkdirSync(path.join(corpus, "notes"));
  let listed = json(["apps", "list"]);
  assert.equal(listed.schema, "org2:workspace-apps:v1");
  assert.deepEqual(listed.apps.map((app) => app.id), ["crm", "canvases"]);
  assert.deepEqual(listed.enabled, []);
  assert.equal(listed.apps[0].suggestion, undefined, "an empty corpus gets no suggestion");
  assert.deepEqual(listed.apps[0].surfaces.map((surface) => surface.id), ["people", "companies"]);
  for (let i = 0; i < 6; i += 1) {
    fs.writeFileSync(path.join(corpus, "notes", `person-${i}.org`), `:PROPERTIES:\n:ID: p${i}\n:ORG2_ENTITY_TYPE: ${i % 2 ? "company" : "person"}\n:END:\n#+title: Example ${i}\n`);
  }
  listed = json(["apps", "list"]);
  assert.match(listed.apps[0].suggestion.reason, /3 people, 3 companies/);
  assert.equal(json(["apps", "list", "--no-suggestions"]).apps[0].suggestion, undefined);
  fs.writeFileSync(path.join(corpus, "board.canvas"), "{}\n");
  assert.match(json(["apps", "list"]).apps[1].suggestion.reason, /canvas/);

  // Enabling previews, then writes only the apps key.
  const preview = json(["apps", "enable", "crm"]);
  assert.equal(preview.applied, false);
  assert.equal(config().apps, undefined);
  const enabled = json(["apps", "enable", "crm", "--apply"]);
  assert.equal(enabled.applied, true);
  assert.deepEqual(config(), { corpus: { name: "Example" }, agendaFiles: ["notes/*.org"], apps: { enabled: ["crm"] } });
  listed = json(["apps", "list"]);
  assert.deepEqual(listed.enabled, ["crm"]);
  assert.equal(listed.apps[0].suggestion, undefined, "enabled apps are not suggested");
  assert.equal(json(["apps", "enable", "crm", "--apply"]).changed, false);
  const stale = cli(["apps", "enable", "canvases", "--if-revision", "sha256:0", "--apply"], { allowFailure: true });
  assert.notEqual(stale.status, 0);
  json(["apps", "disable", "crm", "--apply"]);
  assert.equal(config().apps, undefined, "turning a default-off app off removes the override");
  assert.notEqual(cli(["apps", "enable", "spreadsheets"], { allowFailure: true }).status, 0);

  // A plugin surface becomes an app that is on once the plugin is installed.
  fs.writeFileSync(path.join(pluginRepository, "org2-plugin.json"), `${JSON.stringify({
    $schema: "org2:plugin-manifest:v1",
    id: "example.board",
    name: "Example board",
    version: "0.1.0",
    description: "A pipeline board.",
    contributes: { surfaces: [{ id: "board", title: "Pipeline", symbol: "square.grid.2x2", entry: "board.mjs" }] },
  }, null, 2)}\n`);
  fs.writeFileSync(path.join(pluginRepository, "board.mjs"), `let input = ""; for await (const chunk of process.stdin) input += chunk;
const invocation = JSON.parse(input);
process.stdout.write(JSON.stringify({ $schema: "org2:plugin-render-result:v1", title: "Pipeline board", html: "<h1>" + invocation.kind + ":" + invocation.contribution.id + "</h1>", css: "h1{color:teal}", sawCorpus: "corpus" in invocation }));
`);
  git(["init", "-q", "-b", "main"]);
  git(["add", "."]);
  git(["-c", "user.name=Celorga Test", "-c", "user.email=celorga@example.invalid", "commit", "-q", "-m", "Initial plugin"]);
  cli(["plugin", "add", pluginRepository, "--apply"]);
  listed = json(["apps", "list"]);
  const app = listed.apps.find((item) => item.id === "plugin:example.board");
  assert.equal(app.enabled, true);
  assert.equal(app.trusted, false);
  assert.equal(app.source, "plugin");
  assert.deepEqual(app.surfaces, [{ id: "board", title: "Pipeline", symbol: "square.grid.2x2" }]);
  const untrusted = cli(["apps", "render", "example.board:board"], { allowFailure: true });
  assert.match(untrusted.stderr, /not trusted/);
  cli(["plugin", "trust", "example.board", "--apply"]);
  const rendered = json(["apps", "render", "example.board:board"]);
  assert.equal(rendered.schema, "org2:plugin-surface-render:v1");
  assert.equal(rendered.title, "Pipeline board");
  assert.equal(rendered.html, "<h1>surface:board</h1>");
  assert.equal(rendered.css, "h1{color:teal}");
  json(["apps", "disable", "plugin:example.board", "--apply"]);
  assert.deepEqual(config().apps, { disabled: ["plugin:example.board"] });
  assert.match(cli(["apps", "render", "example.board:board"], { allowFailure: true }).stderr, /turned off/);
  const pluginList = JSON.parse(cli(["plugin", "list", "--json"]).stdout);
  assert.deepEqual(pluginList.plugins[0].contributions.surfaces, [{ id: "board", title: "Pipeline" }]);
  console.log("OK: workspace apps");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
