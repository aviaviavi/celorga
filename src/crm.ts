import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { configFilePath } from "./brandNames.js";
import { formatOrgDateTimestamp } from "./calendarDate.js";
import { configPathMatches, loadConfig, type Org2Config } from "./config.js";
import { compileCorpusIncremental, type CompiledCorpus, type CompiledCorpusNode } from "./corpusCompile.js";
import { guardedContentRevision, guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { org2CorpusIndexDir } from "./indexPaths.js";
import { updatePlanningInText } from "./planning.js";
import { editPropertyViewSource } from "./propertyViews.js";
import { isPlanningLine } from "./sourceLines.js";
import {
  acquireWorkLedgerMutationLock,
  listWorkLedgerAccounts,
  loadWorkLedgerAccount,
  parseWorkLedgerAccount,
  saveWorkLedgerAccount,
  summarizeWorkLedgerAccount,
  updateWorkLedgerAccount,
  validateWorkLedgerAccount,
} from "./workLedger.js";

/**
 * People & Companies: a CRM view computed from ordinary corpus records.
 *
 * Nothing here is a second database. People and companies are entity notes
 * (`:ORG2_ENTITY_TYPE: person|company`), relationship stage and contact
 * details are ordinary properties, tasks are TODO headings, meetings are
 * meeting headings, outreach history comes from work-ledger accounts, and
 * upcoming meetings come from staged calendar events under raw/. Every write
 * previews first and is revision guarded.
 */
export const CRM_INDEX_SCHEMA = "org2:crm-index:v1" as const;
export const CRM_ENTITY_SCHEMA = "org2:crm-entity:v1" as const;
export const DEFAULT_CRM_STAGES = ["lead", "prospect", "opportunity", "customer", "partner", "former"] as const;
/** Identity key a ledger account carries once it is linked to a company note. */
export const CRM_LEDGER_COMPANY_KEY_PREFIX = "org-id:";

export type CrmEntityKind = "person" | "company";
export type CrmMatch = "explicit" | "property" | "domain" | "email" | "email-domain" | "note-link" | "name";

export interface CrmTask {
  key: string;
  title: string;
  todo: string;
  open: boolean;
  priority?: string;
  scheduled?: string;
  deadline?: string;
  closed?: string;
  file: string;
  line: number;
  revision?: string;
  via?: string;
}

export interface CrmTimelineItem {
  key: string;
  type: "meeting" | "task" | "mention" | "outreach" | "calendar";
  title: string;
  at?: string;
  file?: string;
  line?: number;
  detail?: string;
  via?: string;
  url?: string;
  /** For meetings and mentions: whether the entity took part or was only brought up. */
  role?: "attended" | "mentioned";
}

export interface CrmLedgerRef {
  ledger: string;
  id: string;
  title: string;
  state: string;
  workStatus?: string;
  lastContactAt?: string;
  lastEventAt?: string;
  nextFollowUpAt?: string;
  eventCount: number;
  file: string;
  match: CrmMatch;
}

export interface CrmEntitySummary {
  key: string;
  kind: CrmEntityKind;
  source: "note" | "ledger";
  id: string | null;
  title: string;
  aliases: string[];
  file: string | null;
  line: number | null;
  nodeKind: "file" | "heading" | null;
  stage: string;
  stageSource: "property" | "ledger" | "";
  emails: string[];
  domains: string[];
  role: string;
  owner: string;
  company?: { key: string; title: string; match: CrmMatch };
  people: Array<{ key: string; title: string }>;
  ledgerAccounts: CrmLedgerRef[];
  openTaskCount: number;
  nextTask?: CrmTask;
  /** Meetings and calendar events the person or company took part in. */
  meetingCount: number;
  /** Meetings and notes that only brought them up. */
  mentionCount: number;
  /** Most recent activity of either kind. */
  lastInteractionAt?: string;
  lastInteractionType?: string;
  /** Most recent direct contact: an attended meeting or calendar event, or sent or received outreach. */
  lastTouchAt?: string;
  lastTouchType?: "meeting" | "calendar" | "outreach";
  /** Most recent time someone else brought them up in a meeting or note. */
  lastMentionAt?: string;
  lastMentionType?: "meeting" | "note";
  nextFollowUpAt?: string;
}

export interface CrmIndexOptions {
  now?: Date;
  /** Directory for the disposable compile and ledger caches; defaults to the machine-local corpus index. */
  cacheDir?: string;
}

const PERSON_TYPES = new Set(["person", "people", "contact", "individual"]);
const COMPANY_TYPES = new Set(["company", "organization", "organisation", "org", "business", "customer"]);
const RELATION_KEYS = ["COMPANY", "ACCOUNT", "ORGANIZATION", "ORGANISATION", "CUSTOMER", "CLIENT", "PERSON", "PEOPLE", "CONTACT", "CONTACTS", "ATTENDEES", "PARTICIPANTS", "WITH", "AFFILIATION", "EMPLOYER"];
const MEETING_ATTENDEE_KEYS = ["ATTENDEES", "PARTICIPANTS", "WITH", "PERSON", "PEOPLE", "CONTACT", "CONTACTS", "COMPANY", "ACCOUNT", "ORGANIZATION", "ORGANISATION", "CUSTOMER", "CLIENT"];
const ATTENDEE_SECTION = /^(?:attendees|participants|people|present|who)$/i;
const ATTENDEE_LINE = /\b(?:participants|attendees|attended by|present)\s*:\s*(.*)$/i;
const MEETING_WORDS = /\b(?:sync|call|meeting|demo|intro|introduction|follow[- ]?up|check[- ]?in|catch[- ]?up|review|weekly|bi-?weekly|monthly|chat|discussion|1:1|one[- ]on[- ]one)\b/gi;
const PERSON_COMPANY_KEYS = ["COMPANY", "ORGANIZATION", "ORGANISATION", "AFFILIATION", "EMPLOYER", "ACCOUNT"];
const FREE_MAIL = new Set([
  "gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "hotmail.com", "outlook.com", "live.com", "msn.com",
  "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "fastmail.com", "hey.com",
  "gmx.com", "gmx.net", "yandex.com", "zoho.com", "mail.com", "qq.com", "163.com",
]);
const CORPORATE_SUFFIXES = new Set(["inc", "incorporated", "llc", "ltd", "limited", "corp", "corporation", "co", "company", "gmbh", "plc", "sa", "ag", "bv", "oy", "ab", "pty", "srl", "sas"]);
const EMAIL_PATTERN = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const ID_LINK_PATTERN = /\[\[id:([^\]\s]+)\](?:\[([^\]]*)\])?\]/gi;

// MARK: - Small helpers

function sha(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function normalizeCrmName(value: string): string {
  const words = String(value || "")
    .replace(/\[\[[^\]]*\]\[([^\]]*)\]\]/g, "$1")
    .replace(/\[\[([^\]]*)\]\]/g, "$1")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  while (words.length > 1 && CORPORATE_SUFFIXES.has(words[words.length - 1]!)) words.pop();
  return words.join(" ");
}

export function normalizeDomain(value: string): string | null {
  let text = String(value || "").trim().toLowerCase();
  const link = /^\[\[([^\]]+)\](?:\[[^\]]*\])?\]$/.exec(text);
  if (link) text = link[1]!;
  text = text.replace(/^mailto:/, "").replace(/^[a-z]+:\/\//, "").replace(/^www\./, "");
  if (text.includes("@")) text = text.split("@").pop() || "";
  text = text.split(/[/?#:\s]/)[0] || "";
  return /^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$/.test(text) ? text : null;
}

/** Names a meeting title may contain, such as "Jane Doe" in "Jane Doe and Avi" or "Acme" in "Acme | Example sync". */
export function meetingTitleParts(title: string): string[] {
  const base = String(title || "")
    .replace(/\[\[[^\]]*\]\[([^\]]*)\]\]/g, "$1")
    .replace(/^\s*meeting:\s*/i, "")
    .replace(/^\s*[<[]?\d{4}-\d{2}-\d{2}[^\]>]*[\]>]?\s*/, "")
    .trim();
  const parts = new Set<string>();
  const add = (value: string) => {
    for (const candidate of [value, value.replace(MEETING_WORDS, " ")]) {
      const trimmed = candidate.replace(/\s+/g, " ").trim();
      if (trimmed.length > 1) parts.add(trimmed);
    }
  };
  add(base);
  for (const piece of base.split(/\s*(?:[@|/,&+:]|<>|\bx\b|\band\b|\bwith\b|\bvs\.?|—|–|\s-\s)\s*/i)) add(piece);
  return [...parts];
}

function emailsIn(value: string): string[] {
  return [...new Set((String(value || "").match(EMAIL_PATTERN) || []).map((email) => email.toLowerCase()))];
}

function emailDomain(email: string): string | null {
  return normalizeDomain(email.split("@").pop() || "");
}

function splitList(value: string): string[] {
  const out: string[] = [];
  let rest = String(value || "");
  rest = rest.replace(/\[\[[^\]]*\](?:\[[^\]]*\])?\]/g, (match) => { out.push(match); return ","; });
  for (const part of rest.split(/[,;|]/)) {
    const trimmed = part.trim();
    if (trimmed) out.push(trimmed);
  }
  return out;
}

function idLinks(value: string): string[] {
  return [...String(value || "").matchAll(ID_LINK_PATTERN)].map((match) => String(match[1]).toLowerCase());
}

