import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { configFilePath } from "./brandNames.js";
import { formatOrgDateTimestamp } from "./calendarDate.js";
import { loadConfig, resolveFilesFromDir, type Org2Config } from "./config.js";
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
  type WorkLedgerEvent,
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
  meetingCount: number;
  lastInteractionAt?: string;
  lastInteractionType?: string;
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

export function crmSourceFiles(root: string, config: Org2Config): string[] {
  const nodesDir = String(config.roam?.nodesDir || "notes").replace(/^\.\//, "").replace(/\/+$/, "");
  const patterns = [
    ...(config.agendaFiles?.length ? config.agendaFiles : ["**/*.org", "**/*.org2"]),
    ...(nodesDir && !path.isAbsolute(nodesDir) ? [`${nodesDir}/**/*.org`, `${nodesDir}/**/*.org2`] : []),
    "views/**/*.org",
    "views/**/*.org2",
    ...(config.crm?.include ?? []),
  ];
  const ignore = ["node_modules", "node_modules/**", "raw/**", ...(config.ignorePatterns ?? [])];
  return [...new Set(resolveFilesFromDir(root, patterns, ignore, config.recursive !== false))]
    .filter((file) => !isLedgerAccountPath(path.relative(root, file)))
    .sort();
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
};

type LedgerCache = { schema: "org2:crm-ledger-cache:v1"; files: Record<string, { size: number; mtimeMs: number; summary: LedgerSummary }> };

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
  const cacheFile = cacheDir ? path.join(cacheDir, "crm-ledger-v1.json") : null;
  let cache: LedgerCache = { schema: "org2:crm-ledger-cache:v1", files: {} };
  if (cacheFile && fs.existsSync(cacheFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(cacheFile, "utf8")) as LedgerCache;
      if (parsed.schema === "org2:crm-ledger-cache:v1" && parsed.files) cache = parsed;
    } catch { /* rebuild */ }
  }
  const next: LedgerCache = { schema: "org2:crm-ledger-cache:v1", files: {} };
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

export function buildCrm(rootRaw: string, options: CrmIndexOptions = {}): BuiltIndex {
  const root = fs.realpathSync(path.resolve(rootRaw));
  const config = readConfig(root);
  const now = options.now ?? new Date();
  // Machine-local, disposable caches keep repeated opens fast on large corpora.
  const cacheDir = options.cacheDir || org2CorpusIndexDir(root);
  const files = crmSourceFiles(root, config);
  const corpus = compileCorpusIncremental(files, { rootDir: root, cacheFile: path.join(cacheDir, "crm-corpus-cache.json") });
  const ledgers = loadLedgerSummaries(root, cacheDir);
  const selfDomains = new Set((config.crm?.selfDomains ?? []).map((domain) => normalizeDomain(domain)).filter((domain): domain is string => Boolean(domain)));

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
      people: [], ledgerAccounts: [], openTaskCount: 0, meetingCount: 0,
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
    if (FREE_MAIL.has(domain) || ambiguousDomains.has(domain)) return;
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
      people: [], ledgerAccounts: [{ ...ref, match: "explicit" }], openTaskCount: 0, meetingCount: 0,
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

  const addItem = (entityKey: string, item: CrmTimelineItem) => {
    const entity = entities.get(entityKey);
    if (entity && !entity.timeline.has(item.key)) entity.timeline.set(item.key, item);
  };
  const addTask = (entityKey: string, task: CrmTask) => {
    const entity = entities.get(entityKey);
    if (entity && !entity.tasks.has(task.key)) entity.tasks.set(task.key, task);
  };

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
          addItem(key, { key: `mention:${file}`, type: "mention", title: node.title, at: crmTimeFrom(node.properties.CREATED) || crmTimeFrom(path.basename(file)), file, line: 1 });
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
        const related = relationsOf(node, false);
        for (const key of own) related.add(key);
        meetingRelations.set(node.key, related);
        const at = meetingTime(node);
        for (const key of related) addItem(key, { key: `meeting:${node.key}`, type: "meeting", title: node.title.replace(/^Meeting:\s*/i, ""), ...(at ? { at } : {}), file, line: node.sourceRange.startLine });
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
          addItem(key, { key: `mention:${file}`, type: "mention", title: fileNode && fileNode.title !== node.title ? `${fileNode.title} › ${node.title}` : node.title, ...(at ? { at } : {}), file, line: node.sourceRange.startLine });
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

  // Roll people's meetings and tasks up into their company.
  for (const person of entities.values()) {
    if (person.kind !== "person" || !person.company) continue;
    const company = entities.get(person.company.key)!;
    for (const item of person.timeline.values()) if (item.type === "meeting" && !company.timeline.has(item.key)) company.timeline.set(item.key, { ...item, via: person.title });
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
    const meetings = [...entity.timeline.values()].filter((item) => item.type === "meeting");
    entity.meetingCount = meetings.length;
    const past = (value: string | undefined) => value && (value <= nowIso || value <= today) ? value : undefined;
    const candidates: Array<{ at?: string; type: string }> = [
      ...meetings.map((item) => ({ at: past(item.at), type: "meeting" })),
      ...entity.ledgerAccounts.map((ref) => ({ at: past(ref.lastContactAt), type: "outreach" })),
      ...tasks.map((task) => ({ at: past(task.closed), type: "task" })),
    ];
    const last = candidates.filter((item) => item.at).sort((a, b) => a.at!.localeCompare(b.at!)).at(-1);
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
    ...(entity.lastInteractionAt ? { lastInteractionAt: entity.lastInteractionAt, lastInteractionType: entity.lastInteractionType } : {}),
    ...(entity.nextFollowUpAt ? { nextFollowUpAt: entity.nextFollowUpAt } : {}),
  });
  const sortEntities = (a: CrmEntitySummary, b: CrmEntitySummary) =>
    (b.lastInteractionAt || "").localeCompare(a.lastInteractionAt || "") || a.title.localeCompare(b.title);
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

