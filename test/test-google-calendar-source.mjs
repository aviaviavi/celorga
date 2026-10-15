#!/usr/bin/env node
// Google Calendar as an external sync source: configuration validation, the
// app-provided refresh credential, Calendar API paging, event normalization,
// and snapshot staging through the shared import pipeline. Uses a local fake
// Google token endpoint and Calendar API.
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import {
  googleCalendarSourceSettings,
  normalizeGoogleCalendarEvent,
  parseGoogleCalendarCredential,
} from "../dist/googleCalendarSource.js";
import { validateExternalSourceProfile } from "../dist/sourceRuntime.js";

const repo = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), "org2-google-calendar-source-"));
const corpus = path.join(root, "corpus");
const indexHome = path.join(root, "index");
fs.mkdirSync(corpus, { recursive: true });

// Settings and validation.
assert.deepEqual(googleCalendarSourceSettings("cal", { type: "google-calendar" }), { calendars: ["primary"], lookaheadDays: 14, lookback: "1d" });
assert.throws(() => googleCalendarSourceSettings("cal", { type: "google-calendar", googleCalendar: { lookaheadDays: 400 } }), /lookaheadDays/);
assert.throws(() => googleCalendarSourceSettings("cal", { type: "google-calendar", googleCalendar: { calendars: [] } }), /calendars/);
assert.throws(() => googleCalendarSourceSettings("cal", { type: "google-calendar", googleCalendar: { extra: 1 } }), /unknown key extra/);
assert.throws(() => validateExternalSourceProfile("cal", { type: "google-calendar", googleCalendar: { refreshToken: "x" } }), /credentials stay machine-local/);
assert.throws(() => validateExternalSourceProfile("mail", { type: "email", email: { host: "imap.example.com", username: "a" }, googleCalendar: {} }), /apply only to type google-calendar/);
assert.equal(validateExternalSourceProfile("cal", { type: "google-calendar", googleCalendar: { calendars: ["primary", "team@example.com"], lookaheadDays: 7 } }).type, "google-calendar");

// Credentials.
assert.equal(parseGoogleCalendarCredential(""), null);
assert.throws(() => parseGoogleCalendarCredential("{"), /not valid JSON/);
assert.throws(() => parseGoogleCalendarCredential(JSON.stringify({ clientId: "c" })), /refresh token/);
assert.deepEqual(parseGoogleCalendarCredential(JSON.stringify({ schema: "org2:google-oauth-credential:v1", clientId: "c", clientSecret: "s", refreshToken: "r" })), { clientId: "c", clientSecret: "s", refreshToken: "r" });

// Normalization.
const normalized = normalizeGoogleCalendarEvent("primary", {
  id: "evt1",
  summary: "Design review",
  description: "<p>Agenda&amp;notes</p><br>Bring <b>mocks</b>",
  start: { dateTime: "2026-10-15T10:00:00-07:00" },
  end: { dateTime: "2026-10-15T10:30:00-07:00" },
  hangoutLink: "https://meet.google.com/abc-defg-hij",
  conferenceData: { entryPoints: [{ entryPointType: "phone", uri: "tel:+1" }, { entryPointType: "video", uri: "https://zoom.us/j/1" }] },
  organizer: { email: "Ada@Example.com", displayName: "Ada" },
  attendees: [
    { email: "ada@example.com", displayName: "Ada Lovelace", organizer: true, responseStatus: "accepted" },
    { email: "avi@example.com", self: true, responseStatus: "needsAction" },
    { email: "room-1@resource.calendar.google.com", resource: true },
  ],
});
assert.equal(normalized.start, "2026-10-15T17:00:00.000Z");
assert.equal(normalized.meetingUrl, "https://zoom.us/j/1");
assert.equal(normalized.description, "Agenda&notes\n\nBring mocks");
assert.equal(normalized.selfResponse, "needsAction");
assert.equal(normalized.organizer.email, "ada@example.com");
assert.deepEqual(normalized.attendees.map((attendee) => attendee.email), ["ada@example.com", "avi@example.com"]);
assert.equal(normalizeGoogleCalendarEvent("primary", { id: "allday", start: { date: "2026-10-16" }, end: { date: "2026-10-17" } }).allDay, true);
assert.equal(normalizeGoogleCalendarEvent("primary", { summary: "no id" }), null);