function localIso(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/**
 * A sortable time from a property, Org timestamp, ISO string or dated path.
 * Date-only values stay `YYYY-MM-DD`; values with a time become UTC ISO.
 */
export function crmTimeFrom(value: string | undefined | null): string | undefined {
  const text = String(value || "").trim();
  if (!text) return undefined;
  const iso = /(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)(Z|[+-]\d{2}:?\d{2})?/.exec(text);
  if (iso && (iso[3] || /T/.test(iso[0]))) {
    const parsed = Date.parse(iso[0].replace(" ", "T"));
    if (Number.isFinite(parsed)) return new Date(parsed).toISOString();
  }
  const org = /(\d{4})-(\d{2})-(\d{2})(?:\s+[A-Za-z]{2,3}\.?)?(?:\s+(\d{1,2}):(\d{2}))?/.exec(text);
  if (!org) return undefined;
  const [, y, m, d, hh, mm] = org;
  const month = Number(m), day = Number(d);
  if (month < 1 || month > 12 || day < 1 || day > 31) return undefined;
  if (hh !== undefined && mm !== undefined) return new Date(Number(y), month - 1, day, Number(hh), Number(mm)).toISOString();
  return `${y}-${m}-${d}`;
}

function maxTime(values: Array<string | undefined>): string | undefined {
  return values.filter((value): value is string => Boolean(value)).sort().at(-1);
}

// MARK: - Corpus loading

function readConfig(root: string): Org2Config {
  const file = configFilePath(root);
  return fs.existsSync(file) ? loadConfig(file) : {};
}

function isLedgerAccountPath(relative: string): boolean {
  return /^notes\/[^/]+\/accounts\//.test(relative.replace(/\\/g, "/"));
}

function crmSourcePatterns(config: Org2Config): { patterns: string[]; ignore: string[] } {
  const nodesDir = String(config.roam?.nodesDir || "notes").replace(/^\.\//, "").replace(/\/+$/, "");
  return {
    patterns: [
      ...(config.agendaFiles?.length ? config.agendaFiles : ["**/*.org", "**/*.org2"]),
      ...(nodesDir && !path.isAbsolute(nodesDir) ? [`${nodesDir}/**/*.org`, `${nodesDir}/**/*.org2`] : []),
      "views/**/*.org",
      "views/**/*.org2",
      ...(config.crm?.include ?? []),
    ].map((pattern) => pattern.replace(/\\/g, "/").replace(/^\.\//, "")),
    ignore: ["node_modules", "node_modules/**", "raw/**", ...(config.ignorePatterns ?? [])],
  };
}

/** Whether a directory could hold a file matching `pattern` (same rules as config globs). */
function directoryCouldMatch(relativeDir: string, pattern: string): boolean {
  const dir = relativeDir.split("/").filter(Boolean);
  const segments = pattern.split("/").filter(Boolean);
  if (!pattern.includes("*")) {
    // A plain pattern names a file or a directory prefix.
    const joined = segments.join("/");
    const rel = dir.join("/");
    return joined === rel || joined.startsWith(rel + "/") || rel.startsWith(joined + "/");
  }
  for (let i = 0; i < dir.length; i += 1) {
    const segment = segments[i];
    if (segment === undefined || i >= segments.length - 1) return segment === "**";
    if (segment === "**") return true;
    if (!configPathMatches(dir[i]!, segment)) return false;
  }
  return true;
}

function ignoredPath(relative: string, ignore: string[]): boolean {
  const base = path.basename(relative);
  if (base.startsWith(".syncthing.") || base.includes(".sync-conflict-") || base.endsWith(".tmp")) return true;
  return ignore.some((pattern) => configPathMatches(relative, pattern));
}

export interface CrmSourceWalk {
  files: string[];
  /** Every directory that could hold a source file, with its mtime; a new or removed file changes it. */
  dirs: Array<[string, number]>;
}

/**
 * Find CRM source files without descending into directories that no pattern
 * can match (audio, artifacts, raw imports, hidden state).
 */
export function walkCrmSources(root: string, config: Org2Config): CrmSourceWalk {
  const { patterns, ignore } = crmSourcePatterns(config);
  const recursive = config.recursive !== false;
  const files: string[] = [];
  const dirs: Array<[string, number]> = [];
  const visit = (absolute: string, relative: string) => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(absolute, { withFileTypes: true });
      dirs.push([relative, fs.statSync(absolute).mtimeMs]);
    } catch { return; }
    for (const entry of entries) {
      const childRelative = relative ? `${relative}/${entry.name}` : entry.name;
      if (ignoredPath(childRelative, ignore)) continue;
      if (entry.isDirectory()) {
        if (!recursive || entry.name.startsWith(".")) continue;
        if (!patterns.some((pattern) => directoryCouldMatch(childRelative, pattern))) continue;
        visit(path.join(absolute, entry.name), childRelative);
      } else if (entry.isFile() && patterns.some((pattern) => configPathMatches(childRelative, pattern))) {
        if (!isLedgerAccountPath(childRelative)) files.push(path.join(absolute, entry.name));
      }
    }
  };
  visit(root, "");
  return { files: [...new Set(files)].sort(), dirs };
}

export function crmSourceFiles(root: string, config: Org2Config): string[] {
  return walkCrmSources(root, config).files;
}

type LedgerSummary = {
  ledger: string;
  id: string;
  title: string;
  state: string;
  aliases: string[];
  identityKeys: string[];
  fields: Record<string, string>;
  eventCount: number;
  lastEventAt?: string;
  lastContactAt?: string;
  file: string;
  /** Compact event history for the activity timeline. */
  events: Array<{ id: string; type: string; at: string; note?: string }>;
};

const LEDGER_CACHE_SCHEMA = "org2:crm-ledger-cache:v2";
type LedgerCache = { schema: typeof LEDGER_CACHE_SCHEMA; files: Record<string, { size: number; mtimeMs: number; summary: LedgerSummary }> };

const LEDGER_FIELD_KEEP = ["primary_email", "work_status", "next_followup_at", "stage", "crm_stage", "owner"];

function ledgerAccountFilePaths(root: string): string[] {
  const notes = path.join(root, "notes");
  if (!fs.existsSync(notes)) return [];
  const files: string[] = [];
  for (const entry of fs.readdirSync(notes, { withFileTypes: true })) {
    if (!entry.isDirectory() || !/^[a-z0-9][a-z0-9._-]*$/.test(entry.name)) continue;
    const accounts = path.join(notes, entry.name, "accounts");
    if (!fs.existsSync(accounts)) continue;
    for (const name of fs.readdirSync(accounts)) if (/\.org2?$/i.test(name)) files.push(path.join(accounts, name));
  }
  return files.sort();
}

function loadLedgerSummaries(root: string, cacheDir: string): LedgerSummary[] {
  const cacheFile = cacheDir ? path.join(cacheDir, "crm-ledger-v2.json") : null;
  let cache: LedgerCache = { schema: LEDGER_CACHE_SCHEMA, files: {} };
  if (cacheFile && fs.existsSync(cacheFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(cacheFile, "utf8")) as LedgerCache;
      if (parsed.schema === LEDGER_CACHE_SCHEMA && parsed.files) cache = parsed;
    } catch { /* rebuild */ }
  }
  const next: LedgerCache = { schema: LEDGER_CACHE_SCHEMA, files: {} };
  const summaries: LedgerSummary[] = [];
  let changed = false;
  for (const file of ledgerAccountFilePaths(root)) {
    const relative = path.relative(root, file).replace(/\\/g, "/");
    let stat: fs.Stats;
    try { stat = fs.statSync(file); } catch { continue; }
    const cached = cache.files[relative];
    if (cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
      next.files[relative] = cached;
      summaries.push(cached.summary);
      continue;
    }
    changed = true;
    try {
      const raw = fs.readFileSync(file, "utf8");
      if (!/work-ledger-account/i.test(raw)) continue;
      const account = parseWorkLedgerAccount(raw);
      const summary = summarizeWorkLedgerAccount({ file, revision: "", raw, account, sourceIssues: [] }, { cooldownDays: 0 });
      const kept: LedgerSummary = {
        ledger: account.ledger,
        id: account.id,
        title: account.title,
        state: account.state,
        aliases: account.aliases,
        identityKeys: account.identityKeys,
        fields: Object.fromEntries(Object.entries(account.fields).filter(([key]) => LEDGER_FIELD_KEEP.includes(key))),
        eventCount: account.events.length,
        ...(summary.lastEventAt ? { lastEventAt: summary.lastEventAt } : {}),
        ...(summary.lastContactAt ? { lastContactAt: summary.lastContactAt } : {}),
        file: relative,
        events: account.events.map((event) => ({ id: event.id, type: event.type, at: event.at, ...(event.note ? { note: event.note.slice(0, 300) } : {}) })),
      };
      next.files[relative] = { size: stat.size, mtimeMs: stat.mtimeMs, summary: kept };
      summaries.push(kept);
    } catch { /* invalid ledger files are reported by celorga doctor */ }
  }
  if (Object.keys(cache.files).length !== Object.keys(next.files).length) changed = true;
  if (cacheFile && changed) {
    try {
      fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
      const temporary = `${cacheFile}.${process.pid}.tmp`;
      fs.writeFileSync(temporary, JSON.stringify(next));
      fs.renameSync(temporary, cacheFile);
    } catch { /* the cache is disposable */ }
  }
  return summaries;
}

// MARK: - Calendar

export interface CrmCalendarEvent {
  calendarId: string;
  eventId: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  status: string;
  htmlLink?: string;
  meetingUrl?: string;
  selfResponse?: string;
  attendees: Array<{ email?: string; name?: string; self?: boolean; organizer?: boolean; response?: string }>;
  organizer?: { email?: string; self?: boolean };
}

/** Staged calendar events (org2:calendar-event:v1) between two instants. */
export function loadStagedCalendarEvents(root: string, from: Date, to: Date): CrmCalendarEvent[] {
  const base = path.join(root, "raw", "connectors", "google-calendar");
  if (!fs.existsSync(base)) return [];
  const months = new Set<string>();
  for (let cursor = new Date(from.getFullYear(), from.getMonth(), 1); cursor <= to; cursor.setMonth(cursor.getMonth() + 1)) {
    months.add(`${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}`);
  }
  const seen = new Map<string, CrmCalendarEvent>();
  for (const profile of fs.readdirSync(base, { withFileTypes: true })) {
    if (!profile.isDirectory()) continue;
    const directory = path.join(base, profile.name);
    for (const name of fs.readdirSync(directory)) {
      if (!name.endsWith(".json")) continue;
      const month = /(\d{4}-\d{2})\.json$/.exec(name)?.[1];
      if (month && !months.has(month)) continue;
      let parsed: { records?: Array<{ rawPayload?: Record<string, unknown> }> };
      try { parsed = JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")); } catch { continue; }
      for (const record of parsed.records ?? []) {
        const event = record.rawPayload as unknown as CrmCalendarEvent & { schema?: string } | undefined;
        if (!event || event.schema !== "org2:calendar-event:v1" || !event.eventId || !event.start) continue;
        const start = Date.parse(event.start);
        if (!Number.isFinite(start) || start < from.getTime() || start > to.getTime()) continue;
        if (String(event.status).toLowerCase() === "cancelled") continue;
        seen.set(`${profile.name}:${event.calendarId}:${event.eventId}`, {
          calendarId: event.calendarId,
          eventId: event.eventId,
          title: event.title,
          start: event.start,
          end: event.end,
          allDay: Boolean(event.allDay),
          status: event.status,
          ...(event.htmlLink ? { htmlLink: event.htmlLink } : {}),
          ...(event.meetingUrl ? { meetingUrl: event.meetingUrl } : {}),
          ...(event.selfResponse ? { selfResponse: event.selfResponse } : {}),
          attendees: Array.isArray(event.attendees) ? event.attendees : [],
          ...(event.organizer ? { organizer: event.organizer } : {}),
        });
      }
    }
  }
  // The same event can appear in two calendars (work and personal).
  const unique = new Map<string, CrmCalendarEvent>();
  for (const event of seen.values()) {
    const key = `${event.eventId}:${event.start}`;
    if (!unique.has(key)) unique.set(key, event);
  }
  return [...unique.values()].sort((a, b) => a.start.localeCompare(b.start));
}

// MARK: - Index

type EntityRecord = CrmEntitySummary & {
  node: CompiledCorpusNode | null;
  revision?: string;
  inferredEmails: string[];
  timeline: Map<string, CrmTimelineItem>;
  tasks: Map<string, CrmTask>;
  mentionFiles: Set<string>;
};

export interface CrmIndex {
  schema: typeof CRM_INDEX_SCHEMA;
  generatedAt: string;
  stages: string[];
  people: CrmEntitySummary[];
  companies: CrmEntitySummary[];
  stats: { people: number; companies: number; ledgerOnlyCompanies: number; ledgerAccounts: number; linkedLedgerAccounts: number; openTasks: number };
}

interface BuiltIndex {
  index: CrmIndex;
  entities: Map<string, EntityRecord>;
  ledgers: LedgerSummary[];
  selfDomains: Set<string>;
  byEmail: Map<string, string>;
  byDomain: Map<string, string>;
  corpus: CompiledCorpus;
  root: string;
  config: Org2Config;
  now: Date;
}

function entityTypeOf(node: CompiledCorpusNode): CrmEntityKind | null {
  const raw = String(node.entityType || node.properties.CELORGA_ENTITY_TYPE || node.properties.ORG2_ENTITY_TYPE || node.properties.ENTITY_TYPE || "").toLowerCase();
  if (PERSON_TYPES.has(raw)) return "person";
  if (COMPANY_TYPES.has(raw)) return "company";
  return null;
}

function nodeProperty(node: CompiledCorpusNode, ...keys: string[]): string {
  for (const key of keys) {
    const value = node.properties[key];
    if (value && value.trim()) return value.trim();
  }
  return "";
}

function isMeetingNode(node: CompiledCorpusNode): boolean {
  const kind = String(node.properties.KIND || node.properties.ORG2_KIND || node.properties.CELORGA_KIND || "").toLowerCase();
  return kind === "meeting" || Boolean(node.properties.CALENDAR_EVENT_ID || node.properties.RECORDED_AT || node.properties.RECORD_START);
}

function meetingTime(node: CompiledCorpusNode): string | undefined {
  for (const key of ["SCHEDULED_START", "RECORDED_AT", "RECORD_START", "CREATED_AT", "CREATED", "DATE"]) {
    const value = crmTimeFrom(node.properties[key]);
    if (value) return value;
  }
  return crmTimeFrom(node.title) || crmTimeFrom(path.basename(node.file));
}

function planningTime(node: CompiledCorpusNode, kind: "SCHEDULED" | "DEADLINE" | "CLOSED"): string | undefined {
  const entry = node.planning.find((item) => item.kind === kind);
  return entry ? crmTimeFrom(entry.raw) : undefined;
}

function taskFrom(node: CompiledCorpusNode, revision?: string): CrmTask {
  const open = !(node.todoTerminal ?? /^(DONE|CANCELED|CANCELLED)$/i.test(node.todo || ""));
  return {
    key: node.key,
    title: node.title,
    todo: node.todo || "",
    open,
    ...(node.priority ? { priority: node.priority } : {}),
    ...(planningTime(node, "SCHEDULED") ? { scheduled: planningTime(node, "SCHEDULED") } : {}),
    ...(planningTime(node, "DEADLINE") ? { deadline: planningTime(node, "DEADLINE") } : {}),
    ...(planningTime(node, "CLOSED") ? { closed: planningTime(node, "CLOSED") } : {}),
    file: node.file,
    line: node.sourceRange.startLine,
    ...(revision ? { revision } : {}),
  };
}

function taskDue(task: CrmTask): string | undefined {
  return [task.scheduled, task.deadline].filter((value): value is string => Boolean(value)).sort()[0];
}

function compareTasks(a: CrmTask, b: CrmTask): number {
  const left = taskDue(a), right = taskDue(b);
  if (left && right && left !== right) return left < right ? -1 : 1;
  if (Boolean(left) !== Boolean(right)) return left ? -1 : 1;
  return (a.priority || "Z").localeCompare(b.priority || "Z") || a.file.localeCompare(b.file) || a.line - b.line;
}

function stagesFor(config: Org2Config): string[] {
  const configured = Array.isArray(config.crm?.stages) ? config.crm!.stages.map((stage) => String(stage).trim().toLowerCase()).filter(Boolean) : [];
  return configured.length ? [...new Set(configured)] : [...DEFAULT_CRM_STAGES];
}

export function buildCrm(rootRaw: string, options: CrmIndexOptions = {}, walk?: CrmSourceWalk): BuiltIndex {
  const root = fs.realpathSync(path.resolve(rootRaw));
  const config = readConfig(root);
  const now = options.now ?? new Date();
  // Machine-local, disposable caches keep repeated opens fast on large corpora.
  const cacheDir = options.cacheDir || org2CorpusIndexDir(root);
  const files = (walk ?? walkCrmSources(root, config)).files;
  const corpus = compileCorpusIncremental(files, { rootDir: root, cacheFile: path.join(cacheDir, "crm-corpus-cache.json") });
  const ledgers = loadLedgerSummaries(root, cacheDir);
  const selfDomains = new Set((config.crm?.selfDomains ?? []).map((domain) => normalizeDomain(domain)).filter((domain): domain is string => Boolean(domain)));
  // Your own calendar identities reveal your team's domains without configuration.
  const recentEvents = loadStagedCalendarEvents(root, new Date(now.getTime() - 120 * 86_400_000), now);
  for (const event of recentEvents) {
    for (const person of [...event.attendees, ...(event.organizer ? [event.organizer] : [])]) {
      const domain = person.self && person.email ? emailDomain(person.email) : null;
      if (domain && !FREE_MAIL.has(domain)) selfDomains.add(domain);
    }
  }

  const nodesByFile = new Map<string, CompiledCorpusNode[]>();
  for (const node of corpus.nodes) {
    const list = nodesByFile.get(node.file);
    if (list) list.push(node);
    else nodesByFile.set(node.file, [node]);
  }
  for (const list of nodesByFile.values()) list.sort((a, b) => (a.kind === "file" ? -1 : b.kind === "file" ? 1 : a.sourceRange.startLine - b.sourceRange.startLine));
  const fileRevision = new Map(corpus.files.map((file) => [file.file, `sha256:${file.sha256}`]));

  // Entities.
  const entities = new Map<string, EntityRecord>();
  const byId = new Map<string, string>();
  const byNodeKey = new Map<string, string>();
  for (const node of corpus.nodes) {
    const kind = entityTypeOf(node);
    if (!kind) continue;
    const key = node.id ? `id:${node.id}` : node.kind === "file" ? `file:${node.file}` : `heading:${node.file}:${node.sourceRange.startLine}`;
    if (entities.has(key)) continue;
    const emails = emailsIn(nodeProperty(node, "EMAIL", "EMAILS", "WORK_EMAIL"));
    const domains = [...new Set(splitList(nodeProperty(node, "DOMAIN", "DOMAINS", "WEBSITE", "URL")).map(normalizeDomain).filter((d): d is string => Boolean(d)))];
    const stage = nodeProperty(node, "CRM_STAGE", "STAGE").toLowerCase();
    entities.set(key, {
      key, kind, source: "note", id: node.id, title: node.title, aliases: node.aliases,
      file: node.file, line: node.sourceRange.startLine, nodeKind: node.kind,
      stage, stageSource: stage ? "property" : "",
      emails, domains: kind === "company" ? domains : [],
      role: nodeProperty(node, "ROLE", "JOB_TITLE", "POSITION"),
      owner: nodeProperty(node, "OWNER"),
      people: [], ledgerAccounts: [], openTaskCount: 0, meetingCount: 0, mentionCount: 0,
      node, revision: fileRevision.get(node.file), inferredEmails: [],
      timeline: new Map(), tasks: new Map(), mentionFiles: new Set(),
    });
    if (node.id) byId.set(node.id, key);
    byNodeKey.set(node.key, key);
  }

  const nameIndex = (kind: CrmEntityKind) => {
    const map = new Map<string, string[]>();
    for (const entity of entities.values()) {
      if (entity.kind !== kind) continue;
      for (const label of [entity.title, ...entity.aliases]) {
        const name = normalizeCrmName(label);
        if (!name) continue;
        map.set(name, [...new Set([...(map.get(name) || []), entity.key])]);
      }
    }
    return map;
  };
  const companyNames = nameIndex("company");
  const personNames = nameIndex("person");
  const uniqueName = (map: Map<string, string[]>, label: string): string | undefined => {
    const matches = map.get(normalizeCrmName(label));
    return matches && matches.length === 1 ? matches[0] : undefined;
  };

  const byEmail = new Map<string, string>();
  for (const entity of entities.values()) if (entity.kind === "person") for (const email of entity.emails) if (!byEmail.has(email)) byEmail.set(email, entity.key);
  const byDomain = new Map<string, string>();
  const ambiguousDomains = new Set<string>();
  const indexDomain = (domain: string, key: string) => {
    if (FREE_MAIL.has(domain) || selfDomains.has(domain) || ambiguousDomains.has(domain)) return;
    const existing = byDomain.get(domain);
    if (existing && existing !== key) { byDomain.delete(domain); ambiguousDomains.add(domain); return; }
    byDomain.set(domain, key);
  };
  for (const entity of entities.values()) if (entity.kind === "company") for (const domain of entity.domains) indexDomain(domain, entity.key);

  // Ledger accounts → companies.
  const ledgerOnly: EntityRecord[] = [];
  let linkedLedgerAccounts = 0;
  for (const ledger of ledgers) {
    const keys = ledger.identityKeys.map((key) => key.toLowerCase());
    let target: string | undefined;
    let match: CrmMatch | undefined;
    const explicit = keys.find((key) => key.startsWith(CRM_LEDGER_COMPANY_KEY_PREFIX))?.slice(CRM_LEDGER_COMPANY_KEY_PREFIX.length);
    if (explicit && byId.has(explicit)) { target = byId.get(explicit); match = "explicit"; }
    if (!target) {
      for (const key of keys.filter((item) => item.startsWith("domain:"))) {
        const domain = normalizeDomain(key.slice(7));
        if (domain && byDomain.has(domain)) { target = byDomain.get(domain); match = "domain"; break; }
      }
    }
    if (!target) {
      for (const key of keys.filter((item) => item.startsWith("email:"))) {
        const domain = emailDomain(key.slice(6));
        if (domain && byDomain.has(domain)) { target = byDomain.get(domain); match = "email"; break; }
      }
    }
    if (!target) {
      for (const label of [ledger.title, ...ledger.aliases, ...keys.filter((key) => key.startsWith("name:")).map((key) => key.slice(5))]) {
        const found = uniqueName(companyNames, label);
        if (found) { target = found; match = "name"; break; }
      }
    }
    const ref: CrmLedgerRef = {
      ledger: ledger.ledger, id: ledger.id, title: ledger.title, state: ledger.state,
      ...(ledger.fields.work_status ? { workStatus: ledger.fields.work_status } : {}),
      ...(ledger.lastContactAt ? { lastContactAt: ledger.lastContactAt } : {}),
      ...(ledger.lastEventAt ? { lastEventAt: ledger.lastEventAt } : {}),
      ...(crmTimeFrom(ledger.fields.next_followup_at) ? { nextFollowUpAt: crmTimeFrom(ledger.fields.next_followup_at) } : {}),
      eventCount: ledger.eventCount, file: ledger.file, match: match || "explicit",
    };
    const ledgerDomains = keys.filter((key) => key.startsWith("domain:")).map((key) => normalizeDomain(key.slice(7))).filter((d): d is string => Boolean(d));
    if (target && match) {
      linkedLedgerAccounts += 1;
      const company = entities.get(target)!;
      company.ledgerAccounts.push(ref);
      continue;
    }
    const emails = [ledger.fields.primary_email, ...keys.filter((key) => key.startsWith("email:")).map((key) => key.slice(6))].flatMap((value) => emailsIn(value || ""));
    const stage = String(ledger.fields.crm_stage || ledger.fields.stage || "").toLowerCase();
    ledgerOnly.push({
      key: `ledger:${ledger.ledger}/${ledger.id}`, kind: "company", source: "ledger", id: null, title: ledger.title, aliases: ledger.aliases,
      file: ledger.file, line: 1, nodeKind: null, stage: stage || "lead", stageSource: "ledger",
      emails: [...new Set(emails)], domains: [...new Set(ledgerDomains)], role: "", owner: String(ledger.fields.owner || ""),
      people: [], ledgerAccounts: [{ ...ref, match: "explicit" }], openTaskCount: 0, meetingCount: 0, mentionCount: 0,
      node: null, inferredEmails: [], timeline: new Map(), tasks: new Map(), mentionFiles: new Set(),
    });
  }
  for (const record of ledgerOnly) {
    entities.set(record.key, record);
    // Calendar attendees from outreach-only prospects still find their account.
    for (const domain of record.domains) indexDomain(domain, record.key);
  }

  // Company stage falls back to the outreach ledger when no stage is set.
  for (const entity of entities.values()) {
    if (entity.kind !== "company" || entity.stage || !entity.ledgerAccounts.length) continue;
    entity.stage = "lead";
    entity.stageSource = "ledger";
  }
  for (const entity of entities.values()) {
    if (entity.kind !== "company") continue;
    for (const ref of entity.ledgerAccounts) {
      const summary = ledgers.find((ledger) => ledger.ledger === ref.ledger && ledger.id === ref.id);
      for (const key of summary?.identityKeys ?? []) {
        if (!key.startsWith("domain:")) continue;
        const domain = normalizeDomain(key.slice(7));
        if (domain && !entity.domains.includes(domain)) entity.domains.push(domain);
        if (domain) indexDomain(domain, entity.key);
      }
    }
  }

  // Person → company.
  for (const person of entities.values()) {
    if (person.kind !== "person" || !person.node) continue;
    const node = person.node;
    let company: { key: string; match: CrmMatch } | undefined;
    for (const key of PERSON_COMPANY_KEYS) {
      const value = node.properties[key];
      if (!value) continue;
      const linked = idLinks(value).map((id) => byId.get(id)).find((candidate) => candidate && entities.get(candidate)?.kind === "company");
      if (linked) { company = { key: linked, match: "explicit" }; break; }
      const named = splitList(value).map((part) => uniqueName(companyNames, part)).find(Boolean);
      if (named) { company = { key: named, match: "property" }; break; }
    }
    if (!company) {
      for (const email of person.emails) {
        const domain = emailDomain(email);
        if (domain && !selfDomains.has(domain) && byDomain.has(domain)) { company = { key: byDomain.get(domain)!, match: "email-domain" }; break; }
      }
    }
    if (!company && node.kind === "file") {
      const linked = new Set<string>();
      for (const fileNode of nodesByFile.get(node.file) ?? []) {
        for (const link of fileNode.links) {
          if (link.type !== "id") continue;
          const target = byId.get(link.target.replace(/^id:/i, "").toLowerCase());
          if (target && entities.get(target)?.kind === "company") linked.add(target);
        }
      }
      if (linked.size === 1) company = { key: [...linked][0]!, match: "note-link" };
    }
    if (company) {
      const target = entities.get(company.key)!;
      person.company = { key: target.key, title: target.title, match: company.match };
      target.people.push({ key: person.key, title: person.title });
    }
  }

  // Relations from every node to entities.
  const relationsOf = (node: CompiledCorpusNode, useEffective: boolean): Set<string> => {
    const related = new Set<string>();
    for (const link of node.links) {
      if (link.type !== "id") continue;
      const target = byId.get(link.target.replace(/^id:/i, "").toLowerCase());
      if (target) related.add(target);
    }
    for (const id of idLinks(node.title)) { const target = byId.get(id); if (target) related.add(target); }
    const properties = useEffective ? node.effectiveProperties : node.properties;
    for (const key of RELATION_KEYS) {
      const value = properties[key];
      if (!value) continue;
      for (const id of idLinks(value)) { const target = byId.get(id); if (target) related.add(target); }
      for (const email of emailsIn(value)) {
        const person = byEmail.get(email);
        if (person) related.add(person);
        else {
          const domain = emailDomain(email);
          if (domain && !selfDomains.has(domain) && byDomain.has(domain)) related.add(byDomain.get(domain)!);
        }
      }
      for (const part of splitList(value)) {
        if (part.startsWith("[[") || part.includes("@")) continue;
        const target = uniqueName(companyNames, part) || uniqueName(personNames, part);
        if (target) related.add(target);
      }
    }
    const self = byNodeKey.get(node.key);
    if (self) related.delete(self);
    return related;
  };

  // Who took part in a meeting, as opposed to who was only brought up.
  const fileLines = new Map<string, string[]>();
  const linesOf = (file: string): string[] => {
    let lines = fileLines.get(file);
    if (!lines) {
      try { lines = fs.readFileSync(path.join(root, file), "utf8").split(/\r?\n/); } catch { lines = []; }
      fileLines.set(file, lines);
    }
    return lines;
  };
  const refsInText = (text: string, into: Set<string>) => {
    for (const id of idLinks(text)) { const target = byId.get(id); if (target) into.add(target); }
    for (const email of emailsIn(text)) {
      const person = byEmail.get(email);
      if (person) { into.add(person); continue; }
      const domain = emailDomain(email);
      if (domain && !selfDomains.has(domain) && byDomain.has(domain)) into.add(byDomain.get(domain)!);
    }
  };
  const meetingAttendees = (meeting: CompiledCorpusNode, fileNodes: CompiledCorpusNode[]): Set<string> => {
    const attendees = new Set<string>();
    refsInText(meeting.title, attendees);
    for (const part of meetingTitleParts(meeting.title)) {
      const target = uniqueName(personNames, part) || uniqueName(companyNames, part);
      if (target) attendees.add(target);
    }
    for (const key of MEETING_ATTENDEE_KEYS) {
      const value = meeting.properties[key];
      if (!value) continue;
      refsInText(value, attendees);
      for (const part of splitList(value)) {
        if (part.startsWith("[[") || part.includes("@")) continue;
        const target = uniqueName(personNames, part) || uniqueName(companyNames, part);
        if (target) attendees.add(target);
      }
    }
    const lines = linesOf(meeting.file);
    const start = meeting.sourceRange.startLine, end = Math.min(lines.length, meeting.sourceRange.endLine);
    for (const child of fileNodes) {
      if (child.kind !== "heading" || child.sourceRange.startLine <= start || child.sourceRange.startLine > end) continue;
      if (!ATTENDEE_SECTION.test(child.title.trim())) continue;
      for (let line = child.sourceRange.startLine; line < Math.min(lines.length, child.sourceRange.endLine); line += 1) refsInText(lines[line] || "", attendees);
    }
    for (let line = start; line < end; line += 1) {
      const match = ATTENDEE_LINE.exec(lines[line] || "");
      if (match) refsInText(String(match[1]).split(/\.\s/)[0] || "", attendees);
    }
    for (const key of [...attendees]) {
      const person = entities.get(key);
      if (person?.kind === "person" && person.company) attendees.add(person.company.key);
    }
    return attendees;
  };

  const addItem = (entityKey: string, item: CrmTimelineItem) => {
    const entity = entities.get(entityKey);
    if (entity && !entity.timeline.has(item.key)) entity.timeline.set(item.key, item);
  };
  const addTask = (entityKey: string, task: CrmTask) => {
    const entity = entities.get(entityKey);
    if (entity && !entity.tasks.has(task.key)) entity.tasks.set(task.key, task);
  };

  const notedCalendarEvents = new Set<string>();
  for (const [file, nodes] of nodesByFile) {
    const revision = fileRevision.get(file);
    const fileNode = nodes.find((node) => node.kind === "file");
    const fileEntity = fileNode ? byNodeKey.get(fileNode.key) : undefined;
    const stack: CompiledCorpusNode[] = [];
    const meetingRelations = new Map<string, Set<string>>();
    for (const node of nodes) {
      if (node.kind === "file") {
        if (fileEntity) continue;
        const related = relationsOf(node, false);
        for (const key of related) {
          const entity = entities.get(key)!;
          if (entity.mentionFiles.has(file)) continue;
          entity.mentionFiles.add(file);
          addItem(key, { key: `mention:${file}`, type: "mention", title: node.title, at: crmTimeFrom(node.properties.CREATED) || crmTimeFrom(path.basename(file)), file, line: 1, role: "mentioned" });
        }
        continue;
      }
      while (stack.length && (stack[stack.length - 1]!.level || 0) >= (node.level || 0)) stack.pop();
      const own = new Set<string>();
      if (fileEntity) own.add(fileEntity);
      for (const ancestor of stack) { const key = byNodeKey.get(ancestor.key); if (key) own.add(key); }
      const isEntity = byNodeKey.has(node.key);
      const meetingAncestor = [...stack].reverse().find((ancestor) => meetingRelations.has(ancestor.key));
      if (!isEntity && isMeetingNode(node) && !meetingAncestor) {
        const attendees = meetingAttendees(node, nodes);
        for (const key of own) attendees.add(key);
        const related = relationsOf(node, false);
        for (const key of attendees) related.add(key);
        meetingRelations.set(node.key, related);
        const calendarEventId = String(node.properties.CALENDAR_EVENT_ID || "").trim();
        if (calendarEventId) notedCalendarEvents.add(calendarEventId);
        const at = meetingTime(node);
        for (const key of related) addItem(key, { key: `meeting:${node.key}`, type: "meeting", title: node.title.replace(/^Meeting:\s*/i, ""), ...(at ? { at } : {}), file, line: node.sourceRange.startLine, role: attendees.has(key) ? "attended" : "mentioned" });
      } else if (!isEntity && node.todo) {
        const related = relationsOf(node, true);
        for (const key of own) related.add(key);
        if (meetingAncestor) for (const key of meetingRelations.get(meetingAncestor.key)!) related.add(key);
        if (related.size) {
          const task = taskFrom(node, revision);
          for (const key of related) addTask(key, task);
        }
      } else if (!isEntity && !meetingAncestor && !own.size) {
        const related = relationsOf(node, false);
        for (const key of related) {
          const entity = entities.get(key)!;
          if (entity.mentionFiles.has(file)) continue;
          entity.mentionFiles.add(file);
          const at = crmTimeFrom(node.properties.CREATED) || crmTimeFrom(node.title) || crmTimeFrom(path.basename(file));
          addItem(key, { key: `mention:${file}`, type: "mention", title: fileNode && fileNode.title !== node.title ? `${fileNode.title} › ${node.title}` : node.title, ...(at ? { at } : {}), file, line: node.sourceRange.startLine, role: "mentioned" });
        }
      }
      stack.push(node);
    }
  }

  // Person inferred emails, used only for link suggestions.
  for (const person of entities.values()) {
    if (person.kind !== "person" || !person.node || person.emails.length || person.node.kind !== "file") continue;
    try {
      const raw = fs.readFileSync(path.join(root, person.node.file), "utf8").slice(0, 20_000);
      person.inferredEmails = emailsIn(raw);
    } catch { /* ignore */ }
  }

  // Past calendar events are direct contact even without a meeting note.
  for (const event of recentEvents) {
    if (event.allDay || event.selfResponse === "declined" || notedCalendarEvents.has(event.eventId)) continue;
    const eventSelfDomains = new Set(selfDomains);
    for (const attendee of event.attendees) if (attendee.self && attendee.email) { const domain = emailDomain(attendee.email); if (domain) eventSelfDomains.add(domain); }
    const touched = new Set<string>();
    for (const attendee of event.attendees) {
      if (attendee.self || !attendee.email) continue;
      const email = attendee.email.toLowerCase();
      const domain = emailDomain(email);
      if (domain && eventSelfDomains.has(domain)) continue;
      const person = byEmail.get(email);
      if (person) {
        touched.add(person);
        const company = entities.get(person)?.company;
        if (company) touched.add(company.key);
      } else if (domain && byDomain.has(domain)) touched.add(byDomain.get(domain)!);
    }
    const start = Date.parse(event.start);
    for (const key of touched) {
      const entity = entities.get(key)!;
      // A meeting note within a few hours already covers this event.
      const covered = [...entity.timeline.values()].some((item) => item.type === "meeting" && item.role === "attended" && item.at
        && Math.abs(Date.parse(item.at.length === 10 ? `${item.at}T12:00:00` : item.at) - start) < 6 * 3_600_000);
      if (!covered) addItem(key, { key: `calendar:${event.eventId}:${event.start}`, type: "calendar", title: event.title, at: event.start, ...(event.htmlLink ? { url: event.htmlLink } : {}), role: "attended" });
    }
  }

  // Roll people's meetings and tasks up into their company. Only meetings a
  // person attended count as contact with their company.
  for (const person of entities.values()) {
    if (person.kind !== "person" || !person.company) continue;
    const company = entities.get(person.company.key)!;
    for (const item of person.timeline.values()) {
      if ((item.type === "meeting" || item.type === "calendar") && item.role === "attended" && !company.timeline.has(item.key)) company.timeline.set(item.key, { ...item, via: person.title });
    }
    for (const task of person.tasks.values()) if (!company.tasks.has(task.key)) company.tasks.set(task.key, { ...task, via: person.title });
  }

  // Summaries.
  const nowIso = now.toISOString();
  const today = localIso(now);
  let openTasks = 0;
  const openTaskKeys = new Set<string>();
  for (const entity of entities.values()) {
    const tasks = [...entity.tasks.values()];
    const open = tasks.filter((task) => task.open).sort(compareTasks);
    for (const task of open) openTaskKeys.add(task.key);
    entity.openTaskCount = open.length;
    if (open[0]) entity.nextTask = open[0];
    const items = [...entity.timeline.values()];
    const attended = items.filter((item) => (item.type === "meeting" || item.type === "calendar") && item.role === "attended");
    const mentioned = items.filter((item) => item.role === "mentioned");
    entity.meetingCount = attended.length;
    entity.mentionCount = mentioned.length;
    const past = (value: string | undefined) => value && (value <= nowIso || value <= today) ? value : undefined;
    const latest = <T extends string>(candidates: Array<{ at?: string; type: T }>) =>
      candidates.filter((item) => item.at).sort((a, b) => a.at!.localeCompare(b.at!)).at(-1) as { at: string; type: T } | undefined;
    const touch = latest<"meeting" | "calendar" | "outreach">([
      ...attended.map((item) => ({ at: past(item.at), type: item.type === "calendar" ? "calendar" as const : "meeting" as const })),
      ...entity.ledgerAccounts.map((ref) => ({ at: past(ref.lastContactAt), type: "outreach" as const })),
    ]);
    const mention = latest<"meeting" | "note">(mentioned.map((item) => ({ at: past(item.at), type: item.type === "meeting" ? "meeting" as const : "note" as const })));
    if (touch) { entity.lastTouchAt = touch.at; entity.lastTouchType = touch.type; }
    if (mention) { entity.lastMentionAt = mention.at; entity.lastMentionType = mention.type; }
    const last = latest<string>([touch, mention, ...tasks.map((task) => ({ at: past(task.closed), type: "task" }))].filter((item): item is { at: string; type: string } => Boolean(item)));
    if (last) { entity.lastInteractionAt = last.at; entity.lastInteractionType = last.type; }
    entity.nextFollowUpAt = [entity.nextTask ? taskDue(entity.nextTask) : undefined, ...entity.ledgerAccounts.map((ref) => ref.nextFollowUpAt)]
      .filter((value): value is string => Boolean(value)).sort()[0];
  }
  openTasks = openTaskKeys.size;
  const summary = (entity: EntityRecord): CrmEntitySummary => ({
    key: entity.key, kind: entity.kind, source: entity.source, id: entity.id, title: entity.title, aliases: entity.aliases,
    file: entity.file, line: entity.line, nodeKind: entity.nodeKind, stage: entity.stage, stageSource: entity.stageSource,
    emails: entity.emails, domains: entity.domains, role: entity.role, owner: entity.owner,
    ...(entity.company ? { company: entity.company } : {}),
    people: entity.people.sort((a, b) => a.title.localeCompare(b.title)),
    ledgerAccounts: entity.ledgerAccounts,
    openTaskCount: entity.openTaskCount,
    ...(entity.nextTask ? { nextTask: entity.nextTask } : {}),
    meetingCount: entity.meetingCount,
    mentionCount: entity.mentionCount,
    ...(entity.lastInteractionAt ? { lastInteractionAt: entity.lastInteractionAt, lastInteractionType: entity.lastInteractionType } : {}),
    ...(entity.lastTouchAt ? { lastTouchAt: entity.lastTouchAt, lastTouchType: entity.lastTouchType } : {}),
    ...(entity.lastMentionAt ? { lastMentionAt: entity.lastMentionAt, lastMentionType: entity.lastMentionType } : {}),
    ...(entity.nextFollowUpAt ? { nextFollowUpAt: entity.nextFollowUpAt } : {}),
  });
  // Direct contact first, then recent mentions.
  const sortEntities = (a: CrmEntitySummary, b: CrmEntitySummary) =>
    (b.lastTouchAt || "").localeCompare(a.lastTouchAt || "") || (b.lastMentionAt || "").localeCompare(a.lastMentionAt || "") || a.title.localeCompare(b.title);
  const people = [...entities.values()].filter((entity) => entity.kind === "person").map(summary).sort(sortEntities);
  const companies = [...entities.values()].filter((entity) => entity.kind === "company").map(summary).sort(sortEntities);
  return {
    index: {
      schema: CRM_INDEX_SCHEMA,
      generatedAt: nowIso,
      stages: stagesFor(config),
      people,
      companies,
      stats: {
        people: people.length,
        companies: companies.filter((company) => company.source === "note").length,
        ledgerOnlyCompanies: ledgerOnly.length,
        ledgerAccounts: ledgers.length,
        linkedLedgerAccounts,
        openTasks,
      },
    },
    entities, ledgers, selfDomains, byEmail, byDomain, corpus, root, config, now,
  };
}

// MARK: - Snapshot cache

/**
 * The CRM is derived from thousands of files, so reads go through a
 * machine-local snapshot of the computed index and every entity's activity.
 * The snapshot is reused while no source file, directory, ledger account,
 * staged calendar file or config changed (checked with stat calls only) and
 * is rebuilt on the next read otherwise. It is disposable: deleting it only
 * costs one rebuild.
 */
export const CRM_SNAPSHOT_SCHEMA = "org2:crm-snapshot:v1" as const;
/** Bump whenever the computed index or activity changes shape or meaning. */
const CRM_SNAPSHOT_VERSION = 2;
const TIMELINE_LIMIT = 250;

export interface CrmEntityDetails {
  properties: Record<string, string>;
  tasks: CrmTask[];
  timeline: CrmTimelineItem[];
}

type FileStamp = [string, number, number];

interface CrmSnapshotMeta {
  schema: typeof CRM_SNAPSHOT_SCHEMA;
  version: number;
  token: string;
  root: string;
  day: string;
  files: FileStamp[];
  dirs: Array<[string, number]>;
  extra: FileStamp[];
}

interface CrmSnapshot {
  schema: typeof CRM_SNAPSHOT_SCHEMA;
  token: string;
  index: CrmIndex;
  details: Record<string, CrmEntityDetails>;
  lookups: { byEmail: Record<string, string>; byDomain: Record<string, string>; selfDomains: string[] };
}

interface CrmLookup {
  entities: Map<string, CrmEntitySummary>;
  byEmail: Map<string, string>;
  byDomain: Map<string, string>;
}

interface LoadedSnapshot extends CrmLookup {
  root: string;
  now: Date;
  index: CrmIndex;
  details: Record<string, CrmEntityDetails>;
  selfDomains: Set<string>;
  cached: boolean;
  buildMs: number;
}

function stamp(root: string, absolute: string): FileStamp | null {
  try {
    const stat = fs.statSync(absolute);
    return [path.relative(root, absolute).replace(/\\/g, "/"), stat.size, stat.mtimeMs];
  } catch { return null; }
}

/** Inputs outside the walked note sources: config, ledger accounts, staged calendar events. */
function extraInputs(root: string): FileStamp[] {
  const files = [configFilePath(root), ...ledgerAccountFilePaths(root)];
  const notes = path.join(root, "notes");
  if (fs.existsSync(notes)) {
    for (const entry of fs.readdirSync(notes, { withFileTypes: true })) {
      const accounts = path.join(notes, entry.name, "accounts");
      if (entry.isDirectory() && fs.existsSync(accounts)) files.push(accounts);
    }
  }
  const calendar = path.join(root, "raw", "connectors", "google-calendar");
  if (fs.existsSync(calendar)) {
    files.push(calendar);
    for (const profile of fs.readdirSync(calendar, { withFileTypes: true })) {
      if (!profile.isDirectory()) continue;
      const directory = path.join(calendar, profile.name);
      files.push(directory);
      for (const name of fs.readdirSync(directory)) if (name.endsWith(".json")) files.push(path.join(directory, name));
    }
  }
  return files.map((file) => stamp(root, file)).filter((item): item is FileStamp => Boolean(item));
}

function sameStamps(left: FileStamp[], right: FileStamp[]): boolean {
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i += 1) {
    const a = left[i]!, b = right[i]!;
    if (a[0] !== b[0] || a[1] !== b[1] || a[2] !== b[2]) return false;
  }
  return true;
}

function snapshotIsCurrent(root: string, meta: CrmSnapshotMeta, day: string): boolean {
  if (meta.schema !== CRM_SNAPSHOT_SCHEMA || meta.version !== CRM_SNAPSHOT_VERSION || meta.root !== root || meta.day !== day) return false;
  for (const [relative, mtime] of meta.dirs) {
    try { if (fs.statSync(path.join(root, relative)).mtimeMs !== mtime) return false; } catch { return false; }
  }
  for (const [relative, size, mtime] of meta.files) {
    try {
      const stat = fs.statSync(path.join(root, relative));
      if (stat.size !== size || stat.mtimeMs !== mtime) return false;
    } catch { return false; }
  }
  return sameStamps(extraInputs(root), meta.extra);
}

function outreachTimeline(built: BuiltIndex, entity: EntityRecord): CrmTimelineItem[] {
  const items: CrmTimelineItem[] = [];
  for (const ref of entity.ledgerAccounts) {
    const ledger = built.ledgers.find((item) => item.ledger === ref.ledger && item.id === ref.id);
    for (const event of ledger?.events ?? []) {
      const label = event.type.replace(/-/g, " ");
      items.push({
        key: `outreach:${ref.ledger}/${ref.id}:${event.id}`,
        type: "outreach",
        title: label.charAt(0).toUpperCase() + label.slice(1),
        at: crmTimeFrom(event.at) || event.at,
        file: ref.file,
        ...(event.note ? { detail: event.note } : {}),
        via: ref.ledger,
      });
    }
  }
  return items;
}

function entityDetails(built: BuiltIndex, entity: EntityRecord): CrmEntityDetails {
  const tasks = [...entity.tasks.values()].sort((a, b) => Number(b.open) - Number(a.open) || compareTasks(a, b));
  const timeline = [...entity.timeline.values(), ...outreachTimeline(built, entity)];
  for (const task of tasks) if (!task.open) timeline.push({ key: `task:${task.key}`, type: "task", title: task.title, at: task.closed, file: task.file, line: task.line, detail: task.todo, ...(task.via ? { via: task.via } : {}) });
  timeline.sort((a, b) => (b.at || "").localeCompare(a.at || "") || a.key.localeCompare(b.key));
  return { properties: entity.node ? entity.node.properties : {}, tasks, timeline: timeline.slice(0, TIMELINE_LIMIT) };
}

function writeAtomic(file: string, content: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, content);
  fs.renameSync(temporary, file);
}

