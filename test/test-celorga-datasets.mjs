import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { runOrg2DataQuery, applyDataQueryResults } from "../dist/dataQuery.js";
import { parseCelorgaDataset, createCelorgaDatasetLoader } from "../dist/celorgaDatasets.js";
import { renderAppHTML } from "../dist/appHtmlRenderer.js";
import { writeShardedV2Store } from "./helpers/ai-chat-sharded-fixture.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-datasets-"));
const file = path.join(root, "views", "unanswered.org");
const source = fs.readFileSync("examples/chat-response-queue/views/unanswered.org", "utf8");
const now = Date.now();
const at = minutes => (now - minutes * 60_000) / 1000 - 978_307_200;
const user = (fields = {}) => ({ id: crypto.randomUUID(), role: "user", content: "Inspect the draft", deliveryStatus: "sent", createdAt: at(30), ...fields });
const reply = (fields = {}) => ({ id: crypto.randomUUID(), role: "assistant", content: "Inspection completed", deliveryStatus: "sent", createdAt: at(20), ...fields });
const thread = (messages, fields = {}) => ({ metadata: { id: crypto.randomUUID(), title: "Inspect draft", destinationID: "reviewer", runtime: "codex", updatedAt: at(1), ...fields }, messages });
let generation = 0;
function write(threads) {
  return writeShardedV2Store(root, { threads, generation: ++generation,
    legacyPayload: { version: 6, threads: [{ id: crypto.randomUUID(), title: "Stale compatibility transcript", updatedAt: at(1), messages: [user({ deliveryStatus: "failed" })] }] } });
}
async function run(resultId = "unanswered") {
  const result = await runOrg2DataQuery(source, { file, resultId });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  return result;
}
const actionable = result => result.rows.filter(row => row.Status !== "Clear");
try {
  fs.mkdirSync(path.dirname(file));
  fs.writeFileSync(path.join(root, "celorga.json"), "{}");
  fs.writeFileSync(file, source);
  assert.equal(parseCelorgaDataset("chat-messages").sinceDays, 7);
  for (const [kind, since] of [["unknown", "7d"], ["chat-messages", "0d"], ["chat-messages", "7w"], ["chat-messages", "3651d"]]) assert.throws(() => parseCelorgaDataset(kind, since));
  for (const extra of ["path: ../other/celorga.json", "profile: other", "url: https://example.test/data", "credential: env:TOKEN"]) {
    const invalid = source.replace("type: celorga", `type: celorga\n${extra}`);
    const result = await runOrg2DataQuery(invalid, { file, resultId: "unanswered", inspectOnly: true });
    assert.equal(result.ok, false, extra);
  }
  // Inspect never reads chat storage; typed empty relations retain every column.
  fs.mkdirSync(path.join(root, ".org2"));
  fs.writeFileSync(path.join(root, ".org2", "openclaw-chat.json"), "not-json");
  const inspection = await runOrg2DataQuery(source, { file, resultId: "unanswered", inspectOnly: true, includeScript: true });
  assert.equal(inspection.ok, true);
  assert.match(inspection.duckdbScript, /CAST\(NULL AS BIGINT\) AS "ordinal"/);
  const unavailable = await runOrg2DataQuery(source, { file, resultId: "unanswered" });
  assert.equal(unavailable.ok, false);

  write([]);
  assert.equal((await run()).rows[0].Status, "Clear");
  write([thread([user(), reply()])]);
  assert.equal(actionable(await run()).length, 0);
  write([thread([user({ deliveryStatus: "failed", sendFailure: "Connection timed out" }), reply({ sendFailure: "Connection timed out" })], { settledAt: at(2), isArchived: true })]);
  const failed = await run();
  assert.equal(actionable(failed).length, 1);
  assert.equal(failed.rows[0].Status, "Failed");
  assert.equal(failed.rows[0].Error, "Connection timed out");
  assert.equal(failed.rows[0].Requested, new Date((at(30) + 978_307_200) * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC");
  assert.match(failed.rows[0].Conversation, /\[\[org2-chat:/);
  for (const response of [reply({ content: "" }), reply({ source: "run:background" }), reply({ authorAgentRef: "background-worker" }), reply({ authorLabel: "Background worker" }), reply({ authorDestinationID: "another-agent" }), reply({ deliveryStatus: "interrupted" })]) {
    write([thread([user(), response])]);
    assert.equal(actionable(await run()).length, 1, JSON.stringify(response));
  }
  write([thread([user({ deliveryStatus: "interrupted" }), reply({ deliveryStatus: "interrupted" })])]);
  assert.equal((await run()).rows[0].Status, "Interrupted");
  write([thread([user(), reply({ sendFailure: "Provider failed" })])]);
  assert.equal((await run()).rows[0].Error, "Provider failed");
  write([thread([user({ deliveryStatus: "failed" }), user(), reply()])]);
  assert.equal(Number((await run()).rows[0].Requests), 1);
  write([thread([user(), user(), reply(), reply()])]);
  assert.equal((await run()).rows[0].Status, "Reply association unclear", "An uncorrelated late reply must not silently clear a request");
  write([thread([user(), user(), reply()])]);
  assert.equal(Number((await run()).rows[0].Requests), 1);
  write([thread([user(), user({ deliveryKind: "steer" }), reply()])]);
  assert.equal(actionable(await run()).length, 0);

  write([thread([user()], { isSharedRoom: true, roomDestinationIDs: ["reviewer", "builder"], roomDefaultDestinationID: "" })]);
  assert.equal(actionable(await run()).length, 0, "Posting room context requests no agent reply");

  const round = crypto.randomUUID();
  write([thread([user({ roomRoundID: round, audienceDestinationIDs: ["reviewer", "builder"] }), user({ roomRoundID: round, isRoomDispatchCopy: true, targetDestinationID: "builder", deliveryStatus: "failed" }), reply({ roomRoundID: round, authorDestinationID: "reviewer" })], { isSharedRoom: true, roomDestinationIDs: ["reviewer", "builder"] })]);
  const room = await run();
  assert.equal(Number(room.rows[0].Requests), 1);
  assert.equal(room.rows[0].Agent, "builder");
  write([thread([user({ provenance: { requestedByDestinationID: "another-agent" } })]), thread([user({ content: "#+org2_automation_event_id: run-1\nScheduled prompt" })]), thread([user()], { title: "Automation: Daily digest" })]);
  assert.equal(actionable(await run()).length, 0);
  write([thread([user({ createdAt: at(8 * 1440) })]), thread([user({ createdAt: at(-60) })])]);
  assert.equal(actionable(await run()).length, 0);

  write([thread([user({ deliveryStatus: "sending", deliveryAttemptState: "unconfirmed", sendFailure: "Submission result is unknown" })])]);
  assert.equal((await run()).rows[0].Status, "Awaiting confirmation");

  const liveUser = user({ deliveryStatus: "sending" });
  const liveThread = thread([liveUser]);
  write([liveThread]);
  const liveDirectory = path.join(root, ".org2/openclaw-chat.store/live");
  fs.mkdirSync(liveDirectory);
  const liveFile = path.join(liveDirectory, "test.json");
  const host = { schema: "org2:ai-chat-live-host:v1", writerID: "test-host", hostRef: "test-host", hostName: "Test host", hostKind: "desktop", isOnline: true, updatedAt: new Date().toISOString(), enabledDestinationIDs: ["reviewer"], turns: [{ threadID: liveThread.metadata.id, userMessageID: liveUser.id, destinationID: "reviewer" }] };
  fs.writeFileSync(liveFile, JSON.stringify(host));
  assert.equal(actionable(await run()).length, 0);
  assert.equal((await run("in_progress")).rows[0].Status, "Running");
  fs.writeFileSync(liveFile, JSON.stringify({ ...host, updatedAt: new Date(now - 3600_000).toISOString() }));
  assert.equal((await run()).rows[0].Status, "No completed response");
  write([thread([user({ deliveryStatus: "sending", createdAt: at(0.5) })])]);
  assert.equal((await run("in_progress")).rows[0].Status, "Recently sent");

  write([thread([user({ deliveryStatus: "failed", sendFailure: "A | B\nC", content: "Request | with\nnewlines" })], { title: "A [title] | line" })]);
  const first = await run();
  const second = await run("in_progress");
  assert.doesNotMatch(first.rows[0].Request, /[|\r\n]/);
  assert.doesNotMatch(first.rows[0].Error, /[|\r\n]/);
  const materialized = applyDataQueryResults(source, [first, second]);
  assert.equal((materialized.text.match(/#\+query-data: result=unanswered /g) ?? []).length, 1);
  assert.ok(materialized.text.indexOf("#\+query-data: result=unanswered ") > materialized.text.indexOf(":END:"));
  const html = renderAppHTML(materialized.text, { sourcePath: file, corpusRoot: root });
  assert.match(html, /org2-workspace:\/\/open-thread\?id=/);
  assert.match(html, /<summary>Refreshed [^<]+ UTC · 1 row<\/summary>/);
  assert.match(html, /<details class="org2-drawer org2-query-provenance"/);
  assert.match(renderAppHTML("#+TITLE: Pending report\n#+query-data: result=example status=not-run\n", { sourcePath: file, corpusRoot: root }), /<summary>Not refreshed<\/summary>/);
  assert.doesNotMatch(html, /CHAT_QUEUE/);
  assert.equal(fs.readFileSync(file, "utf8"), source, "Read-only query never rewrites the notebook");
  assert.throws(() => createCelorgaDatasetLoader(path.join(os.tmpdir(), "outside.org"), [parseCelorgaDataset("chat-messages")]));
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("Celorga datasets and SQL chat notebook tests passed");
