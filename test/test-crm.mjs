#!/usr/bin/env node
// People & Companies: a CRM computed from entity notes, meetings, TODOs,
// work-ledger accounts and staged calendar events. Writes preview first.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { appendWorkLedgerEvent, createWorkLedgerAccount, loadWorkLedgerAccount, saveWorkLedgerAccount } from "../dist/workLedger.js";
import { crmTimeFrom, normalizeCrmName, normalizeDomain } from "../dist/crm.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-crm-"));
const corpus = path.join(root, "corpus");
const indexHome = path.join(root, "index");
const NOW = "2026-03-02T15:00:00.000Z"; // Monday

const ACME = "11111111-1111-4111-8111-111111111111";
const GLOBEX = "22222222-2222-4222-8222-222222222222";
const JANE = "33333333-3333-4333-8333-333333333333";
const BOB = "44444444-4444-4444-8444-444444444444";
const CAROL = "55555555-5555-4555-8555-555555555555";

function write(relative, content) {
  const file = path.join(corpus, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}
const read = (relative) => fs.readFileSync(path.join(corpus, relative), "utf8");
function crm(args, options = {}) {
  const child = spawnSync("node", ["dist/cli.js", "crm", ...args, "--dir", corpus, "--now", NOW], {
    cwd: repo,
    env: { ...process.env, ORG2_INDEX_HOME: indexHome, TZ: "UTC" },
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (options.allowFailure !== true && child.status !== 0) throw new Error(`crm ${args.join(" ")} failed (${child.status}):\n${child.stdout}\n${child.stderr}`);
  return options.allowFailure ? child : JSON.parse(child.stdout);
}

try {
  // Pure helpers.
  assert.equal(normalizeCrmName("Globex Corporation"), "globex");
  assert.equal(normalizeCrmName("[[id:x][Acme, Inc.]]"), "acme");
  assert.equal(normalizeDomain("https://www.Acme.test/pricing"), "acme.test");
  assert.equal(normalizeDomain("jane@acme.test"), "acme.test");
  assert.equal(normalizeDomain("not a domain"), null);
  assert.equal(crmTimeFrom("<2026-03-03 Tue>"), "2026-03-03");
  assert.equal(crmTimeFrom("2026-02-20T17:00:00Z"), "2026-02-20T17:00:00.000Z");

  write("celorga.json", `${JSON.stringify({ agendaFiles: ["notes/**/*.org", "meetings/*.org", "daily/*.org"], crm: { selfDomains: ["example.org"] } }, null, 2)}\n`);
  write("notes/acme-robotics.org", `:PROPERTIES:\n:ID: ${ACME}\n:ORG2_ENTITY_TYPE: company\n:DOMAIN: acme.test\n:CRM_STAGE: prospect\n:END:\n#+title: Acme Robotics\n\nWarehouse robots.\n\n* TODO Send pricing to Acme\nSCHEDULED: <2026-03-03 Tue>\n`);
  write("notes/globex.org", `:PROPERTIES:\n:ID: ${GLOBEX}\n:ORG2_ENTITY_TYPE: company\n:END:\n#+title: Globex\n`);
  write("notes/jane-doe.org", `:PROPERTIES:\n:ID: ${JANE}\n:ORG2_ENTITY_TYPE: person\n:EMAIL: jane@acme.test\n:ROLE: VP Engineering\n:END:\n#+title: Jane Doe\n`);
  write("notes/bob-stone.org", `:PROPERTIES:\n:ID: ${BOB}\n:ORG2_ENTITY_TYPE: person\n:END:\n#+title: Bob Stone\n\nWorks at [[id:${GLOBEX}][Globex]]. Reach him at bob@globex.test.\n`);
  write("notes/carol-king.org", `:PROPERTIES:\n:ID: ${CAROL}\n:ORG2_ENTITY_TYPE: person\n:EMAIL: carol@acme.test\n:COMPANY: [[id:${ACME}][Acme Robotics]]\n:END:\n#+title: Carol King\n`);
  write("meetings/2026-02-20-acme-demo.org", `#+ORG2_KIND: meeting\n* Meeting: Acme demo\n:PROPERTIES:\n:kind: meeting\n:recorded_at: 2026-02-20T17:00:00Z\n:END:\n** Attendees\n- [[id:${JANE}][Jane Doe]]\n** TODOs\n*** TODO Share security docs\nDEADLINE: <2026-03-04 Wed>\n`);
  write("meetings/2026-02-19-jane.org", `#+ORG2_KIND: meeting\n* Meeting: Jane Doe\n:PROPERTIES:\n:kind: meeting\n:recorded_at: 2026-02-19T17:00:00Z\n:END:\n** Notes\nTalked roadmap.\n`);
  write("meetings/2026-02-27-globex-sync.org", `#+ORG2_KIND: meeting\n* Meeting: Quarterly sync\n:PROPERTIES:\n:kind: meeting\n:recorded_at: 2026-02-27T17:00:00Z\n:END:\n** Notes\nParticipants: [[id:${BOB}][Bob Stone]] and Pat.\n** Summary\n- Bob said [[id:${ACME}][Acme Robotics]] is a good reference.\n`);
  write("daily/2026-02-25.org", `#+title: 2026-02-25\n* Notes\nCall with [[id:${GLOBEX}][Globex]] went well.\n* TODO Check Globex contract\nSCHEDULED: <2026-03-02 Mon>\n:PROPERTIES:\n:ACCOUNT: Globex\n:END:\n`);

  const ledgerAccount = (id, title, keys, events = []) => {
    let account = createWorkLedgerAccount({ ledger: "outreach", id, title, identityKeys: keys, now: "2026-01-05T10:00:00Z" });
    for (const event of events) account = appendWorkLedgerEvent(account, event).account;
    saveWorkLedgerAccount(corpus, account, { expectedRevision: null });
  };
  ledgerAccount("acme", "Acme", ["domain:acme.test"], [{ idempotencyKey: "acme-1", type: "outreach-sent", at: "2026-01-10T12:00:00Z", note: "Intro email", externalId: "msg-acme-1" }]);
  ledgerAccount("globex", "Globex Corporation", ["domain:globex.test"], [{ idempotencyKey: "globex-1", type: "outreach-sent", at: "2026-02-01T12:00:00Z", externalId: "msg-globex-1" }]);
  ledgerAccount("initech", "Initech", ["domain:initech.test"], [{ idempotencyKey: "initech-1", type: "outreach-sent", at: "2026-02-10T12:00:00Z", externalId: "msg-initech-1" }]);

  write("raw/connectors/google-calendar/Work/primary--2026-03.json", `${JSON.stringify({
    schema: "org2:source-import:v1",
    records: [
      { rawPayload: { schema: "org2:calendar-event:v1", calendarId: "primary", eventId: "busy-1", title: "Team standup", start: "2026-03-02T15:00:00.000Z", end: "2026-03-02T16:00:00.000Z", allDay: false, status: "confirmed", attendees: [{ email: "me@example.org", self: true }, { email: "pat@example.org" }] } },
      { rawPayload: { schema: "org2:calendar-event:v1", calendarId: "primary", eventId: "acme-call", title: "Acme follow-up", start: "2026-03-03T16:00:00.000Z", end: "2026-03-03T16:30:00.000Z", allDay: false, status: "confirmed", htmlLink: "https://calendar.example/acme", attendees: [{ email: "me@example.org", self: true }, { email: "jane@acme.test" }, { email: "new@initech.test" }] } },
      { rawPayload: { schema: "org2:calendar-event:v1", calendarId: "primary", eventId: "gone", title: "Cancelled sync", start: "2026-03-03T18:00:00.000Z", end: "2026-03-03T18:30:00.000Z", allDay: false, status: "cancelled", attendees: [{ email: "jane@acme.test" }] } },
    ],
  }, null, 2)}\n`);

  write("raw/connectors/google-calendar/Work/primary--2026-02.json", `${JSON.stringify({
    schema: "org2:source-import:v1",
    records: [
      { rawPayload: { schema: "org2:calendar-event:v1", calendarId: "primary", eventId: "carol-coffee", title: "Coffee", start: "2026-02-18T17:00:00.000Z", end: "2026-02-18T17:30:00.000Z", allDay: false, status: "confirmed", attendees: [{ email: "me@example.org", self: true }, { email: "carol@acme.test" }] } },
    ],
  }, null, 2)}\n`);

  // The index joins notes, ledgers and tasks without any extra metadata.
  const index = crm(["list"]);
  assert.equal(index.schema, "org2:crm-index:v1");
  assert.deepEqual(index.stages, ["lead", "prospect", "opportunity", "customer", "partner", "former"]);
  const company = (title) => index.companies.find((item) => item.title === title);
  const person = (title) => index.people.find((item) => item.title === title);
  assert.equal(company("Acme Robotics").stage, "prospect");
  assert.equal(company("Acme Robotics").ledgerAccounts[0].match, "domain");
  assert.equal(company("Globex").ledgerAccounts[0].match, "name", "corporate suffixes are ignored when matching names");
  assert.equal(company("Globex").stage, "lead");
  assert.equal(company("Globex").stageSource, "ledger");
  assert.deepEqual(company("Globex").domains, ["globex.test"]);
  assert.equal(company("Initech").source, "ledger");
  assert.equal(person("Jane Doe").company.match, "email-domain");
  assert.equal(person("Carol King").company.match, "explicit");
  assert.equal(person("Bob Stone").company.match, "note-link");
  assert.equal(company("Acme Robotics").openTaskCount, 2, "own TODO plus the meeting TODO via Jane");
  assert.equal(company("Acme Robotics").nextTask.title, "Send pricing to Acme");
  // Last touch is direct contact; a mention by someone else is tracked separately.
  assert.equal(company("Acme Robotics").meetingCount, 3, "the demo, Jane's meeting and Carol's calendar event");
  assert.equal(company("Acme Robotics").lastTouchAt, "2026-02-20T17:00:00.000Z");
  assert.equal(company("Acme Robotics").lastTouchType, "meeting");
  assert.equal(company("Acme Robotics").lastMentionAt, "2026-02-27T17:00:00.000Z");
  assert.equal(company("Acme Robotics").lastMentionType, "meeting");
  assert.equal(company("Acme Robotics").lastInteractionAt, "2026-02-27T17:00:00.000Z");
  assert.equal(person("Jane Doe").meetingCount, 2, "a meeting titled with her name counts as attended");
  assert.equal(person("Carol King").lastTouchType, "calendar");
  assert.equal(person("Bob Stone").lastTouchAt, "2026-02-27T17:00:00.000Z", "a Participants: line lists attendees");
  assert.equal(company("Globex").lastTouchAt, "2026-02-27T17:00:00.000Z", "Bob's attendance touches his company");
  assert.equal(company("Globex").lastMentionType, "note");
  assert.equal(index.companies[0].title, "Globex", "lists sort by last touch");
  assert.equal(company("Globex").openTaskCount, 1, "a TODO's ACCOUNT property relates it by name");
  assert.equal(index.stats.ledgerAccounts, 3);
  assert.equal(index.stats.linkedLedgerAccounts, 2);
  assert.equal(crm(["list", "--kind", "companies", "--stage", "prospect"]).companies.length, 1);
  assert.equal(crm(["list", "--query", "acme.test"]).people.length, 2);

  // Detail view: timeline, tasks, outreach history and upcoming meetings.
  const acme = crm(["show", "Acme Robotics"]);
  assert.equal(acme.schema, "org2:crm-entity:v1");
  assert.ok(acme.revision.startsWith("sha256:"));
  const types = new Set(acme.timeline.map((item) => item.type));
  for (const type of ["meeting", "outreach", "calendar"]) assert.ok(types.has(type), `timeline includes ${type}`);
  const roles = Object.fromEntries(acme.timeline.filter((item) => item.type === "meeting").map((item) => [item.title, item.role]));
  assert.deepEqual(roles, { "Acme demo": "attended", "Jane Doe": "attended", "Quarterly sync": "mentioned" });
  assert.equal(acme.timeline.find((item) => item.key.startsWith("calendar:carol-coffee")).role, "attended");
  assert.equal(acme.tasks.filter((task) => task.open).length, 2);
  assert.equal(acme.upcoming.length, 1);
  assert.equal(crm(["show", "jane@acme.test"]).entity.title, "Jane Doe");
  assert.equal(crm(["show", "ledger:outreach/initech"]).entity.title, "Initech");
  const ambiguous = crm(["show", "nobody@nowhere.test"], { allowFailure: true });
  assert.notEqual(ambiguous.status, 0);

  // Reads reuse a snapshot until an input changes.
  assert.equal(crm(["warm"]).cached, true);
  assert.equal(crm(["list"]).cache.hit, true);
  const detailed = crm(["list", "--details"]);
  assert.equal(detailed.details[acme.entity.key].upcoming.length, 1);
  assert.ok(detailed.details[acme.entity.key].timeline.some((item) => item.type === "outreach"));
  write("notes/umbrella.org", `:PROPERTIES:\n:ID: 66666666-6666-4666-8666-666666666666\n:ORG2_ENTITY_TYPE: company\n:END:\n#+title: Umbrella\n`);
  const afterNew = crm(["list"]);
  assert.equal(afterNew.cache.hit, false, "a new note invalidates the snapshot");
  assert.ok(afterNew.companies.some((item) => item.title === "Umbrella"));
  assert.equal(crm(["list"]).cache.hit, true);
  fs.appendFileSync(path.join(corpus, "notes/umbrella.org"), "\nUmbrella makes [[id:${JANE}][Jane]] happy.\n".replace("${JANE}", JANE));
  assert.equal(crm(["list"]).cache.hit, false, "an edited note invalidates the snapshot");
  fs.rmSync(path.join(corpus, "notes/umbrella.org"));
  assert.ok(!crm(["list"]).companies.some((item) => item.title === "Umbrella"), "a removed note disappears");

  const resolved = crm(["resolve", "new@initech.test"]);
  assert.equal(resolved.matches[0].title, "Initech");
  assert.equal(resolved.matches[0].ledgerAccounts[0].id, "initech");

  // Upcoming meetings brief external attendees; self-domain and cancelled events are skipped.
  const upcoming = crm(["upcoming", "--days", "7"]);
  assert.equal(upcoming.meetings.length, 1);
  assert.equal(upcoming.meetings[0].event.title, "Acme follow-up");
  assert.deepEqual(upcoming.meetings[0].people.map((item) => item.title), ["Jane Doe"]);
  assert.deepEqual(upcoming.meetings[0].companies.map((item) => item.title).sort(), ["Acme Robotics", "Initech"]);
  assert.deepEqual(upcoming.meetings[0].unknownAttendees, ["new@initech.test"]);

  // Set a stage: preview, then apply.
  const before = read("notes/globex.org");
  const preview = crm(["set", "Globex", "--field", "stage", "--value", "Customer"]);
  assert.equal(preview.applied, false);
  assert.equal(read("notes/globex.org"), before);
  crm(["set", "Globex", "--field", "stage", "--value", "customer", "--apply"]);
  assert.match(read("notes/globex.org"), /:CRM_STAGE: customer/);
  crm(["set", "Bob Stone", "--field", "company", "--value", "Globex", "--apply"]);
  assert.match(read("notes/bob-stone.org"), new RegExp(`:COMPANY: \\[\\[id:${GLOBEX}\\]\\[Globex\\]\\]`));
  const stale = crm(["set", "Globex", "--field", "owner", "--value", "Avery", "--if-revision", "sha256:0"], { allowFailure: true });
  assert.notEqual(stale.status, 0, "stale revisions fail closed");

  // Follow-ups live in the company note itself.
  crm(["follow-up", "Globex", "--title", "Send renewal quote", "--scheduled", "2026-03-05", "--priority", "A", "--apply"]);
  assert.match(read("notes/globex.org"), /\* TODO \[#A\] Send renewal quote\nSCHEDULED: <2026-03-05 Thu>\n:PROPERTIES:\n:CREATED: \[2026-03-02 Mon\]\n:END:\n$/);
  assert.equal(crm(["list"]).companies.find((item) => item.title === "Globex").openTaskCount, 2);
  const ledgerOnlyFollowUp = crm(["follow-up", "Initech", "--title", "Call"], { allowFailure: true });
  assert.match(ledgerOnlyFollowUp.stderr, /create a company note first/);

  // Promote an outreach-only account into a company note linked to its ledger.
  const created = crm(["create", "company", "--from-ledger", "outreach/initech", "--stage", "lead", "--apply"]);
  assert.equal(created.file, "notes/initech.org");
  assert.match(read("notes/initech.org"), /:DOMAIN: initech.test/);
  assert.ok(loadWorkLedgerAccount(corpus, "outreach", "initech").account.identityKeys.includes(`org-id:${created.id}`));
  const initech = crm(["list"]).companies.find((item) => item.title === "Initech");
  assert.equal(initech.source, "note");
  assert.equal(initech.ledgerAccounts[0].match, "explicit");
  const duplicate = crm(["create", "company", "--title", "Initech"], { allowFailure: true });
  assert.match(duplicate.stderr, /already exists/);
  crm(["create", "person", "--title", "Dana Lee", "--email", "dana@initech.test", "--company", "Initech", "--apply"]);
  assert.equal(crm(["show", "dana@initech.test"]).entity.company.title, "Initech");

  // Link suggestions turn inferred matches into explicit, reviewable links.
  const links = crm(["link"]);
  const byType = (type) => links.proposals.filter((item) => item.type === type);
  assert.deepEqual(byType("ledger-company").map((item) => item.target.title).sort(), ["Acme Robotics", "Globex"]);
  assert.deepEqual(byType("person-company").map((item) => item.entity.title), ["Jane Doe"]);
  assert.deepEqual(byType("company-domain").map((item) => item.value), ["globex.test"]);
  assert.equal(links.applied, false);
  const one = byType("person-company")[0].id;
  const partial = crm(["link", "--only", one, "--apply"]);
  assert.deepEqual(partial.results, [{ id: one, applied: true }]);
  assert.match(read("notes/jane-doe.org"), new RegExp(`:COMPANY: \\[\\[id:${ACME}\\]`));
  const all = crm(["link", "--apply"]);
  assert.ok(all.results.every((item) => item.applied), JSON.stringify(all.results));
  assert.equal(crm(["link"]).proposals.length, 0, "applied links are not proposed again");
  assert.ok(loadWorkLedgerAccount(corpus, "outreach", "acme").account.identityKeys.includes(`org-id:${ACME}`));
  assert.match(read("notes/globex.org"), /:DOMAIN: globex.test/);
  assert.equal(crm(["link", "--only", "deadbeef0000"], { allowFailure: true }).status !== 0, true);

  // Scheduling proposes free calendar slots and rewrites only SCHEDULED lines.
  const plan = crm(["schedule", "--days", "5"]);
  assert.equal(plan.proposals[0].task.title, "Check Globex contract");
  assert.equal(plan.proposals[0].timestamp, "<2026-03-02 Mon 16:00-16:30>", "the standup is busy until 16:00");
  assert.equal(plan.proposals[1].timestamp, "<2026-03-02 Mon 16:30-17:00>");
  assert.equal(plan.applied, false);
  const dailyBefore = read("daily/2026-02-25.org");
  assert.match(dailyBefore, /SCHEDULED: <2026-03-02 Mon>\n/);
  const applied = crm(["schedule", "--days", "5", "--only", plan.proposals[0].task.key, "--apply"]);
  assert.deepEqual(applied.results.map((item) => item.applied), [true]);
  assert.equal(read("daily/2026-02-25.org"), dailyBefore.replace("SCHEDULED: <2026-03-02 Mon>", "SCHEDULED: <2026-03-02 Mon 16:00-16:30>"));
  const replanned = crm(["schedule", "--days", "5"]);
  assert.ok(!replanned.proposals.some((item) => item.task.title === "Check Globex contract"), "timed tasks are not rescheduled");
  assert.equal(replanned.proposals[0].timestamp, "<2026-03-02 Mon 16:30-17:00>", "a timed task counts as busy");

  // Help is discoverable.
  const help = spawnSync("node", ["dist/cli.js", "crm", "--help"], { cwd: repo, encoding: "utf8" });
  assert.match(help.stdout, /People & Companies/);
  console.log("OK: crm");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