function lookupFrom(index: CrmIndex, lookups: CrmSnapshot["lookups"]): CrmLookup & { selfDomains: Set<string> } {
  return {
    entities: new Map([...index.people, ...index.companies].map((item) => [item.key, item])),
    byEmail: new Map(Object.entries(lookups.byEmail)),
    byDomain: new Map(Object.entries(lookups.byDomain)),
    selfDomains: new Set(lookups.selfDomains),
  };
}

/** Return a current snapshot, rebuilding it only when an input changed. */
export function loadCrmSnapshot(rootRaw: string, options: CrmIndexOptions & { rebuild?: boolean } = {}): LoadedSnapshot {
  const started = Date.now();
  const root = fs.realpathSync(path.resolve(rootRaw));
  const now = options.now ?? new Date();
  const day = localIso(now);
  const cacheDir = options.cacheDir || org2CorpusIndexDir(root);
  const metaFile = path.join(cacheDir, "crm-snapshot-meta.json");
  const dataFile = path.join(cacheDir, "crm-snapshot.json");
  if (!options.rebuild) {
    try {
      const meta = JSON.parse(fs.readFileSync(metaFile, "utf8")) as CrmSnapshotMeta;
      if (snapshotIsCurrent(root, meta, day)) {
        const data = JSON.parse(fs.readFileSync(dataFile, "utf8")) as CrmSnapshot;
        if (data.schema === CRM_SNAPSHOT_SCHEMA && data.token === meta.token) {
          return { ...lookupFrom(data.index, data.lookups), root, now, index: data.index, details: data.details, cached: true, buildMs: Date.now() - started };
        }
      }
    } catch { /* missing or unreadable: rebuild */ }
  }
  const config = readConfig(root);
  const walk = walkCrmSources(root, config);
  const extra = extraInputs(root);
  const built = buildCrm(root, { ...options, now }, walk);
  const details: Record<string, CrmEntityDetails> = {};
  for (const entity of built.entities.values()) details[entity.key] = entityDetails(built, entity);
  const token = crypto.randomUUID();
  const lookups = { byEmail: Object.fromEntries(built.byEmail), byDomain: Object.fromEntries(built.byDomain), selfDomains: [...built.selfDomains] };
  const meta: CrmSnapshotMeta = {
    schema: CRM_SNAPSHOT_SCHEMA, version: CRM_SNAPSHOT_VERSION, token, root, day,
    files: walk.files.map((file) => stamp(root, file)).filter((item): item is FileStamp => Boolean(item)),
    dirs: walk.dirs,
    extra,
  };
  try {
    // Data first, then the meta that vouches for it.
    writeAtomic(dataFile, JSON.stringify({ schema: CRM_SNAPSHOT_SCHEMA, token, index: built.index, details, lookups } satisfies CrmSnapshot));
    writeAtomic(metaFile, JSON.stringify(meta));
  } catch { /* the snapshot is disposable */ }
  return { ...lookupFrom(built.index, lookups), root, now, index: built.index, details, cached: false, buildMs: Date.now() - started };
}