// Fake Google.
const now = Date.now();
const iso = (offsetMinutes) => new Date(now + offsetMinutes * 60_000).toISOString();
const requests = [];
let refreshCount = 0;
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  requests.push({ method: request.method, path: url.pathname, query: Object.fromEntries(url.searchParams), auth: request.headers.authorization });
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    response.setHeader("Content-Type", "application/json");
    if (url.pathname === "/token") {
      const fields = new URLSearchParams(body);
      if (fields.get("refresh_token") !== "refresh-good" || fields.get("client_id") !== "client.apps.googleusercontent.com" || fields.get("client_secret") !== "shh") {
        response.statusCode = 400;
        response.end(JSON.stringify({ error: "invalid_grant", error_description: "Token has been expired or revoked." }));
        return;
      }
      refreshCount += 1;
      response.end(JSON.stringify({ access_token: `access-${refreshCount}`, expires_in: 3599, token_type: "Bearer" }));
      return;
    }
    if (url.pathname === "/calendar/v3/calendars/primary/events") {
      if (!request.headers.authorization?.startsWith("Bearer access-")) {
        response.statusCode = 401;
        response.end(JSON.stringify({ error: { code: 401, message: "Invalid Credentials" } }));
        return;
      }
      assert.equal(url.searchParams.get("singleEvents"), "true");
      if (!url.searchParams.get("pageToken")) {
        response.end(JSON.stringify({
          summary: "avi@example.com",
          nextPageToken: "page-2",
          items: [
            {
              id: "standup",
              summary: "Standup",
              start: { dateTime: iso(2) },
              end: { dateTime: iso(17) },
              hangoutLink: "https://meet.google.com/abc",
              attendees: [
                { email: "avi@example.com", self: true, responseStatus: "accepted" },
                { email: "ada@example.com", displayName: "Ada Lovelace", responseStatus: "accepted" },
              ],
            },
            { id: "gone", status: "cancelled", summary: "Cancelled", start: { dateTime: iso(30) }, end: { dateTime: iso(60) } },
          ],
        }));
      } else {
        response.end(JSON.stringify({
          summary: "avi@example.com",
          items: [{ id: "planning", summary: "Planning", start: { dateTime: iso(24 * 60) }, end: { dateTime: iso(25 * 60) } }],
        }));
      }
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: { message: "not found" } }));
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