export function crmIndex(root: string, options: CrmIndexOptions & { kind?: "people" | "companies"; stage?: string; query?: string; limit?: number } = {}): CrmIndex & { total: { people: number; companies: number } } {
  const { index } = buildCrm(root, options);
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
  const people = options.kind === "companies" ? [] : filter(index.people);
  const companies = options.kind === "people" ? [] : filter(index.companies);
  return { ...index, people: people.slice(0, limit), companies: companies.slice(0, limit), total: { people: people.length, companies: companies.length } };
}

// MARK: - Resolve and show

function resolveEntity(built: BuiltIndex, refRaw: string): EntityRecord {
  const ref = String(refRaw || "").trim();
  if (!ref) throw new Error("an entity reference is required (ID, title, email, domain or ledger:LEDGER/ID)");
  const lower = ref.toLowerCase();
  const direct = built.entities.get(ref) || built.entities.get(`id:${lower.replace(/^id:/, "")}`);
  if (direct) return direct;
  const matches = resolveCandidates(built, ref);
  if (matches.length === 1) return built.entities.get(matches[0]!.key)!;
  if (!matches.length) throw new Error(`no person or company matches ${ref}`);
  throw new Error(`${ref} is ambiguous: ${matches.slice(0, 6).map((match) => `${match.title} (${match.key})`).join(", ")}`);
}

function resolveCandidates(built: BuiltIndex, query: string): Array<{ key: string; title: string; kind: CrmEntityKind; match: string }> {
  const lower = query.trim().toLowerCase();
  const out = new Map<string, { key: string; title: string; kind: CrmEntityKind; match: string }>();
  const add = (key: string | undefined, match: string) => {
    const entity = key ? built.entities.get(key) : undefined;
    if (entity && !out.has(entity.key)) out.set(entity.key, { key: entity.key, title: entity.title, kind: entity.kind, match });
  };
  for (const email of emailsIn(lower)) {
    // An exact person match wins; otherwise fall back to the company domain.
    if (built.byEmail.has(email)) { add(built.byEmail.get(email), "email"); continue; }
    const domain = emailDomain(email);
    if (domain) add(built.byDomain.get(domain), "email-domain");
  }
  if (!out.size) {
    const domain = normalizeDomain(lower);
    if (domain && !lower.includes(" ")) add(built.byDomain.get(domain), "domain");
  }
  if (!out.size) {
    const name = normalizeCrmName(query);
    for (const entity of built.entities.values()) {
      if ([entity.title, ...entity.aliases].some((label) => normalizeCrmName(label) === name)) add(entity.key, "name");
    }
  }
  if (!out.size) {
    for (const entity of built.entities.values()) {
      if (entity.ledgerAccounts.some((ref) => `${ref.ledger}/${ref.id}` === lower || ref.id === lower)) add(entity.key, "ledger");
    }
  }
  return [...out.values()];
}

export function crmResolve(root: string, query: string, options: CrmIndexOptions = {}) {
  const built = buildCrm(root, options);
  const matches = resolveCandidates(built, query).map((match) => {
    const entity = built.entities.get(match.key)!;
    return { ...match, source: entity.source, id: entity.id, file: entity.file, stage: entity.stage, ledgerAccounts: entity.ledgerAccounts.map((ref) => ({ ledger: ref.ledger, id: ref.id, state: ref.state, workStatus: ref.workStatus })) };
  });
  return { schema: "org2:crm-resolution:v1" as const, query, found: matches.length > 0, ambiguous: matches.length > 1, matches };
}

