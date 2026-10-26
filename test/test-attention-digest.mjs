#!/usr/bin/env node
// The attention digest reports only what needs the person, deterministically:
// approvals, blocked runs, artifact reviews, chats awaiting a reply, failed
// runs, overdue deadlines, and today's deadlines and scheduled items. It
// filters by celorga.json "attention" preferences, dedupes by fingerprint,
// interrupts only for undelivered items outside quiet hours, and records
// delivery only with --mark-delivered --apply.
process.env.TZ = "UTC";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { appleReferenceDateSeconds } from "../dist/openClawThreadState.js";
import { addAgentRunArtifact, addAgentRunComment, createAgentRun, requestAgentRunApproval, saveAgentRun, transitionAgentRun } from "../dist/agentRun.js";
import { buildAttentionDigest, inQuietHours, renderAttentionDigestText, attentionDeliveredFile } from "../dist/attentionDigest.js";
import { validateAttentionConfig } from "../dist/config.js";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "dist", "cli.js");
const base = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-attention-digest-"));
process.env.ORG2_INDEX_HOME = path.join(base, "index-home");
const NOW = new Date("2026-10-26T09:00:00Z");
const at = (minutesBefore) => new Date(NOW.getTime() - minutesBefore * 60_000);
const iso = (minutesBefore) => at(minutesBefore).toISOString();

function corpus(name, id, attention) {
  const root = path.join(base, name);
  fs.mkdirSync(path.join(root, "notes"), { recursive: true });
  fs.writeFileSync(path.join(root, "celorga.json"), `${JSON.stringify({ corpus: { schema: "org2:corpus:v1", id, name, kind: "project" }, agendaFiles: ["**/*.org"], ...(attention ? { attention } : {}) }, null, 2)}\n`);
  return root;
}

function setAttention(root, attention) {
  const file = path.join(root, "celorga.json");
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  if (attention === undefined) delete config.attention;
  else config.attention = attention;
  fs.writeFileSync(file, `${JSON.stringify(config, null, 2)}\n`);
}

const message = (id, role, minutes, extra = {}) => ({ id, role, content: `${role} ${id}`, createdAt: appleReferenceDateSeconds(at(minutes)), deliveryStatus: "sent", ...extra });
const thread = (id, title, messages, extra = {}) => ({
  id, title, createdAt: appleReferenceDateSeconds(at(600)), updatedAt: appleReferenceDateSeconds(at(30)),
  sessionKey: `agent:main:${id}`, messages, isPinned: false, isArchived: false, unreadMessageCount: 0, runtime: "codex", destinationID: "builtin.codex", ...extra,
});

const T = {
  replied: "AAAAAAAA-0000-4000-8000-0000000000A1",
  idle: "BBBBBBBB-0000-4000-8000-0000000000B2",
  approvalChat: "CCCCCCCC-0000-4000-8000-0000000000C3",
};

const celorga = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", env: { ...process.env, TZ: "UTC" } });
const byCategory = (digest, category) => digest.items.filter((item) => item.category === category);
const titles = (digest, category) => byCategory(digest, category).map((item) => item.title).sort();