function run(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(repo, "dist/cli.js"), ...args, "--dir", corpus], {
      env: {
        ...process.env,
        ORG2_INDEX_HOME: indexHome,
        ORG2_GOOGLE_CALENDAR_CREDENTIAL: "",
        ORG2_GOOGLE_CALENDAR_ACCESS_TOKEN: "",
        ORG2_GOOGLE_OAUTH_TOKEN_ENDPOINT: `${base}/token`,
        ORG2_GOOGLE_CALENDAR_API_BASE: `${base}/calendar/v3`,
        ...env,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

try {
  fs.writeFileSync(path.join(corpus, "celorga.json"), JSON.stringify({ corpus: { id: "calendar-test" } }, null, 2));
  const add = await run(["source", "add", "cal", "--source-json", JSON.stringify({ type: "google-calendar", enabled: true, googleCalendar: { lookaheadDays: 7 } }), "--apply", "--json"]);
  assert.equal(add.status, 0, add.stderr);
  assert.match(JSON.parse(add.stdout).next, /Sign in with Google/);

  const list = await run(["source", "list", "--json"]);
  assert.equal(list.status, 0, list.stderr);
  const [status] = JSON.parse(list.stdout);
  assert.equal(status.type, "google-calendar");
  assert.equal(status.ready, true);
  assert.equal(status.credentialAvailable, false);
  assert.deepEqual(status.googleCalendar, { calendars: ["primary"], lookaheadDays: 7 });
  assert.equal(status.rawZone, "raw/connectors/google-calendar/cal");

  // Without a credential the sync fails with an actionable message.
  const missing = await run(["source", "sync", "cal", "--ingest", "--apply", "--json"]);
  assert.equal(missing.status, 1);
  assert.match(JSON.parse(missing.stdout).results[0].error, /Sign in|sign in/);

  // A revoked refresh credential asks for a new sign-in.
  const revoked = await run(["source", "sync", "cal", "--ingest", "--apply", "--json"], {
    ORG2_GOOGLE_CALENDAR_CREDENTIAL: JSON.stringify({ clientId: "client.apps.googleusercontent.com", clientSecret: "shh", refreshToken: "refresh-bad" }),
  });
  assert.equal(revoked.status, 1);
  assert.match(JSON.parse(revoked.stdout).results[0].error, /expired or revoked.*sign in again/);

  const credential = JSON.stringify({ schema: "org2:google-oauth-credential:v1", clientId: "client.apps.googleusercontent.com", clientSecret: "shh", refreshToken: "refresh-good" });
  const doctor = await run(["source", "doctor", "cal", "--json"], { ORG2_GOOGLE_CALENDAR_CREDENTIAL: credential });
  assert.equal(doctor.status, 0, doctor.stdout + doctor.stderr);

  const preview = await run(["source", "sync", "cal", "--ingest", "--json"], { ORG2_GOOGLE_CALENDAR_CREDENTIAL: credential });
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(fs.existsSync(path.join(corpus, "raw/connectors/google-calendar/cal")), false, "preview writes nothing");

  const sync = await run(["source", "sync", "cal", "--ingest", "--apply", "--json"], { ORG2_GOOGLE_CALENDAR_CREDENTIAL: credential });
  assert.equal(sync.status, 0, sync.stderr);
  const result = JSON.parse(sync.stdout).results[0];
  assert.equal(result.ok, true);
  assert.equal(result.imported.acceptedCount, 2, "cancelled events are dropped; paging is followed");
  assert.deepEqual(result.calendars, [{ id: "primary", name: "avi@example.com", events: 2 }]);
  const eventRequests = requests.filter((request) => request.path.endsWith("/events"));
  assert.equal(eventRequests.at(-1).query.pageToken, "page-2");
  const windowDays = (Date.parse(eventRequests[0].query.timeMax) - Date.parse(eventRequests[0].query.timeMin)) / 86_400_000;
  assert.ok(Math.abs(windowDays - 8) < 0.01, `1d back + 7d ahead, got ${windowDays}`);

  const rawFiles = fs.readdirSync(path.join(corpus, "raw/connectors/google-calendar/cal"));
  assert.ok(rawFiles.length >= 1);
  const staged = rawFiles.flatMap((name) => JSON.parse(fs.readFileSync(path.join(corpus, "raw/connectors/google-calendar/cal", name), "utf8")).records);
  const standup = staged.find((record) => record.rawPayload.eventId === "standup");
  assert.equal(standup.source.kind, "calendar");
  assert.equal(standup.rawPayload.schema, "org2:calendar-event:v1");
  assert.equal(standup.rawPayload.meetingUrl, "https://meet.google.com/abc");
  assert.deepEqual(standup.source.participants, ["avi@example.com", "Ada Lovelace <ada@example.com>"]);
  const review = fs.readdirSync(path.join(corpus, "views/connectors/google-calendar/cal"));
  assert.ok(review.length >= 1);
  const corpusText = fs.readdirSync(corpus, { recursive: true })
    .filter((name) => fs.statSync(path.join(corpus, name)).isFile())
    .map((name) => fs.readFileSync(path.join(corpus, name), "utf8")).join("\n");
  assert.equal(corpusText.includes("refresh-good"), false, "the refresh credential never enters the corpus");
  assert.equal(corpusText.includes("access-"), false, "the access token never enters the corpus");

  const runtime = await run(["source", "status", "cal", "--json"]);
  assert.equal(runtime.status, 0, runtime.stderr);
  const runtimeStatus = JSON.parse(runtime.stdout).sources[0];
  assert.equal(runtimeStatus.crawlerStatus.state, "synced");
  assert.ok(runtimeStatus.crawlerStatus.last_sync_at);
  assert.equal(runtimeStatus.crawlerStatus.database_path.startsWith(corpus), false, "sync state is machine-local");

  // A direct access token skips the refresh.
  const before = refreshCount;
  const direct = await run(["source", "sync", "cal", "--ingest", "--apply", "--json"], { ORG2_GOOGLE_CALENDAR_ACCESS_TOKEN: "access-direct" });
  assert.equal(direct.status, 0, direct.stderr);
  assert.equal(refreshCount, before);
  console.log("google calendar source tests passed");
} finally {
  server.close();
  fs.rmSync(root, { recursive: true, force: true });
}