function outreachItems(root: string, entity: EntityRecord): CrmTimelineItem[] {
  const items: CrmTimelineItem[] = [];
  for (const ref of entity.ledgerAccounts) {
    let events: WorkLedgerEvent[] = [];
    try { events = loadWorkLedgerAccount(root, ref.ledger, ref.id).account.events; } catch { continue; }
    for (const event of events) {
      const label = event.type.replace(/-/g, " ");
      items.push({
        key: `outreach:${ref.ledger}/${ref.id}:${event.id}`,
        type: "outreach",
        title: label.charAt(0).toUpperCase() + label.slice(1),
        at: crmTimeFrom(event.at) || event.at,
        file: ref.file,
        ...(event.note ? { detail: event.note.slice(0, 500) } : {}),
        via: ref.ledger,
      });
    }
  }
  return items;
}

export function crmShow(root: string, ref: string, options: CrmIndexOptions & { days?: number } = {}) {
  const built = buildCrm(root, options);
  const entity = resolveEntity(built, ref);
  const summary = (entity.kind === "person" ? built.index.people : built.index.companies).find((item) => item.key === entity.key)!;
  const timeline = [...entity.timeline.values(), ...outreachItems(built.root, entity)];
  const tasks = [...entity.tasks.values()].sort((a, b) => Number(b.open) - Number(a.open) || compareTasks(a, b));
  for (const task of tasks) if (!task.open) timeline.push({ key: `task:${task.key}`, type: "task", title: task.title, at: task.closed, file: task.file, line: task.line, detail: task.todo, ...(task.via ? { via: task.via } : {}) });
  const upcoming = crmUpcomingFromBuilt(built, options.days ?? 30).filter((item) =>
    item.people.some((person) => person.key === entity.key) || item.companies.some((company) => company.key === entity.key)
    || (entity.kind === "company" && item.people.some((person) => entity.people.some((member) => member.key === person.key))));
  for (const item of upcoming) timeline.push({ key: `calendar:${item.event.eventId}`, type: "calendar", title: item.event.title, at: item.event.start, ...(item.event.htmlLink ? { url: item.event.htmlLink } : {}) });
  timeline.sort((a, b) => (b.at || "").localeCompare(a.at || "") || a.key.localeCompare(b.key));
  const properties = entity.node ? entity.node.properties : {};
  return {
    schema: CRM_ENTITY_SCHEMA,
    entity: summary,
    revision: entity.file && entity.source === "note" ? readGuardedFile(path.join(built.root, entity.file)).revision : null,
    properties,
    tasks,
    timeline: timeline.slice(0, 400),
    upcoming,
    stages: built.index.stages,
  };
}

// MARK: - Calendar briefs

export interface CrmUpcomingMeeting {
  event: { eventId: string; calendarId: string; title: string; start: string; end: string; allDay: boolean; htmlLink?: string; meetingUrl?: string };
  people: Array<{ key: string; title: string; email: string }>;
  companies: Array<{ key: string; title: string; stage: string; lastInteractionAt?: string; openTaskCount: number; nextTask?: CrmTask; lastOutreachAt?: string }>;
  unknownAttendees: string[];
}

function crmUpcomingFromBuilt(built: BuiltIndex, days: number): CrmUpcomingMeeting[] {
  const from = built.now;
  const to = new Date(from.getTime() + Math.max(1, days) * 86_400_000);
  const events = loadStagedCalendarEvents(built.root, from, to);
  const summaries = new Map([...built.index.people, ...built.index.companies].map((item) => [item.key, item]));
  const out: CrmUpcomingMeeting[] = [];
  for (const event of events) {
    if (event.selfResponse === "declined") continue;
    const selfDomains = new Set(built.selfDomains);
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
      const personKey = built.byEmail.get(email);
      if (personKey) {
        const person = summaries.get(personKey)!;
        people.set(personKey, { key: personKey, title: person.title, email });
        if (person.company) addCompany(person.company.key);
        continue;
      }
      const companyKey = domain ? built.byDomain.get(domain) : undefined;
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
  const built = buildCrm(root, options);
  return { schema: "org2:crm-upcoming:v1" as const, generatedAt: built.now.toISOString(), days: options.days ?? 7, meetings: crmUpcomingFromBuilt(built, options.days ?? 7) };
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
