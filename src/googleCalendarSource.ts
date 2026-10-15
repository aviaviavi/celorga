import type { Org2ExternalSourceConfig } from "./config.js";
import type { AgentIngestRecord } from "./agentIngestConnectors.js";

/**
 * Google Calendar external source. The Celorga app signs in on a Mac and hands
 * the resulting refresh credential to whichever host syncs (normally the
 * connected server) through an environment variable; it never enters the corpus.
 */

export const GOOGLE_CALENDAR_CREDENTIAL_ENV = "ORG2_GOOGLE_CALENDAR_CREDENTIAL";
export const GOOGLE_CALENDAR_ACCESS_TOKEN_ENV = "ORG2_GOOGLE_CALENDAR_ACCESS_TOKEN";
export const GOOGLE_CALENDAR_CREDENTIAL_SCHEMA = "org2:google-oauth-credential:v1";
export const GOOGLE_CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events.readonly";

const DEFAULT_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const DEFAULT_API_BASE = "https://www.googleapis.com/calendar/v3";
const DEFAULT_LOOKAHEAD_DAYS = 14;
const DEFAULT_LOOKBACK = "1d";
const MAX_EVENTS_PER_CALENDAR = 2_500;

export interface GoogleCalendarSourceSettings {
  calendars: string[];
  lookaheadDays: number;
  /** Relative window such as 1d or 2w (matches ingestion.since). */
  lookback: string;
}

export interface GoogleCalendarCredential {
  clientId: string;
  clientSecret?: string;
  refreshToken: string;
}

export function googleCalendarSourceSettings(id: string, profile: Org2ExternalSourceConfig): GoogleCalendarSourceSettings {
  const raw = profile.googleCalendar;
  if (raw !== undefined && (!raw || typeof raw !== "object" || Array.isArray(raw))) {
    throw new Error(`external source ${id} googleCalendar must be an object`);
  }
  for (const key of Object.keys(raw || {})) {
    if (!["calendars", "lookaheadDays"].includes(key)) throw new Error(`external source ${id} googleCalendar has unknown key ${key}`);
  }
  const calendars = raw?.calendars ?? ["primary"];
  if (!Array.isArray(calendars) || !calendars.length || calendars.some((value) => typeof value !== "string" || !value.trim())) {
    throw new Error(`external source ${id} googleCalendar.calendars must be a non-empty list of calendar IDs`);
  }
  const lookaheadDays = raw?.lookaheadDays ?? DEFAULT_LOOKAHEAD_DAYS;
  if (!Number.isInteger(lookaheadDays) || lookaheadDays < 1 || lookaheadDays > 90) {
    throw new Error(`external source ${id} googleCalendar.lookaheadDays must be an integer from 1 to 90`);
  }
  const lookback = profile.ingestion?.since?.trim() || DEFAULT_LOOKBACK;
  if (!/^\d+[dhwm]$/i.test(lookback)) {
    throw new Error(`external source ${id} ingestion.since must be a relative window such as 1d for Google Calendar`);
  }
  return { calendars: calendars.map((value) => value.trim()), lookaheadDays, lookback };
}

/** Parses the credential the Celorga app stores; returns null when absent. */
export function parseGoogleCalendarCredential(value: string | undefined): GoogleCalendarCredential | null {
  const text = value?.trim();
  if (!text) return null;
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new Error(`${GOOGLE_CALENDAR_CREDENTIAL_ENV} is not valid JSON; sign in to Google Calendar again from the Celorga app`);
  }
  const clientId = typeof parsed.clientId === "string" ? parsed.clientId.trim() : "";
  const refreshToken = typeof parsed.refreshToken === "string" ? parsed.refreshToken.trim() : "";
  const clientSecret = typeof parsed.clientSecret === "string" ? parsed.clientSecret.trim() : "";
  if (!clientId || !refreshToken) {
    throw new Error(`${GOOGLE_CALENDAR_CREDENTIAL_ENV} is missing its client ID or refresh token; sign in to Google Calendar again`);
  }
  return { clientId, refreshToken, ...(clientSecret ? { clientSecret } : {}) };
}