try {
  const alpha = corpus("alpha", "alpha-attention");
  fs.writeFileSync(path.join(alpha, "notes", "tasks.org"), [
    "#+title: Tasks",
    "",
    "* TODO File the quarterly report",
    "DEADLINE: <2026-10-20 Tue>",
    "",
    "* TODO Water the ferns",
    "SCHEDULED: <2026-10-26 Mon>",
    "",
    "* TODO Prepare workshop slides :work:",
    "DEADLINE: <2026-10-26 Mon 14:00>",
    "",
    "* DONE Old finished deadline",
    "DEADLINE: <2026-10-10 Sat>",
    "",
    "* TODO Stale scheduled chore",
    "SCHEDULED: <2026-10-01 Thu>",
    "",
    "* TODO Future deadline in warning period",
    "DEADLINE: <2026-10-29 Thu>",
    "",
    "* TODO Learn the oboe :someday:",
    "SCHEDULED: <2026-10-26 Mon>",
    "",
    "* TODO Approve the vendor contract",
    ":PROPERTIES:",
    ":ID: 7a1d3f0e-0000-4000-8000-00000000c0de",
    ":STATUS: needs-approval",
    ":END:",
    "",
  ].join("\n"));
  fs.mkdirSync(path.join(alpha, "archive"), { recursive: true });
  fs.writeFileSync(path.join(alpha, "archive", "old.org"), "* TODO Archived errand\nSCHEDULED: <2026-10-26 Mon>\n");

  let approval = createAgentRun({ id: "run-approval", title: "Publish release notes", goal: "Publish release notes", riskClass: "external-action", now: iso(120) });
  approval = transitionAgentRun(approval, "running", { actor: "Agent", now: iso(110) });
  approval = addAgentRunComment(approval, "Agent", `AI chat thread: ${T.approvalChat}`, iso(100));
  approval = requestAgentRunApproval(approval, { title: "Publish notes", action: "publish release notes to the public site", riskClass: "external-action", requestedAt: iso(90) }, "Agent");
  approval = transitionAgentRun(approval, "waiting-approval", { actor: "Agent", now: iso(90) });
  saveAgentRun(alpha, approval, { expectedRevision: null });

  let blocked = createAgentRun({ id: "run-blocked", title: "Migrate the tag index", goal: "Migrate the tag index", now: iso(200) });
  blocked = transitionAgentRun(blocked, "running", { actor: "Agent", now: iso(190) });
  blocked = transitionAgentRun(blocked, "blocked", { actor: "Agent", reason: "Which tag spelling should win: colour or color?", now: iso(60) });
  saveAgentRun(alpha, blocked, { expectedRevision: null });

  let failed = createAgentRun({ id: "run-failed", title: "Nightly export", goal: "Nightly export", now: iso(300) });
  failed = transitionAgentRun(failed, "running", { actor: "Agent", now: iso(290) });
  failed = transitionAgentRun(failed, "failed", { actor: "Agent", reason: "disk full", now: iso(280) });
  saveAgentRun(alpha, failed, { expectedRevision: null });

  let review = createAgentRun({ id: "run-review", title: "Draft the onboarding guide", goal: "Draft the onboarding guide", now: iso(400) });
  review = transitionAgentRun(review, "running", { actor: "Agent", now: iso(390) });
  review = transitionAgentRun(review, "completed", { actor: "Agent", summary: "Draft ready for review", now: iso(380) });
  // A completed record can still carry an artifact attached afterwards that awaits review.
  review = addAgentRunArtifact(review, { id: "guide", path: "views/onboarding-guide.org", role: "draft", reviewStatus: "review-required", createdAt: iso(370) }, "Agent");
  saveAgentRun(alpha, review, { expectedRevision: null });

  // An old blocked run is outside --since but still within the activity window.
  let oldBlocked = createAgentRun({ id: "run-old-blocked", title: "Rename photo folders", goal: "Rename photo folders", now: iso(60 * 50) });
  oldBlocked = transitionAgentRun(oldBlocked, "blocked", { actor: "Agent", reason: "Which year format?", now: iso(60 * 48) });
  saveAgentRun(alpha, oldBlocked, { expectedRevision: null });

  fs.mkdirSync(path.join(alpha, ".org2"), { recursive: true });
  fs.writeFileSync(path.join(alpha, ".org2", "openclaw-chat.json"), JSON.stringify({ version: 6, selectedThreadID: null, threads: [
    thread(T.replied, "Trip planning", [message("M1", "user", 40), message("M2", "assistant", 35)], { unreadMessageCount: 1 }),
    thread(T.idle, "Quiet chat", [message("M3", "user", 50), message("M4", "assistant", 45)]),
    thread(T.approvalChat, "Release chat", [message("M5", "user", 100)]),
  ] }));

  // 1. Content: each category once, with evidence and stable fingerprints.
  const first = await buildAttentionDigest({ root: alpha, now: NOW });
  assert.equal(first.schema, "org2:attention-digest:v1");
  assert.deepEqual(first.issues, []);
  assert.equal(first.local.date, "2026-10-26");
  assert.deepEqual(titles(first, "overdue"), ["TODO File the quarterly report"], "only unfinished overdue deadlines; overdue scheduled items are not interruptions");
  assert.deepEqual(titles(first, "today"), ["TODO Archived errand", "TODO Learn the oboe", "TODO Prepare workshop slides", "TODO Water the ferns"], "deadline warnings are not today's items");
  assert.equal(byCategory(first, "approval").filter((item) => item.ref === "run:run-approval").length, 1, "a run approval is reported once, not again through its run or linked chat");
  assert.ok(byCategory(first, "approval").some((item) => item.title === "Approve the vendor contract"), "Org heading approvals come from the approvals queue");
  assert.deepEqual(titles(first, "blocked"), ["Migrate the tag index", "Rename photo folders"]);
  assert.match(byCategory(first, "blocked").find((item) => item.ref === "run:run-blocked").summary, /colour or color/);
  assert.deepEqual(titles(first, "review"), ["Draft the onboarding guide"]);
  assert.deepEqual(titles(first, "failed"), ["Nightly export"]);
  assert.deepEqual(byCategory(first, "reply").map((item) => item.ref), [`thread:${T.replied}`], "idle chats and chats blocked on a run approval are not reply items");
  for (const item of first.items) {
    assert.match(item.fingerprint, /^att_[0-9a-f]{24}$/u);
    assert.ok(item.ref && item.evidence.length > 0, `${item.title} carries evidence`);
    assert.equal(item.delivered, false);
  }
  assert.equal(new Set(first.items.map((item) => item.fingerprint)).size, first.items.length);
  const slides = byCategory(first, "today").find((item) => item.title.includes("workshop slides"));
  assert.equal(slides.ref, "notes/tasks.org:9");
  assert.equal(slides.evidence[0].line, 9);
  assert.deepEqual(slides.tags, ["work"]);
  assert.equal(slides.summary, "Due today at 14:00");
  assert.equal(first.interrupt, true);
  assert.equal(first.summary.new, first.items.length);
  assert.ok(first.notification.title.startsWith(`Celorga: ${first.items.length} new items`));
  assert.equal(first.notification.fingerprints.length, first.items.length);
  assert.match(renderAttentionDigestText(first), /NEW \[approval\]/u);
  const again = await buildAttentionDigest({ root: alpha, now: new Date(NOW.getTime() + 5 * 60_000) });
  assert.deepEqual(again.items.map((item) => item.fingerprint), first.items.map((item) => item.fingerprint), "fingerprints are stable across runs");

  // 2. Preferences: categories, tags, and paths filter; --since bounds run and chat items.
  setAttention(alpha, { excludeCategories: ["failed"], excludeTags: ["someday"], excludePaths: ["archive/**"] });
  const filtered = await buildAttentionDigest({ root: alpha, now: NOW, sinceSeconds: 24 * 3600 });
  assert.equal(byCategory(filtered, "failed").length, 0);
  assert.deepEqual(titles(filtered, "today"), ["TODO Prepare workshop slides", "TODO Water the ferns"]);
  assert.deepEqual(titles(filtered, "blocked"), ["Migrate the tag index"], "--since drops run items whose last signal is older");
  assert.ok(filtered.preferencesFile.endsWith("celorga.json"));
  setAttention(alpha, { includeCategories: ["approval", "overdue"] });
  const narrowed = await buildAttentionDigest({ root: alpha, now: NOW });
  assert.deepEqual([...new Set(narrowed.items.map((item) => item.category))].sort(), ["approval", "overdue"]);

  setAttention(alpha, { excludeCategories: ["sometimes"], quietHours: { start: "25:00", end: "07:00" }, checkIntervalMinutes: 5, surprise: true });
  await assert.rejects(buildAttentionDigest({ root: alpha, now: NOW }), (error) => {
    assert.match(error.message, /invalid attention settings/u);
    assert.match(error.message, /unknown categories: sometimes/u);
    assert.match(error.message, /quietHours/u);
    assert.match(error.message, /checkIntervalMinutes/u);
    assert.match(error.message, /attention\.surprise is not a known/u);
    return true;
  });
  const defaults = validateAttentionConfig(undefined);
  assert.deepEqual(defaults.issues, []);
  assert.equal(defaults.preferences.morningBrief, "08:00");
  assert.equal(defaults.preferences.checkIntervalMinutes, 120);
  setAttention(alpha, undefined);

  // 3. Delivery: preview writes nothing; --apply records; delivered items stop interrupting.
  const ledger = attentionDeliveredFile(alpha);
  await assert.rejects(buildAttentionDigest({ root: alpha, now: NOW, apply: true }), /--apply requires --mark-delivered/u);
  const preview = await buildAttentionDigest({ root: alpha, now: NOW, markDelivered: true });
  assert.equal(preview.delivery.applied, false);
  assert.equal(preview.delivery.marked.length, preview.items.length);
  assert.equal(preview.delivery.revision, null);
  assert.equal(fs.existsSync(ledger), false, "preview never writes the ledger");

  const onlyTwo = preview.items.slice(0, 2).map((item) => item.fingerprint);
  await assert.rejects(buildAttentionDigest({ root: alpha, now: NOW, markDelivered: true, fingerprints: ["att_000000000000000000000000"], apply: true }), /not in the current digest/u);
  await assert.rejects(buildAttentionDigest({ root: alpha, now: NOW, markDelivered: true, ifRevision: "sha256:stale", apply: true }), /ledger changed/u);
  const partial = await buildAttentionDigest({ root: alpha, now: NOW, markDelivered: true, fingerprints: onlyTwo, ifRevision: "absent", apply: true });
  assert.equal(partial.delivery.applied, true);
  assert.deepEqual([...partial.delivery.marked].sort(), [...onlyTwo].sort());
  assert.ok(ledger.includes(`${path.sep}.org2${path.sep}attention${path.sep}`), "the ledger lives in the corpus state directory");
  const stored = JSON.parse(fs.readFileSync(ledger, "utf8"));
  assert.equal(stored.schema, "org2:attention-delivered:v1");
  assert.deepEqual(Object.keys(stored.delivered).sort(), [...onlyTwo].sort());

  const afterPartial = await buildAttentionDigest({ root: alpha, now: NOW });
  assert.equal(afterPartial.summary.delivered, 2);
  assert.equal(afterPartial.interrupt, true);
  assert.equal(afterPartial.notification.fingerprints.length, afterPartial.items.length - 2, "only undelivered items are announced");

  const all = await buildAttentionDigest({ root: alpha, now: NOW, markDelivered: true, ifRevision: partial.delivery.revision, apply: true });
  assert.equal(all.delivery.marked.length, all.items.length - 2);
  const quietNow = await buildAttentionDigest({ root: alpha, now: NOW });
  assert.equal(quietNow.interrupt, false);
  assert.equal(quietNow.notification, null);
  assert.match(quietNow.interruptReason, /already delivered/u);
  assert.ok(quietNow.items.every((item) => item.delivered && item.deliveredAt));

  // A new deadline interrupts again, alone.
  fs.appendFileSync(path.join(alpha, "notes", "tasks.org"), "* TODO Renew the passport\nDEADLINE: <2026-10-22 Thu>\n");
  const fresh = await buildAttentionDigest({ root: alpha, now: NOW });
  assert.equal(fresh.interrupt, true);
  assert.equal(fresh.summary.new, 1);
  assert.equal(fresh.notification.title, "Celorga: 1 new item needs you");
  assert.equal(fresh.notification.body, "Overdue: TODO Renew the passport");

  // Brief mode summarizes everything, delivered or not.
  const brief = await buildAttentionDigest({ root: alpha, now: NOW, mode: "brief" });
  assert.equal(brief.interrupt, true);
  assert.equal(brief.notification.fingerprints.length, brief.items.length);
  assert.ok(brief.notification.title.startsWith(`Celorga brief: ${brief.items.length} items`));
  assert.match(brief.notification.body, /and \d+ more$/u);

  // 4. Quiet hours hold interrupts, including windows that wrap midnight.
  setAttention(alpha, { quietHours: { start: "22:00", end: "07:00" } });
  const night = await buildAttentionDigest({ root: alpha, now: new Date("2026-10-26T23:30:00Z") });
  assert.equal(night.quietHours.active, true);
  assert.equal(night.interrupt, false);
  assert.match(night.interruptReason, /Quiet hours 22:00–07:00/u);
  assert.ok(night.summary.new >= 1, "held items stay undelivered");
  const quiet = { start: "22:00", end: "07:00" };
  assert.equal(inQuietHours(new Date("2026-10-26T06:59:00Z"), quiet), true);
  assert.equal(inQuietHours(new Date("2026-10-26T07:00:00Z"), quiet), false);
  assert.equal(inQuietHours(new Date("2026-10-26T21:59:00Z"), quiet), false);
  assert.equal(inQuietHours(new Date("2026-10-26T13:00:00Z"), { start: "12:00", end: "14:00" }), true);
  assert.equal(inQuietHours(new Date("2026-10-26T13:00:00Z"), null), false);
  setAttention(alpha, undefined);

  // 5. Mounts: read across corpora, but delivery writes one corpus only.
  const beta = corpus("beta", "beta-attention");
  fs.writeFileSync(path.join(beta, "notes", "home.org"), "* TODO Pay the electricity bill\nDEADLINE: <2026-10-26 Mon>\n");
  const mounted = await buildAttentionDigest({ mounts: [alpha, beta], now: NOW });
  assert.deepEqual(mounted.corpora.map((entry) => entry.id), ["alpha-attention", "beta-attention"]);
  assert.ok(mounted.items.some((item) => item.corpus.id === "beta-attention" && item.title === "TODO Pay the electricity bill"));
  await assert.rejects(buildAttentionDigest({ mounts: [alpha, beta], now: NOW, markDelivered: true }), /exactly one/u);

  // 6. CLI contract.
  const json = celorga("workspace", "attention", "--dir", beta, "--now", NOW.toISOString(), "--json");
  assert.equal(json.status, 0, json.stderr);
  const payload = JSON.parse(json.stdout);
  assert.equal(payload.schema, "org2:attention-digest:v1");
  assert.equal(payload.interrupt, true);
  assert.equal(payload.items[0].category, "today");
  const mark = celorga("workspace", "attention", "--dir", beta, "--now", NOW.toISOString(), "--mark-delivered", "--fingerprint", payload.items[0].fingerprint, "--apply");
  assert.equal(mark.status, 0, mark.stderr);
  assert.match(mark.stdout, /Marked 1 item\(s\) delivered/u);
  const text = celorga("workspace", "attention", "--dir", beta, "--now", NOW.toISOString());
  assert.match(text.stdout, /interrupt: no/u);
  const bad = celorga("workspace", "attention", "--dir", beta, "--mode", "loud");
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /invalid attention mode/u);
  const help = celorga("workspace", "--help");
  assert.match(help.stdout + help.stderr, /workspace attention/u);

  console.log("attention digest tests passed");
} finally {
  fs.rmSync(base, { recursive: true, force: true });
}