/** Build the snapshot ahead of time so the next read is fast. */
export function crmWarm(root: string, options: CrmIndexOptions & { rebuild?: boolean } = {}) {
  const snapshot = loadCrmSnapshot(root, options);
  return {
    schema: "org2:crm-warm:v1" as const,
    cached: snapshot.cached,
    elapsedMs: snapshot.buildMs,
    people: snapshot.index.people.length,
    companies: snapshot.index.companies.length,
  };
}

// MARK: - Reads

function upcomingByEntity(meetings: CrmUpcomingMeeting[], lookup: CrmLookup): Map<string, CrmUpcomingMeeting[]> {
  const out = new Map<string, CrmUpcomingMeeting[]>();
  const add = (key: string, meeting: CrmUpcomingMeeting) => {
    const list = out.get(key) ?? [];
    if (!list.includes(meeting)) list.push(meeting);
    out.set(key, list);
  };
  for (const meeting of meetings) {
    for (const person of meeting.people) {
      add(person.key, meeting);
      const company = lookup.entities.get(person.key)?.company;
      if (company) add(company.key, meeting);
    }
    for (const company of meeting.companies) add(company.key, meeting);
  }
  return out;
}

function calendarTimeline(meetings: CrmUpcomingMeeting[]): CrmTimelineItem[] {
  return meetings.map((item) => ({ key: `calendar:${item.event.eventId}:${item.event.start}`, type: "calendar" as const, title: item.event.title, at: item.event.start, ...(item.event.htmlLink ? { url: item.event.htmlLink } : {}), role: "attended" as const }));
}

