import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { parseViewBridgeIntent, renderInteractiveViewOrg, refreshInteractiveView } from "../dist/interactiveViews.js";
import { renderAppHTML } from "../dist/appHtmlRenderer.js";

const cliPath = path.resolve("dist/cli.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-interactive-views-"));
const view = (...args) => spawnSync(process.execPath, [cliPath, "view", ...args, "--dir", root], { encoding: "utf8" });
const ok = (...args) => { const r = view(...args); assert.equal(r.status, 0, r.stderr || r.stdout); return JSON.parse(r.stdout); };
const DATE = "2026-03-02";
const TASK_A = "id:aaaaaaaa-1111-4111-8111-111111111111";
const TASK_B = "id:bbbbbbbb-2222-4222-8222-222222222222";
const notes = path.join(root, "notes", "work.org");

try {
  fs.mkdirSync(path.dirname(notes), { recursive: true });
  fs.writeFileSync(notes, [
    "* TODO [#A] Draft quarterly summary",
    "SCHEDULED: <2026-03-02 Mon>",
    ":PROPERTIES:",
    ":ID: aaaaaaaa-1111-4111-8111-111111111111",
    ":EFFORT: 1:30",
    ":END:",
    "* TODO Reply to the example vendor",
    "DEADLINE: <2026-03-01 Sun>",
    ":PROPERTIES:",
    ":ID: bbbbbbbb-2222-4222-8222-222222222222",
    ":END:",
    "* DONE Finished item",
    "SCHEDULED: <2026-03-02 Mon>",
    "* TODO Someday idea",
    "",
  ].join("\n"));

  // Save: preview writes nothing, apply creates the view file.
  const preview = ok("create", "today", "--title", "Plan my day", "--available-minutes", "60");
  assert.equal(preview.applied, false);
  assert.equal(fs.existsSync(path.join(root, "views", "today.org2-interactive-view.json")), false);
  ok("create", "today", "--title", "Plan my day", "--available-minutes", "60", "--apply");
  assert.equal(ok("list").views[0].id, "today");
  assert.notEqual(view("create", "today", "--title", "Again", "--apply").status, 0, "duplicate create must fail");

  // Refresh links source tasks and computes fit against available time.
  let refresh = ok("refresh", "today", "--date", DATE);
  assert.deepEqual(refresh.items.map(i => i.key), [TASK_B, TASK_A], "overdue before scheduled");
  const a = refresh.items.find(i => i.key === TASK_A);
  assert.equal(a.source.file, "notes/work.org");
  assert.equal(a.source.line, 1);
  assert.equal(a.source.link, TASK_A);
  assert.match(a.source.revision, /^sha256:/);
  assert.equal(a.estimateMinutes, 90);
  assert.equal(a.fits, false);

  // Remember choices; reopen (a fresh refresh) preserves them.
  const saved = ok("state", "today", "--patch", JSON.stringify({ order: [TASK_A, TASK_B], estimates: { [TASK_A]: 45 } }), "--if-revision", refresh.view.revision, "--apply");
  assert.equal(saved.applied, true);
  const stale = view("state", "today", "--patch", JSON.stringify({ availableMinutes: 30 }), "--if-revision", refresh.view.revision, "--apply");
  assert.equal(stale.status, 3, "stale view revision must be rejected");
  assert.equal(JSON.parse(stale.stdout).code, "ORG2_WRITE_CONFLICT");
  assert.match(view("state", "today", "--patch", JSON.stringify({ script: "x" }), "--if-revision", saved.revision).stderr, /Unsupported view state field/);
  refresh = ok("refresh", "today", "--date", DATE);
  assert.deepEqual(refresh.items.map(i => i.key), [TASK_A, TASK_B]);
  assert.equal(refresh.items[0].estimateMinutes, 45);
  assert.equal(refresh.items[0].fits, true);

  // Refresh reflects canonical source changes made outside the view.
  fs.appendFileSync(notes, "* TODO Newly scheduled\nSCHEDULED: <2026-03-02 Mon>\n");
  refresh = ok("refresh", "today", "--date", DATE);
  assert.equal(refresh.items.length, 3);
  assert.deepEqual(refresh.items.slice(0, 2).map(i => i.key), [TASK_A, TASK_B], "remembered order survives new data");

  // Guarded action: preview, refuse stale or substituted applies, apply, undo.
  const action = JSON.stringify({ action: "schedule", task: TASK_A, date: "2026-03-03" });
  const actionPreview = ok("action", "today", "--action", action);
  assert.equal(actionPreview.applied, false);
  assert.deepEqual(actionPreview.diff, ["-SCHEDULED: <2026-03-02 Mon>", "+SCHEDULED: <2026-03-03 Tue>"]);
  const original = fs.readFileSync(notes, "utf8");
  const wrongFingerprint = view("action", "today", "--action", JSON.stringify({ action: "schedule", task: TASK_A, date: "2026-03-09" }), "--fingerprint", actionPreview.fingerprint, "--if-revision", actionPreview.sourceRevision, "--apply");
  assert.notEqual(wrongFingerprint.status, 0, "fingerprint must bind the exact action");
  fs.writeFileSync(notes, original + "Concurrent edit\n");
  const staleApply = view("action", "today", "--action", action, "--fingerprint", actionPreview.fingerprint, "--if-revision", actionPreview.sourceRevision, "--apply");
  assert.equal(staleApply.status, 3, "stale source revision must be rejected");
  assert.equal(fs.readFileSync(notes, "utf8"), original + "Concurrent edit\n", "stale apply wrote nothing");
  fs.writeFileSync(notes, original);
  const applied = ok("action", "today", "--action", action, "--fingerprint", actionPreview.fingerprint, "--if-revision", actionPreview.sourceRevision, "--actor", "tester", "--apply");
  assert.equal(applied.historyRecorded, true);
  assert.match(fs.readFileSync(notes, "utf8"), /SCHEDULED: <2026-03-03 Tue>/);
  refresh = ok("refresh", "today", "--date", DATE);
  assert.equal(refresh.items.some(i => i.key === TASK_A), false, "rescheduled task leaves today's plan");
  assert.ok(refresh.staleKeys.includes(TASK_A), "remembered choice is retained, not dropped");
  assert.equal(refresh.history[0].id, applied.actionId);

  const undoPreview = ok("undo", "today", "--action-id", applied.actionId);
  assert.equal(undoPreview.applied, false);
  assert.match(fs.readFileSync(notes, "utf8"), /2026-03-03/, "undo preview writes nothing");
  ok("undo", "today", "--action-id", applied.actionId, "--apply");
  assert.equal(fs.readFileSync(notes, "utf8"), original, "undo restores the exact source");
  assert.notEqual(view("undo", "today", "--action-id", applied.actionId, "--apply").status, 0, "undo is single-use");

  // Undo refuses to overwrite newer edits.
  const p2 = ok("action", "today", "--action", action);
  const a2 = ok("action", "today", "--action", action, "--fingerprint", p2.fingerprint, "--if-revision", p2.sourceRevision, "--apply");
  fs.appendFileSync(notes, "Later edit\n");
  assert.equal(view("undo", "today", "--action-id", a2.actionId, "--apply").status, 3);
  assert.match(fs.readFileSync(notes, "utf8"), /Later edit\n$/);
  fs.writeFileSync(notes, original);

  // Reversible when the action adds a token or a planning line that did not exist.
  for (const [task, dateValue] of [[TASK_B, "2026-03-05"], ["file:notes/work.org::Someday idea", "2026-03-06"]]) {
    const request = JSON.stringify({ action: "schedule", task, date: dateValue });
    const p = ok("action", "today", "--action", request);
    const done = ok("action", "today", "--action", request, "--fingerprint", p.fingerprint, "--if-revision", p.sourceRevision, "--apply");
    assert.match(fs.readFileSync(notes, "utf8"), new RegExp(`SCHEDULED: <${dateValue}`));
    ok("undo", "today", "--action-id", done.actionId, "--apply");
    assert.equal(fs.readFileSync(notes, "utf8"), original, `undo restores ${task}`);
  }

  // Bridge: narrow, closed intent set. No apply or undo intents.
  const viewRevision = ok("show", "today").revision;
  const base = { type: "org2-view-intent", version: 1, viewId: "today" };
  assert.equal(parseViewBridgeIntent({ ...base, intent: "preview-action", action: { action: "schedule", task: TASK_A, date: DATE } }, { viewId: "today" }).intent, "preview-action");
  for (const [message, pattern] of [
    [{ ...base, intent: "apply-action", action: {} }, /Unsupported view intent/],
    [{ ...base, intent: "undo", actionId: "x" }, /Unsupported view intent/],
    [{ ...base, viewId: "other", intent: "open-source", task: TASK_A }, /different view/],
    [{ ...base, intent: "open-source", task: TASK_A, fingerprint: "sha256:00" }, /Unexpected view intent field/],
    [{ ...base, intent: "preview-action", action: { action: "delete", task: TASK_A } }, /Only the schedule action/],
    [{ ...base, intent: "preview-action", action: { action: "schedule", task: TASK_A, date: DATE, fingerprint: "x" } }, /Unsupported action field/],
    [{ ...base, intent: "set-state", viewRevision, patch: { history: [] } }, /Unsupported view state field/],
    [{ ...base, intent: "set-state", patch: { order: [] } }, /requires the view revision/],
    [{ ...base, intent: "open-source", task: "file:../../etc/passwd" }, /Invalid task key/],
    [{ type: "org2-frame-size", height: 10 }, /Not an interactive view intent/],
  ]) assert.throws(() => parseViewBridgeIntent(message, { viewId: "today" }), pattern);

  const bridged = ok("bridge", "today", "--message", JSON.stringify({ ...base, intent: "set-state", viewRevision, patch: { availableMinutes: 120 } }));
  assert.equal(bridged.applied, true);
  assert.equal(ok("show", "today").view.state.availableMinutes, 120);
  const bridgedPreview = ok("bridge", "today", "--message", JSON.stringify({ ...base, intent: "preview-action", action: { action: "schedule", task: TASK_B, date: "2026-03-04" } }));
  assert.equal(bridgedPreview.applied, false);
  assert.equal(fs.readFileSync(notes, "utf8"), original, "bridge preview never writes source");
  assert.equal(ok("bridge", "today", "--message", JSON.stringify({ ...base, intent: "open-source", task: TASK_B })).line, 7);

  // Rendered view is an Org html block that runs in Celorga's opaque-origin sandbox.
  const org = renderInteractiveViewOrg(refreshInteractiveView(root, "today", { date: DATE }));
  assert.match(org, /\[\[id:aaaaaaaa-1111-4111-8111-111111111111\]\[Draft quarterly summary\]\]/);
  assert.match(org, /#\+celorga_view_revision: sha256:/);
  const html = renderAppHTML(org, { sourcePath: path.join(root, "views", "today.org") });
  const frame = /<iframe[^>]*sandbox="([^"]*)"[^>]*srcdoc="([^"]*)"/.exec(html);
  assert.ok(frame, "html block renders as a sandboxed frame");
  assert.equal(frame[1], "allow-scripts allow-forms allow-popups");
  assert.doesNotMatch(frame[1], /allow-same-origin|allow-top-navigation/);
  assert.match(frame[2], /org2-view-intent/);
  assert.doesNotMatch(frame[2], /apply/i, "frame code has no apply path");
  const hostile = renderInteractiveViewOrg({ ...refreshInteractiveView(root, "today", { date: DATE }), items: [{ ...refreshInteractiveView(root, "today", { date: DATE }).items[0], title: "</script><script>alert(1)</script>" }] });
  assert.doesNotMatch(hostile.split("#+begin_src html")[1], /<\/script><script>alert/, "task titles cannot break out of the data script");

  console.log("interactive views: ok");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