export function googleCalendarCredentialAvailable(env: NodeJS.ProcessEnv = process.env): boolean {
  return Boolean(env[GOOGLE_CALENDAR_ACCESS_TOKEN_ENV]?.trim() || env[GOOGLE_CALENDAR_CREDENTIAL_ENV]?.trim());
}

async function fetchJSON(url: string, init: RequestInit, timeoutMs: number): Promise<Record<string, unknown>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetch(url, { ...init, signal: controller.signal });
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`Google request timed out after ${timeoutMs / 1_000} seconds`);
    throw new Error(`Google request failed: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    clearTimeout(timer);
  }
  const text = await response.text();
  let body: Record<string, unknown> = {};
  try { body = text ? JSON.parse(text) as Record<string, unknown> : {}; } catch { /* reported below */ }
  if (!response.ok) {
    const error = body.error;
    const detail = typeof error === "string"
      ? [error, body.error_description].filter((value) => typeof value === "string").join(": ")
      : error && typeof error === "object" && typeof (error as Record<string, unknown>).message === "string"
        ? (error as Record<string, unknown>).message as string
        : text.slice(0, 300);
    throw new Error(`Google returned HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
  }
  return body;
}

/** Resolves a short-lived access token from the environment, refreshing when needed. */
export async function googleCalendarAccessToken(env: NodeJS.ProcessEnv = process.env, timeoutMs = 30_000): Promise<string> {
  const direct = env[GOOGLE_CALENDAR_ACCESS_TOKEN_ENV]?.trim();
  if (direct) return direct;
  const credential = parseGoogleCalendarCredential(env[GOOGLE_CALENDAR_CREDENTIAL_ENV]);
  if (!credential) {
    throw new Error(`no Google Calendar credential: sign in from the Celorga app's Sources view (it sends the credential to the connected server), or set ${GOOGLE_CALENDAR_CREDENTIAL_ENV}`);
  }
  const fields = new URLSearchParams({
    client_id: credential.clientId,
    grant_type: "refresh_token",
    refresh_token: credential.refreshToken,
    ...(credential.clientSecret ? { client_secret: credential.clientSecret } : {}),
  });
  const body = await fetchJSON(env.ORG2_GOOGLE_OAUTH_TOKEN_ENDPOINT?.trim() || DEFAULT_TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: fields.toString(),
  }, timeoutMs).catch((error: Error) => {
    throw new Error(`could not refresh the Google Calendar sign-in (${error.message}); sign in again from the Celorga app`);
  });
  const token = typeof body.access_token === "string" ? body.access_token : "";
  if (!token) throw new Error("Google returned no access token; sign in to Google Calendar again");
  return token;
}

type GoogleAttendee = {
  email?: string;
  displayName?: string;
  responseStatus?: string;
  self?: boolean;
  organizer?: boolean;
  optional?: boolean;
  resource?: boolean;
};

type GoogleEvent = {
  id?: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  htmlLink?: string;
  hangoutLink?: string;
  iCalUID?: string;
  recurringEventId?: string;
  updated?: string;
  eventType?: string;
  start?: { dateTime?: string; date?: string; timeZone?: string };
  end?: { dateTime?: string; date?: string; timeZone?: string };
  organizer?: { email?: string; displayName?: string; self?: boolean };
  attendees?: GoogleAttendee[];
  conferenceData?: { entryPoints?: Array<{ entryPointType?: string; uri?: string }> };
};

/** The event fields Celorga keeps; the app reads these to prompt for recording. */
export interface GoogleCalendarEventPayload {
  schema: "org2:calendar-event:v1";
  calendarId: string;
  eventId: string;
  iCalUID?: string;
  recurringEventId?: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  status: string;
  location?: string;
  description?: string;
  htmlLink?: string;
  meetingUrl?: string;
  organizer?: { email?: string; name?: string; self?: boolean };
  /** The signed-in account's own response, when it is an attendee. */
  selfResponse?: string;
  attendees: Array<{ email?: string; name?: string; response?: string; organizer?: boolean; optional?: boolean; self?: boolean }>;
  updated?: string;
}