export function crmIndex(root: string, options: CrmIndexOptions & { kind?: "people" | "companies"; stage?: string; query?: string; limit?: number; details?: boolean; days?: number } = {}) {
  const snapshot = loadCrmSnapshot(root, options);
  const { index } = snapshot;
  const query = normalizeCrmName(options.query || "");
  const rawQuery = String(options.query || "").trim().toLowerCase();
  const filter = (items: CrmEntitySummary[]) => items.filter((item) => {
    if (options.stage && item.stage !== options.stage.toLowerCase()) return false;
    if (!rawQuery) return true;
    return normalizeCrmName([item.title, ...item.aliases].join(" ")).includes(query)
      || item.emails.some((email) => email.includes(rawQuery))
      || item.domains.some((domain) => domain.includes(rawQuery))
      || (item.company ? normalizeCrmName(item.company.title).includes(query) : false);
  });
  const limit = options.limit && options.limit > 0 ? options.limit : 5000;
  const people = (options.kind === "companies" ? [] : filter(index.people)).slice(0, limit);
  const companies = (options.kind === "people" ? [] : filter(index.companies)).slice(0, limit);
  const result = {
    ...index,
    people,
    companies,
    total: { people: options.kind === "companies" ? 0 : filter(index.people).length, companies: options.kind === "people" ? 0 : filter(index.companies).length },
    cache: { hit: snapshot.cached, elapsedMs: snapshot.buildMs },
  };
  if (!options.details) return result;
  // Everything the People and Companies pages show, in one read.
  const upcoming = upcomingByEntity(upcomingFrom(snapshot, options.days ?? 30), snapshot);
  const details: Record<string, CrmEntityDetails & { upcoming: CrmUpcomingMeeting[] }> = {};
  for (const item of [...people, ...companies]) {
    const base = snapshot.details[item.key] ?? { properties: {}, tasks: [], timeline: [] };
    const meetings = upcoming.get(item.key) ?? [];
    details[item.key] = { ...base, timeline: meetings.length ? [...calendarTimeline(meetings), ...base.timeline] : base.timeline, upcoming: meetings };
  }
  return { ...result, details };
}

// MARK: - Resolve and show

function resolveEntity(built: BuiltIndex, refRaw: string): EntityRecord {
  return built.entities.get(resolveKey(built, refRaw))!;
}

function resolveKey(lookup: CrmLookup, refRaw: string): string {
  const ref = String(refRaw || "").trim();
  if (!ref) throw new Error("an entity reference is required (ID, title, email, domain or ledger:LEDGER/ID)");
  const lower = ref.toLowerCase();
  const direct = lookup.entities.get(ref) || lookup.entities.get(`id:${lower.replace(/^id:/, "")}`);
  if (direct) return direct.key;
  const matches = resolveCandidates(lookup, ref);
  if (matches.length === 1) return matches[0]!.key;
  if (!matches.length) throw new Error(`no person or company matches ${ref}`);
  throw new Error(`${ref} is ambiguous: ${matches.slice(0, 6).map((match) => `${match.title} (${match.key})`).join(", ")}`);
}

function resolveCandidates(lookup: CrmLookup, query: string): Array<{ key: string; title: string; kind: CrmEntityKind; match: string }> {
  const lower = query.trim().toLowerCase();
  const out = new Map<string, { key: string; title: string; kind: CrmEntityKind; match: string }>();
  const add = (key: string | undefined, match: string) => {
    const entity = key ? lookup.entities.get(key) : undefined;
    if (entity && !out.has(entity.key)) out.set(entity.key, { key: entity.key, title: entity.title, kind: entity.kind, match });
  };
  for (const email of emailsIn(lower)) {
    // An exact person match wins; otherwise fall back to the company domain.
    if (lookup.byEmail.has(email)) { add(lookup.byEmail.get(email), "email"); continue; }
    const domain = emailDomain(email);
    if (domain) add(lookup.byDomain.get(domain), "email-domain");
  }
  if (!out.size) {
    const domain = normalizeDomain(lower);
    if (domain && !lower.includes(" ")) add(lookup.byDomain.get(domain), "domain");
  }
  if (!out.size) {
    const name = normalizeCrmName(query);
    for (const entity of lookup.entities.values()) {
      if ([entity.title, ...entity.aliases].some((label) => normalizeCrmName(label) === name)) add(entity.key, "name");
    }
  }
  if (!out.size) {
    for (const entity of lookup.entities.values()) {
      if (entity.ledgerAccounts.some((ref) => `${ref.ledger}/${ref.id}` === lower || ref.id === lower)) add(entity.key, "ledger");
    }
  }
  return [...out.values()];
}

export function crmResolve(root: string, query: string, options: CrmIndexOptions = {}) {
  const snapshot = loadCrmSnapshot(root, options);
  const matches = resolveCandidates(snapshot, query).map((match) => {
    const entity = snapshot.entities.get(match.key)!;
    return { ...match, source: entity.source, id: entity.id, file: entity.file, stage: entity.stage, ledgerAccounts: entity.ledgerAccounts.map((ref) => ({ ledger: ref.ledger, id: ref.id, state: ref.state, workStatus: ref.workStatus })) };
  });
  return { schema: "org2:crm-resolution:v1" as const, query, found: matches.length > 0, ambiguous: matches.length > 1, matches };
}

export function crmShow(root: string, ref: string, options: CrmIndexOptions & { days?: number } = {}) {
  const snapshot = loadCrmSnapshot(root, options);
  const key = resolveKey(snapshot, ref);
  const summary = snapshot.entities.get(key)!;
  const details = snapshot.details[key] ?? { properties: {}, tasks: [], timeline: [] };
  const upcoming = upcomingByEntity(upcomingFrom(snapshot, options.days ?? 30), snapshot).get(key) ?? [];
  let revision: string | null = null;
  if (summary.file && summary.source === "note") {
    try { revision = readGuardedFile(path.join(snapshot.root, summary.file)).revision; } catch { revision = null; }
  }
  return {
    schema: CRM_ENTITY_SCHEMA,
    entity: summary,
    revision,
    properties: details.properties,
    tasks: details.tasks,
    timeline: [...calendarTimeline(upcoming), ...details.timeline],
    upcoming,
    stages: snapshot.index.stages,
  };
}

// MARK: - Calendar briefs

export interface CrmUpcomingMeeting {
  event: { eventId: string; calendarId: string; title: string; start: string; end: string; allDay: boolean; htmlLink?: string; meetingUrl?: string };
  people: Array<{ key: string; title: string; email: string }>;
  companies: Array<{ key: string; title: string; stage: string; lastInteractionAt?: string; lastTouchAt?: string; openTaskCount: number; nextTask?: CrmTask; lastOutreachAt?: string }>;
  unknownAttendees: string[];
}

interface UpcomingContext extends CrmLookup {
  root: string;
  now: Date;
  selfDomains: Set<string>;
}

function upcomingFrom(context: UpcomingContext, days: number): CrmUpcomingMeeting[] {
  const from = context.now;
  const to = new Date(from.getTime() + Math.max(1, days) * 86_400_000);
  const events = loadStagedCalendarEvents(context.root, from, to);
  const summaries = context.entities;
  const out: CrmUpcomingMeeting[] = [];
  for (const event of events) {
    if (event.selfResponse === "declined") continue;
    const selfDomains = new Set(context.selfDomains);
    for (const attendee of event.attendees) if (attendee.self && attendee.email) { const domain = emailDomain(attendee.email); if (domain) selfDomains.add(domain); }
    if (event.organizer?.self && event.organizer.email) { const domain = emailDomain(event.organizer.email); if (domain) selfDomains.add(domain); }
    const people = new Map<string, { key: string; title: string; email: string }>();
    const companies = new Map<string, CrmUpcomingMeeting["companies"][number]>();
    const unknown: string[] = [];
    const addCompany = (key: string) => {
      const company = summaries.get(key);
      if (!company || companies.has(key)) return;
      companies.set(key, {
        key, title: company.title, stage: company.stage, openTaskCount: company.openTaskCount,
        ...(company.lastInteractionAt ? { lastInteractionAt: company.lastInteractionAt } : {}),
        ...(company.lastTouchAt ? { lastTouchAt: company.lastTouchAt } : {}),
        ...(company.nextTask ? { nextTask: company.nextTask } : {}),
        ...(maxTime(company.ledgerAccounts.map((ref) => ref.lastContactAt)) ? { lastOutreachAt: maxTime(company.ledgerAccounts.map((ref) => ref.lastContactAt)) } : {}),
      });
    };
    let external = false;
    for (const attendee of event.attendees) {
      if (attendee.self || !attendee.email) continue;
      const email = attendee.email.toLowerCase();
      const domain = emailDomain(email);
      if (domain && selfDomains.has(domain)) continue;
      external = true;
      const personKey = context.byEmail.get(email);
      if (personKey && summaries.has(personKey)) {
        const person = summaries.get(personKey)!;
        people.set(personKey, { key: personKey, title: person.title, email });
        if (person.company) addCompany(person.company.key);
        continue;
      }
      const companyKey = domain ? context.byDomain.get(domain) : undefined;
      if (companyKey) addCompany(companyKey);
      unknown.push(email);
    }
    if (!external) continue;
    out.push({
      event: { eventId: event.eventId, calendarId: event.calendarId, title: event.title, start: event.start, end: event.end, allDay: event.allDay, ...(event.htmlLink ? { htmlLink: event.htmlLink } : {}), ...(event.meetingUrl ? { meetingUrl: event.meetingUrl } : {}) },
      people: [...people.values()],
      companies: [...companies.values()],
      unknownAttendees: unknown,
    });
  }
  return out;
}

export function crmUpcoming(root: string, options: CrmIndexOptions & { days?: number } = {}) {
  const snapshot = loadCrmSnapshot(root, options);
  return { schema: "org2:crm-upcoming:v1" as const, generatedAt: snapshot.now.toISOString(), days: options.days ?? 7, meetings: upcomingFrom(snapshot, options.days ?? 7) };
}

// MARK: - Writes

function noteEntity(entity: EntityRecord, action: string): EntityRecord & { node: CompiledCorpusNode; file: string } {
  if (!entity.node || !entity.file) throw new Error(`${entity.title} exists only in an outreach ledger; create a company note first (celorga crm create company --from-ledger ${entity.key.replace(/^ledger:/, "")}) before you ${action}`);
  return entity as EntityRecord & { node: CompiledCorpusNode; file: string };
}