function clean(value: unknown, max = 4_000): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, max) : undefined;
}

function plainDescription(value: string | undefined): string | undefined {
  if (!value) return undefined;
  // Google stores descriptions as light HTML.
  const text = value
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return text ? text.slice(0, 4_000) : undefined;
}

function allDayISO(date: string): string {
  return `${date}T00:00:00.000Z`;
}

export function normalizeGoogleCalendarEvent(calendarId: string, event: GoogleEvent): GoogleCalendarEventPayload | null {
  const eventId = clean(event.id, 1_024);
  if (!eventId) return null;
  const startRaw = event.start?.dateTime || event.start?.date;
  const endRaw = event.end?.dateTime || event.end?.date || startRaw;
  if (!startRaw || !endRaw) return null;
  const allDay = !event.start?.dateTime;
  const start = allDay ? allDayISO(startRaw) : new Date(startRaw).toISOString();
  const end = allDay ? allDayISO(endRaw) : new Date(endRaw).toISOString();
  if (!Number.isFinite(Date.parse(start)) || !Number.isFinite(Date.parse(end))) return null;
  const attendees = (event.attendees || [])
    .filter((attendee) => !attendee.resource)
    .map((attendee) => ({
      ...(clean(attendee.email, 320) ? { email: clean(attendee.email, 320)!.toLowerCase() } : {}),
      ...(clean(attendee.displayName, 200) ? { name: clean(attendee.displayName, 200) } : {}),
      ...(clean(attendee.responseStatus, 40) ? { response: clean(attendee.responseStatus, 40) } : {}),
      ...(attendee.organizer ? { organizer: true } : {}),
      ...(attendee.optional ? { optional: true } : {}),
      ...(attendee.self ? { self: true } : {}),
    }))
    .filter((attendee) => attendee.email || attendee.name);
  const video = event.conferenceData?.entryPoints?.find((entry) => entry.entryPointType === "video")?.uri;
  const selfAttendee = (event.attendees || []).find((attendee) => attendee.self);
  const organizer = event.organizer
    ? {
      ...(clean(event.organizer.email, 320) ? { email: clean(event.organizer.email, 320)!.toLowerCase() } : {}),
      ...(clean(event.organizer.displayName, 200) ? { name: clean(event.organizer.displayName, 200) } : {}),
      ...(event.organizer.self ? { self: true } : {}),
    }
    : undefined;
  return {
    schema: "org2:calendar-event:v1",
    calendarId,
    eventId,
    ...(clean(event.iCalUID, 1_024) ? { iCalUID: clean(event.iCalUID, 1_024) } : {}),
    ...(clean(event.recurringEventId, 1_024) ? { recurringEventId: clean(event.recurringEventId, 1_024) } : {}),
    title: clean(event.summary, 500) || "(no title)",
    start,
    end,
    allDay,
    status: clean(event.status, 40) || "confirmed",
    ...(clean(event.location, 500) ? { location: clean(event.location, 500) } : {}),
    ...(plainDescription(event.description) ? { description: plainDescription(event.description) } : {}),
    ...(clean(event.htmlLink, 2_048) ? { htmlLink: clean(event.htmlLink, 2_048) } : {}),
    ...(clean(video || event.hangoutLink, 2_048) ? { meetingUrl: clean(video || event.hangoutLink, 2_048) } : {}),
    ...(organizer && Object.keys(organizer).length ? { organizer } : {}),
    ...(clean(selfAttendee?.responseStatus, 40) ? { selfResponse: clean(selfAttendee?.responseStatus, 40) } : {}),
    attendees,
    ...(clean(event.updated, 64) ? { updated: clean(event.updated, 64) } : {}),
  };
}

function attendeeLabel(attendee: { email?: string; name?: string }): string {
  if (attendee.name && attendee.email) return `${attendee.name} <${attendee.email}>`;
  return attendee.name || attendee.email || "";
}