const SETTABLE_FIELDS: Record<string, string> = { stage: "CRM_STAGE", domain: "DOMAIN", email: "EMAIL", role: "ROLE", owner: "OWNER", company: "COMPANY" };

export function crmSet(rootRaw: string, ref: string, fieldRaw: string, valueRaw: string, options: CrmIndexOptions & { apply?: boolean; expectedRevision?: string } = {}) {
  const built = buildCrm(rootRaw, options);
  const entity = noteEntity(resolveEntity(built, ref), "set fields");
  const field = String(fieldRaw || "").trim().toLowerCase();
  const property = SETTABLE_FIELDS[field];
  if (!property) throw new Error(`--field must be one of ${Object.keys(SETTABLE_FIELDS).join(", ")}`);
  let value = String(valueRaw ?? "").trim();
  if (/[\r\n]/.test(value)) throw new Error("value must be a single line");
  if (field === "stage") value = value.toLowerCase();
  if (field === "domain" && value) {
    const domain = normalizeDomain(value);
    if (!domain) throw new Error(`not a domain: ${value}`);
    value = domain;
  }
  if (field === "email" && value && !emailsIn(value).length) throw new Error(`not an email address: ${value}`);
  if (field === "company" && value) {
    if (entity.kind !== "person") throw new Error("only people have a company");
    const company = resolveEntity(built, value);
    if (company.kind !== "company") throw new Error(`${company.title} is not a company`);
    const linked = noteEntity(company, "link people to it");
    if (!linked.id) throw new Error(`${linked.title} has no :ID: property; add one (celorga id ensure) before linking to it`);
    value = `[[id:${linked.id}][${linked.title.replace(/[[\]]/g, "")}]]`;
  }
  const revision = options.expectedRevision || readGuardedFile(path.join(built.root, entity.file)).revision;
  const result = editPropertyViewSource(built.root, { file: entity.file, kind: entity.nodeKind === "heading" ? "heading" : "file", line: entity.nodeKind === "heading" ? entity.line! : 1, property, value, expectedRevision: revision, apply: options.apply });
  return { schema: "org2:crm-change:v1" as const, action: "set", entity: { key: entity.key, title: entity.title }, field, property, value, oldValue: result.oldValue, changed: result.changed, applied: result.applied, file: entity.file, baseRevision: revision, revision: result.nextRevision, content: result.content };
}

function planningTimestamp(raw: string, label: string): string {
  const text = String(raw || "").trim();
  const match = /^(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}:\d{2})(?:-(\d{1,2}:\d{2}))?)?$/.exec(text);
  if (!match) throw new Error(`${label} must be YYYY-MM-DD, YYYY-MM-DD HH:MM or YYYY-MM-DD HH:MM-HH:MM`);
  const base = formatOrgDateTimestamp(match[1]!);
  if (!base) throw new Error(`invalid ${label}: ${text}`);
  const time = match[2] ? ` ${match[2].padStart(5, "0")}${match[3] ? `-${match[3].padStart(5, "0")}` : ""}` : "";
  return `${base.slice(0, -1)}${time}>`;
}