export function googleCalendarEventRecord(payload: GoogleCalendarEventPayload, calendarName: string): AgentIngestRecord {
  const lines = [
    `${payload.title}`,
    payload.allDay ? `All day: ${payload.start.slice(0, 10)}` : `When: ${payload.start} – ${payload.end}`,
    ...(payload.location ? [`Where: ${payload.location}`] : []),
    ...(payload.meetingUrl ? [`Meeting link: ${payload.meetingUrl}`] : []),
    ...(payload.attendees.length ? [`Attendees: ${payload.attendees.map(attendeeLabel).join(", ")}`] : []),
    ...(payload.description ? ["", payload.description] : []),
  ];
  return {
    id: `google-calendar:${payload.calendarId}:${payload.eventId}`,
    title: payload.title,
    text: lines.join("\n"),
    source: {
      kind: "calendar",
      service: "google-calendar",
      label: payload.calendarId,
      sourceName: calendarName,
      conversationId: payload.eventId,
      conversationTitle: payload.title,
      startedAt: payload.start,
      endedAt: payload.end,
      participants: payload.attendees.map(attendeeLabel),
      ...(payload.htmlLink ? { url: payload.htmlLink } : {}),
      ...(payload.organizer ? { author: attendeeLabel(payload.organizer) } : {}),
      timestamp: payload.start,
    },
    rawPayload: payload,
  };
}

export interface GoogleCalendarFetchOptions {
  settings: GoogleCalendarSourceSettings;
  accessToken: string;
  now?: Date;
  timeoutMs?: number;
  env?: NodeJS.ProcessEnv;
}

export interface GoogleCalendarFetchResult {
  records: AgentIngestRecord[];
  calendars: Array<{ id: string; name: string; events: number }>;
  window: { start: string; end: string };
}

function lookbackMilliseconds(value: string): number {
  const match = value.match(/^(\d+)([dhwm])$/i)!;
  return Number(match[1]) * ({ m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 }[match[2]!.toLowerCase() as "m" | "h" | "d" | "w"]);
}

export async function fetchGoogleCalendarRecords(options: GoogleCalendarFetchOptions): Promise<GoogleCalendarFetchResult> {
  const now = options.now ?? new Date();
  const env = options.env ?? process.env;
  const timeoutMs = options.timeoutMs ?? 60_000;
  const base = (env.ORG2_GOOGLE_CALENDAR_API_BASE?.trim() || DEFAULT_API_BASE).replace(/\/+$/, "");
  const start = new Date(now.getTime() - lookbackMilliseconds(options.settings.lookback));
  const end = new Date(now.getTime() + options.settings.lookaheadDays * 86_400_000);
  const records: AgentIngestRecord[] = [];
  const calendars: GoogleCalendarFetchResult["calendars"] = [];
  for (const calendarId of options.settings.calendars) {
    let pageToken: string | undefined;
    let name = calendarId;
    let count = 0;
    do {
      const query = new URLSearchParams({
        timeMin: start.toISOString(),
        timeMax: end.toISOString(),
        singleEvents: "true",
        orderBy: "startTime",
        maxResults: "250",
        ...(pageToken ? { pageToken } : {}),
      });
      const body = await fetchJSON(`${base}/calendars/${encodeURIComponent(calendarId)}/events?${query}`, {
        headers: { Authorization: `Bearer ${options.accessToken}`, Accept: "application/json" },
      }, timeoutMs);
      if (typeof body.summary === "string" && body.summary.trim()) name = body.summary.trim();
      for (const item of Array.isArray(body.items) ? body.items as GoogleEvent[] : []) {
        const payload = normalizeGoogleCalendarEvent(calendarId, item);
        if (!payload || payload.status === "cancelled") continue;
        records.push(googleCalendarEventRecord(payload, name));
        count += 1;
      }
      pageToken = typeof body.nextPageToken === "string" && body.nextPageToken ? body.nextPageToken : undefined;
    } while (pageToken && count < MAX_EVENTS_PER_CALENDAR);
    for (const record of records) if (record.source.label === calendarId) record.source.sourceName = name;
    calendars.push({ id: calendarId, name, events: count });
  }
  return { records, calendars, window: { start: start.toISOString(), end: end.toISOString() } };
}