export function crmFollowUp(rootRaw: string, ref: string, input: { title: string; scheduled?: string; deadline?: string; priority?: string }, options: CrmIndexOptions & { apply?: boolean; expectedRevision?: string } = {}) {
  const built = buildCrm(rootRaw, options);
  const entity = noteEntity(resolveEntity(built, ref), "add follow-ups");
  const title = String(input.title || "").trim();
  if (!title || /[\r\n]/.test(title)) throw new Error("--title must be a single non-empty line");
  const priority = input.priority ? String(input.priority).trim().toUpperCase() : "";
  if (priority && !/^[A-Z0-9]$/.test(priority)) throw new Error("--priority must be a single letter such as A");
  const absolute = path.join(built.root, entity.file);
  const snapshot = readGuardedFile(absolute);
  if (options.expectedRevision && options.expectedRevision !== snapshot.revision) throw new Error("note changed since it was read; refresh and retry");
  const newline = snapshot.content.includes("\r\n") ? "\r\n" : "\n";
  const lines = snapshot.content.split(/\r\n|\n/);
  const trailingNewline = snapshot.content.endsWith("\n");
  if (trailingNewline) lines.pop();
  let level = 1;
  let insertAt = lines.length;
  if (entity.nodeKind === "heading") {
    level = (entity.node.level || 1) + 1;
    insertAt = Math.min(lines.length, entity.node.sourceRange.endLine);
    while (insertAt > entity.line! && !lines[insertAt - 1]!.trim()) insertAt -= 1;
  }
  const planning = [
    input.scheduled ? `SCHEDULED: ${planningTimestamp(input.scheduled, "--scheduled")}` : "",
    input.deadline ? `DEADLINE: ${planningTimestamp(input.deadline, "--deadline")}` : "",
  ].filter(Boolean).join(" ");
  const created = `[${localIso(built.now)} ${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][built.now.getDay()]}]`;
  const block = [
    `${"*".repeat(level)} TODO ${priority ? `[#${priority}] ` : ""}${title}`,
    ...(planning ? [planning] : []),
    ":PROPERTIES:",
    `:CREATED: ${created}`,
    ":END:",
  ];
  const before = lines.slice(0, insertAt);
  if (before.length && before[before.length - 1]!.trim() && entity.nodeKind !== "heading") before.push("");
  const next = [...before, ...block, ...lines.slice(insertAt)];
  const content = next.join(newline) + newline;
  if (options.apply) guardedWriteFile(absolute, content, { expectedRevision: snapshot.revision, preserveMode: true });
  return { schema: "org2:crm-change:v1" as const, action: "follow-up", entity: { key: entity.key, title: entity.title }, title, changed: true, applied: Boolean(options.apply), file: entity.file, line: before.length + 1, baseRevision: snapshot.revision, revision: guardedContentRevision(content), content };
}

function slugify(value: string): string {
  return value.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "untitled";
}

export function crmCreate(rootRaw: string, kindRaw: string, input: { title?: string; domain?: string; email?: string; stage?: string; role?: string; company?: string; fromLedger?: string }, options: CrmIndexOptions & { apply?: boolean } = {}) {
  const built = buildCrm(rootRaw, options);
  const kind = String(kindRaw || "").toLowerCase() === "person" ? "person" : String(kindRaw || "").toLowerCase() === "company" ? "company" : null;
  if (!kind) throw new Error("create requires person or company");
  let ledgerRef: { ledger: string; id: string } | null = null;
  let ledgerDomains: string[] = [];
  let title = String(input.title || "").trim();
  if (input.fromLedger) {
    if (kind !== "company") throw new Error("--from-ledger creates a company");
    const [ledger, id] = String(input.fromLedger).replace(/^ledger:/, "").split("/");
    if (!ledger || !id) throw new Error("--from-ledger must be LEDGER/ACCOUNT_ID");
    const snapshot = loadWorkLedgerAccount(built.root, ledger, id);
    ledgerRef = { ledger, id };
    title ||= snapshot.account.title;
    ledgerDomains = snapshot.account.identityKeys.filter((key) => key.startsWith("domain:")).map((key) => normalizeDomain(key.slice(7))).filter((d): d is string => Boolean(d));
    if (snapshot.account.identityKeys.some((key) => key.startsWith(CRM_LEDGER_COMPANY_KEY_PREFIX))) throw new Error(`${ledger}/${id} is already linked to a company note`);
  }
  if (!title || /[\r\n]/.test(title)) throw new Error("--title must be a single non-empty line");
  const duplicate = resolveCandidates(built, title).find((match) => match.kind === kind && built.entities.get(match.key)?.source === "note");
  if (duplicate) throw new Error(`${duplicate.title} already exists (${duplicate.key})`);
  const domain = input.domain ? normalizeDomain(input.domain) : ledgerDomains[0] || null;
  if (input.domain && !domain) throw new Error(`not a domain: ${input.domain}`);
  const email = input.email ? emailsIn(input.email)[0] : undefined;
  if (input.email && !email) throw new Error(`not an email address: ${input.email}`);
  let companyLink = "";
  if (input.company) {
    if (kind !== "person") throw new Error("--company applies to people");
    const company = noteEntity(resolveEntity(built, input.company), "link people to it");
    if (!company.id) throw new Error(`${company.title} has no :ID: property`);
    companyLink = `[[id:${company.id}][${company.title.replace(/[[\]]/g, "")}]]`;
  }
  const id = crypto.randomUUID();
  const nodesDir = String(built.config.roam?.nodesDir || "notes").replace(/^\.\//, "").replace(/\/+$/, "");
  const directory = path.isAbsolute(nodesDir) ? nodesDir : path.join(built.root, nodesDir || "notes");
  let file = path.join(directory, `${slugify(title)}.org`);
  for (let n = 2; fs.existsSync(file) || fs.existsSync(file.replace(/\.org$/, ".org2")); n += 1) file = path.join(directory, `${slugify(title)}-${n}.org`);
  const properties = [
    `:ID: ${id}`,
    `:ORG2_ENTITY_TYPE: ${kind}`,
    ...(domain && kind === "company" ? [`:DOMAIN: ${domain}`] : []),
    ...(email ? [`:EMAIL: ${email}`] : []),
    ...(input.role ? [`:ROLE: ${String(input.role).trim()}`] : []),
    ...(companyLink ? [`:COMPANY: ${companyLink}`] : []),
    ...(input.stage ? [`:CRM_STAGE: ${String(input.stage).trim().toLowerCase()}`] : []),
  ];
  const content = [":PROPERTIES:", ...properties, ":END:", `#+title: ${title}`, ""].join("\n");
  const relative = path.relative(built.root, file).replace(/\\/g, "/");
  let ledgerChange: { ledger: string; id: string; identityKey: string } | null = null;
  if (ledgerRef) ledgerChange = { ...ledgerRef, identityKey: `${CRM_LEDGER_COMPANY_KEY_PREFIX}${id}` };
  if (options.apply) {
    guardedWriteFile(file, content, { expectedRevision: null });
    if (ledgerChange) linkLedgerAccount(built.root, ledgerChange.ledger, ledgerChange.id, id);
  }
  return { schema: "org2:crm-change:v1" as const, action: "create", kind, id, title, file: relative, changed: true, applied: Boolean(options.apply), content, ...(ledgerChange ? { ledgerLink: ledgerChange } : {}) };
}

function linkLedgerAccount(root: string, ledger: string, accountId: string, companyId: string): void {
  const release = acquireWorkLedgerMutationLock(root, ledger);
  try {
    const snapshot = loadWorkLedgerAccount(root, ledger, accountId);
    const key = `${CRM_LEDGER_COMPANY_KEY_PREFIX}${companyId}`;
    if (snapshot.account.identityKeys.includes(key)) return;
    const others = listWorkLedgerAccounts(root, ledger).filter((item) => item.account.id !== accountId && item.account.identityKeys.includes(key));
    if (others.length) throw new Error(`${key} is already claimed by ${ledger}/${others[0]!.account.id}; merge the duplicate accounts first`);
    const account = updateWorkLedgerAccount(snapshot.account, { identityKeys: [...snapshot.account.identityKeys, key] });
    const validation = validateWorkLedgerAccount(account);
    if (!validation.valid) throw new Error(validation.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n"));
    saveWorkLedgerAccount(root, account, { expectedRevision: snapshot.revision, rejectSourceDrift: true });
  } finally {
    release();
  }
}

// MARK: - Link suggestions

export interface CrmLinkProposal {
  id: string;
  type: "ledger-company" | "person-company" | "person-email" | "company-domain";
  title: string;
  reason: string;
  entity: { key: string; title: string };
  target?: { key: string; title: string };
  file: string;
  value: string;
}

function proposalId(type: string, key: string, value: string): string {
  return sha(`${type}\0${key}\0${value}`).slice(0, 12);
}

export function crmLinkSuggestions(built: BuiltIndex): CrmLinkProposal[] {
  const proposals: CrmLinkProposal[] = [];
  const ledgerLinked = new Map<string, number>();
  for (const entity of built.entities.values()) for (const ref of entity.ledgerAccounts) if (entity.source === "note") ledgerLinked.set(`${ref.ledger}/${ref.id}`, (ledgerLinked.get(`${ref.ledger}/${ref.id}`) || 0) + 1);
  for (const company of built.entities.values()) {
    if (company.kind !== "company" || company.source !== "note") continue;
    for (const ref of company.ledgerAccounts) {
      if (ref.match === "explicit" || !company.id) continue;
      const value = `${CRM_LEDGER_COMPANY_KEY_PREFIX}${company.id}`;
      proposals.push({
        id: proposalId("ledger-company", `${ref.ledger}/${ref.id}`, value), type: "ledger-company",
        title: `Link ledger account ${ref.title} to ${company.title}`,
        reason: `Matched by ${ref.match}.`, entity: { key: `ledger:${ref.ledger}/${ref.id}`, title: ref.title },
        target: { key: company.key, title: company.title }, file: ref.file, value,
      });
    }
    if (!company.domains.length || company.node?.properties.DOMAIN) continue;
    const ledgerDomains = [...new Set(company.ledgerAccounts.flatMap((ref) => built.ledgers.find((ledger) => ledger.ledger === ref.ledger && ledger.id === ref.id)?.identityKeys ?? [])
      .filter((key) => key.startsWith("domain:")).map((key) => normalizeDomain(key.slice(7))).filter((d): d is string => Boolean(d)))];
    if (ledgerDomains.length === 1) {
      proposals.push({
        id: proposalId("company-domain", company.key, ledgerDomains[0]!), type: "company-domain",
        title: `Set ${company.title} domain to ${ledgerDomains[0]}`, reason: "From its linked outreach ledger account.",
        entity: { key: company.key, title: company.title }, file: company.file!, value: ledgerDomains[0]!,
      });
    }
  }
  for (const person of built.entities.values()) {
    if (person.kind !== "person" || !person.node) continue;
    if (person.company && person.company.match !== "explicit" && person.company.match !== "property") {
      const company = built.entities.get(person.company.key)!;
      if (company.id && company.source === "note") {
        const value = `[[id:${company.id}][${company.title.replace(/[[\]]/g, "")}]]`;
        proposals.push({
          id: proposalId("person-company", person.key, company.id), type: "person-company",
          title: `Set ${person.title}'s company to ${company.title}`,
          reason: person.company.match === "email-domain" ? "Their email domain matches the company." : "Their note links only to this company.",
          entity: { key: person.key, title: person.title }, target: { key: company.key, title: company.title }, file: person.file!, value,
        });
      }
    }
    if (!person.emails.length && person.inferredEmails.length === 1) {
      proposals.push({
        id: proposalId("person-email", person.key, person.inferredEmails[0]!), type: "person-email",
        title: `Set ${person.title}'s email to ${person.inferredEmails[0]}`, reason: "It is the only email address in their note.",
        entity: { key: person.key, title: person.title }, file: person.file!, value: person.inferredEmails[0]!,
      });
    }
  }
  return proposals.sort((a, b) => a.type.localeCompare(b.type) || a.title.localeCompare(b.title));
}

export function crmLink(rootRaw: string, options: CrmIndexOptions & { apply?: boolean; only?: string[] } = {}) {
  const built = buildCrm(rootRaw, options);
  const proposals = crmLinkSuggestions(built);
  const selected = options.only?.length ? proposals.filter((proposal) => options.only!.includes(proposal.id)) : proposals;
  if (options.only?.length) {
    const missing = options.only.filter((id) => !proposals.some((proposal) => proposal.id === id));
    if (missing.length) throw new Error(`unknown or stale proposal IDs: ${missing.join(", ")}`);
  }
  const results: Array<{ id: string; applied: boolean; error?: string }> = [];
  if (options.apply) {
    for (const proposal of selected) {
      try {
        if (proposal.type === "ledger-company") {
          const [ledger, id] = proposal.entity.key.replace(/^ledger:/, "").split("/");
          linkLedgerAccount(built.root, ledger!, id!, proposal.value.slice(CRM_LEDGER_COMPANY_KEY_PREFIX.length));
        } else {
          const entity = built.entities.get(proposal.entity.key)!;
          const property = proposal.type === "person-company" ? "COMPANY" : proposal.type === "person-email" ? "EMAIL" : "DOMAIN";
          const absolute = path.join(built.root, entity.file!);
          editPropertyViewSource(built.root, { file: entity.file!, kind: entity.nodeKind === "heading" ? "heading" : "file", line: entity.nodeKind === "heading" ? entity.line! : 1, property, value: proposal.value, expectedRevision: readGuardedFile(absolute).revision, apply: true });
        }
        results.push({ id: proposal.id, applied: true });
      } catch (error) {
        results.push({ id: proposal.id, applied: false, error: error instanceof Error ? error.message : String(error) });
      }
    }
  }
  return { schema: "org2:crm-link-proposals:v1" as const, applied: Boolean(options.apply), proposals: selected, ...(options.apply ? { results } : {}) };
}

// MARK: - Scheduling

export interface CrmScheduleProposal {
  task: CrmTask;
  entity: { key: string; title: string };
  start: string;
  end: string;
  timestamp: string;
  reason: string;
}

function parseClock(value: string): number {
  const match = /^(\d{1,2}):(\d{2})$/.exec(value.trim());
  if (!match || Number(match[1]) > 23 || Number(match[2]) > 59) throw new Error(`invalid time ${value}; use HH:MM`);
  return Number(match[1]) * 60 + Number(match[2]);
}

/**
 * Propose calendar slots for open People & Companies follow-ups that are due
 * soon or overdue and have no time yet. Busy time comes from staged calendar
 * events; the proposal only rewrites the TODO's SCHEDULED line in the corpus.
 */
export function crmSchedule(rootRaw: string, options: CrmIndexOptions & { days?: number; hours?: string; duration?: number; apply?: boolean; only?: string[]; weekends?: boolean; overdueDays?: number } = {}) {
  const built = buildCrm(rootRaw, options);
  const days = Math.max(1, Math.min(30, options.days ?? 5));
  const [startText, endText] = String(options.hours || "09:00-17:00").split("-");
  const dayStart = parseClock(startText || "09:00");
  const dayEnd = parseClock(endText || "17:00");
  if (dayEnd <= dayStart) throw new Error("--hours must be START-END with END after START");
  const duration = Math.max(10, Math.min(240, Math.round(options.duration ?? 30)));
  const now = built.now;
  const horizon = new Date(now.getFullYear(), now.getMonth(), now.getDate() + days);
  const horizonDay = localIso(new Date(horizon.getTime() - 1));
  // Long-stale TODOs are clutter, not plans; leave them to a person.
  const overdueDays = Math.max(0, options.overdueDays ?? 14);
  const oldestDay = localIso(new Date(now.getFullYear(), now.getMonth(), now.getDate() - overdueDays));

  const candidates = new Map<string, { task: CrmTask; entity: EntityRecord; due: string }>();
  for (const entity of built.entities.values()) {
    for (const task of entity.tasks.values()) {
      if (!task.open || candidates.has(task.key)) continue;
      const due = taskDue(task);
      if (!due || !/^\d{4}-\d{2}-\d{2}$/.test(due) || due > horizonDay || due < oldestDay) continue;
      if (task.scheduled && !/^\d{4}-\d{2}-\d{2}$/.test(task.scheduled)) continue;
      candidates.set(task.key, { task, entity, due });
    }
  }
  const ordered = [...candidates.values()].sort((a, b) => a.due.localeCompare(b.due) || compareTasks(a.task, b.task));
  const busy = loadStagedCalendarEvents(built.root, new Date(now.getTime() - 86_400_000), horizon)
    .filter((event) => !event.allDay && event.selfResponse !== "declined")
    .map((event) => ({ start: Date.parse(event.start), end: Date.parse(event.end) }))
    .filter((range) => Number.isFinite(range.start) && Number.isFinite(range.end));
  for (const entity of built.entities.values()) for (const task of entity.tasks.values()) {
    if (!task.open || !task.scheduled || /^\d{4}-\d{2}-\d{2}$/.test(task.scheduled)) continue;
    const start = Date.parse(task.scheduled);
    if (Number.isFinite(start)) busy.push({ start, end: start + duration * 60_000 });
  }
  const proposals: CrmScheduleProposal[] = [];
  const free = (start: number, end: number) => !busy.some((range) => range.start < end && range.end > start);
  const step = 15 * 60_000;
  const firstSlot = Math.ceil(now.getTime() / step) * step;
  for (const candidate of ordered) {
    let placed = false;
    for (let offset = 0; offset < days && !placed; offset += 1) {
      const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
      if (!options.weekends && (day.getDay() === 0 || day.getDay() === 6)) continue;
      for (let minute = dayStart; minute + duration <= dayEnd; minute += 15) {
        const start = new Date(day.getFullYear(), day.getMonth(), day.getDate(), Math.floor(minute / 60), minute % 60).getTime();
        const end = start + duration * 60_000;
        if (start < firstSlot || !free(start, end)) continue;
        busy.push({ start, end });
        const startDate = new Date(start), endDate = new Date(end);
        const hhmm = (date: Date) => `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
        proposals.push({
          task: candidate.task,
          entity: { key: candidate.entity.key, title: candidate.entity.title },
          start: startDate.toISOString(),
          end: endDate.toISOString(),
          timestamp: planningTimestamp(`${localIso(startDate)} ${hhmm(startDate)}-${hhmm(endDate)}`, "slot"),
          reason: candidate.due < localIso(now) ? `Overdue since ${candidate.due}` : `Due ${candidate.due}`,
        });
        placed = true;
        break;
      }
    }
  }
  const selected = options.only?.length ? proposals.filter((proposal) => options.only!.includes(proposal.task.key)) : proposals;
  const results: Array<{ task: string; applied: boolean; error?: string }> = [];
  if (options.apply) {
    const byFile = new Map<string, CrmScheduleProposal[]>();
    for (const proposal of selected) byFile.set(proposal.task.file, [...(byFile.get(proposal.task.file) || []), proposal]);
    for (const [file, items] of byFile) {
      const absolute = path.join(built.root, file);
      try {
        const snapshot = readGuardedFile(absolute);
        if (items.some((item) => item.task.revision && item.task.revision !== snapshot.revision && item.task.revision !== guardedContentRevision(snapshot.content.replace(/\r\n?/g, "\n")))) throw new Error("note changed since it was read; refresh and retry");
        let text = snapshot.content;
        for (const item of items) text = setScheduledTimestamp(text, item.task.line, item.timestamp, absolute);
        guardedWriteFile(absolute, text, { expectedRevision: snapshot.revision, preserveMode: true });
        for (const item of items) results.push({ task: item.task.key, applied: true });
      } catch (error) {
        for (const item of items) results.push({ task: item.task.key, applied: false, error: error instanceof Error ? error.message : String(error) });
      }
    }
  }
  return { schema: "org2:crm-schedule:v1" as const, generatedAt: now.toISOString(), days, hours: `${startText}-${endText}`, duration, applied: Boolean(options.apply), proposals: selected, unplaced: ordered.length - proposals.length, ...(options.apply ? { results } : {}) };
}

function setScheduledTimestamp(text: string, headingLine: number, timestamp: string, filePath: string): string {
  // Reuse the shared planning editor, then swap in the timed timestamp.
  const lines = text.split(/\r\n|\n/);
  if (!/^\*+\s/.test(lines[headingLine - 1] || "")) throw new Error(`line ${headingLine} is no longer a heading`);
  const dated = updatePlanningInText(text, { filePath, lineNumber: headingLine, kind: "SCHEDULED", date: timestamp.slice(1, 11) }).text;
  const out = dated.split("\n");
  for (let i = headingLine; i < out.length && (isPlanningLine(out[i]!) || !out[i]!.trim()); i += 1) {
    if (/\bSCHEDULED:\s*<[^>]*>/.test(out[i]!)) { out[i] = out[i]!.replace(/\bSCHEDULED:\s*<[^>]*>/, `SCHEDULED: ${timestamp}`); break; }
  }
  return out.join(text.includes("\r\n") ? "\r\n" : "\n");
}
