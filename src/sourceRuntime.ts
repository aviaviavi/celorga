import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { findConfigFile, loadConfig, type Org2ExternalSourceConfig } from "./config.js";
import { org2CorpusIndexDir } from "./indexPaths.js";
import { importCrawlerArchive, importSourceRecords } from "./sourceIngestion.js";
import {
  DEFAULT_EMAIL_PASSWORD_ENV,
  checkEmailSource,
  emailCredentialAvailable,
  emailSourceSettings,
  emailSourceStatePath,
  fetchEmailRecords,
  readEmailSourceState,
  resolveEmailPassword,
} from "./emailSource.js";
import { schemaMatches } from "./brandNames.js";
import {
  GOOGLE_CALENDAR_CREDENTIAL_ENV,
  fetchGoogleCalendarRecords,
  googleCalendarAccessToken,
  googleCalendarCredentialAvailable,
  googleCalendarSourceSettings,
} from "./googleCalendarSource.js";

export type SourceBinding = {
  binary?: string;
  configPath?: string;
  workingDirectory?: string;
  /** Email: environment variable holding the account password (default ORG2_EMAIL_PASSWORD). */
  passwordEnv?: string;
  /** Email: machine-local shell command that prints the password (for example a Keychain lookup). */
  passwordCommand?: string;
};

type SourceBindingsEnvelope = {
  schemaVersion: 1;
  bindings: Record<string, SourceBinding>;
};

type SourceStatus = {
  id: string;
  type: Org2ExternalSourceConfig["type"];
  enabled: boolean;
  scopes: string[];
  workspaceId?: string;
  rawZone: string;
  reviewZone: string;
  ingestionSince?: string;
  ingestionLimit: number;
  syncArgs: string[];
  media: "lazy" | "metadata-only";
  schedule?: {
    enabled: boolean;
    kind: "interval" | "daily";
    everyMinutes?: number;
    time?: string;
    timezone: string;
  };
  bindingPath: string;
  binary: string;
  binaryAvailable: boolean;
  configPath?: string;
  configAvailable: boolean;
  ready: boolean;
  /** Email: IMAP account summary and where the password will come from. */
  email?: { host: string; port: number; security: string; username: string; mailboxes: string[]; smtp?: { host: string; port: number } };
  /** Google Calendar: calendars and window. */
  googleCalendar?: { calendars: string[]; lookaheadDays: number };
  credentialAvailable?: boolean;
  setupError?: string;
};

const DEFAULT_CRAWLER_TIMEOUT_MS = 30 * 60_000;
const MAX_CRAWLER_TIMEOUT_SECONDS = 24 * 60 * 60;
const SOURCE_SYNC_LOCK_SCHEMA = "org2:source-sync-lock:v1";
const SOURCE_SYNC_LOCK_OWNER_FILE = "owner.json";
const SOURCE_SYNC_LOCK_STARTUP_GRACE_MS = 30_000;
const SOURCE_SYNC_LOCK_EXPIRY_GRACE_MS = 5 * 60_000;

type SourceSyncLockOwner = {
  schema: typeof SOURCE_SYNC_LOCK_SCHEMA;
  token: string;
  pid: number;
  sourceId: string;
  corpusRoot: string;
  hostname: string;
  startedAt: string;
  timeoutMs: number;
};

type AcquiredSourceSyncLock = {
  owner: SourceSyncLockOwner;
  recoveredStaleLock: boolean;
};

function sourceSyncLockOwnerPath(lockDir: string): string {
  return path.join(lockDir, SOURCE_SYNC_LOCK_OWNER_FILE);
}

function readSourceSyncLockOwner(lockDir: string): SourceSyncLockOwner | null {
  try {
    const value = JSON.parse(fs.readFileSync(sourceSyncLockOwnerPath(lockDir), "utf8")) as Partial<SourceSyncLockOwner>;
    if (!schemaMatches(value.schema, SOURCE_SYNC_LOCK_SCHEMA)
        || typeof value.token !== "string"
        || !Number.isInteger(value.pid)
        || typeof value.sourceId !== "string"
        || typeof value.corpusRoot !== "string"
        || typeof value.hostname !== "string"
        || typeof value.startedAt !== "string"
        || !Number.isFinite(value.timeoutMs)) return null;
    return value as SourceSyncLockOwner;
  } catch {
    return null;
  }
}

function processIsAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function sourceSyncLockIsStale(lockDir: string, sourceId: string, corpusRoot: string, now = Date.now()): boolean {
  let modifiedAt = 0;
  try {
    modifiedAt = fs.statSync(lockDir).mtimeMs;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return true;
    throw error;
  }
  if (now - modifiedAt < SOURCE_SYNC_LOCK_STARTUP_GRACE_MS) return false;

  const owner = readSourceSyncLockOwner(lockDir);
  if (!owner) return true;
  if (owner.sourceId !== sourceId || path.resolve(owner.corpusRoot) !== path.resolve(corpusRoot)) return true;
  if (!processIsAlive(owner.pid)) return true;

  const startedAt = Date.parse(owner.startedAt);
  if (!Number.isFinite(startedAt)) return false;
  // A sync can spend one timeout in the crawler and another in ingestion.
  // The grace keeps PID reuse or a wedged parent from blocking the source forever.
  const maximumOwnerAge = Math.max(
    SOURCE_SYNC_LOCK_STARTUP_GRACE_MS,
    owner.timeoutMs * 2 + SOURCE_SYNC_LOCK_EXPIRY_GRACE_MS,
  );
  return now - startedAt > maximumOwnerAge;
}

function acquireSourceSyncLock(
  lockDir: string,
  sourceId: string,
  corpusRoot: string,
  timeoutMs: number,
): AcquiredSourceSyncLock | null {
  const owner: SourceSyncLockOwner = {
    schema: SOURCE_SYNC_LOCK_SCHEMA,
    token: randomUUID(),
    pid: process.pid,
    sourceId,
    corpusRoot: path.resolve(corpusRoot),
    hostname: os.hostname(),
    startedAt: new Date().toISOString(),
    timeoutMs,
  };
  let recoveredStaleLock = false;

  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      fs.mkdirSync(lockDir);
      try {
        fs.writeFileSync(sourceSyncLockOwnerPath(lockDir), JSON.stringify(owner, null, 2) + "\n", { mode: 0o600 });
      } catch (error) {
        fs.rmSync(lockDir, { recursive: true, force: true });
        throw error;
      }
      return { owner, recoveredStaleLock };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      if (!sourceSyncLockIsStale(lockDir, sourceId, corpusRoot)) return null;

      const abandonedDir = `${lockDir}.abandoned-${process.pid}-${randomUUID()}`;
      try {
        fs.renameSync(lockDir, abandonedDir);
      } catch (renameError) {
        const code = (renameError as NodeJS.ErrnoException).code;
        if (code === "ENOENT" || code === "EEXIST") continue;
        throw renameError;
      }
      fs.rmSync(abandonedDir, { recursive: true, force: true });
      recoveredStaleLock = true;
    }
  }
  throw new Error(`could not acquire source sync lock after recovering stale ownership: ${lockDir}`);
}

function releaseSourceSyncLock(lockDir: string, owner: SourceSyncLockOwner): void {
  const current = readSourceSyncLockOwner(lockDir);
  if (current?.token !== owner.token) return;
  fs.rmSync(lockDir, { recursive: true, force: true });
}

function normalizedSchedule(id: string, profile: Org2ExternalSourceConfig): SourceStatus["schedule"] {
  const schedule = profile.schedule;
  if (!schedule) return undefined;
  const timezone = String(schedule.timezone || "local").trim() || "local";
  if (timezone !== "local") {
    try {
      new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format(new Date());
    } catch {
      throw new Error(`external source ${id} schedule timezone is invalid: ${timezone}`);
    }
  }
  if (schedule.kind === "interval") {
    const everyMinutes = Number(schedule.everyMinutes);
    if (!Number.isInteger(everyMinutes) || everyMinutes <= 0) {
      throw new Error(`external source ${id} interval schedule requires a positive integer everyMinutes`);
    }
    return { enabled: schedule.enabled !== false, kind: "interval", everyMinutes, timezone };
  }
  if (schedule.kind === "daily") {
    const time = String(schedule.time || "").trim();
    if (!/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(time)) {
      throw new Error(`external source ${id} daily schedule requires time in HH:MM form`);
    }
    return { enabled: schedule.enabled !== false, kind: "daily", time, timezone };
  }
  throw new Error(`external source ${id} schedule kind must be interval or daily`);
}

export const EXTERNAL_SOURCE_TYPES = ["slack", "notion", "email", "google-calendar"] as const;

const EXTERNAL_SOURCE_KEYS = new Set([
  "type", "email", "googleCalendar", "enabled", "scopes", "workspaceId", "rawZone", "media", "syncArgs", "ingestion", "schedule",
]);
const SECRET_KEY_PATTERN = /token|password|passwd|secret|api[-_]?key|credential|cookie/i;
const SECRET_VALUE_PATTERN = /^(?:xox[abposr]-|xapp-|secret_|ntn_)/;

function assertStringList(id: string, key: string, value: unknown): void {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`external source ${id} ${key} must be a list of strings`);
  }
}

function assertCorpusRelative(id: string, key: string, value: unknown): void {
  if (typeof value !== "string" || !value.trim()) throw new Error(`external source ${id} ${key} must be a non-empty path`);
  const normalized = path.posix.normalize(value.replace(/\\/g, "/"));
  if (path.posix.isAbsolute(normalized) || normalized === ".." || normalized.startsWith("../")) {
    throw new Error(`external source ${id} ${key} must stay inside the corpus`);
  }
}

function assertNoSecrets(id: string, value: unknown, where: string): void {
  if (typeof value === "string") {
    if (SECRET_VALUE_PATTERN.test(value.trim())) throw new Error(`external source ${id} ${where} looks like a credential; keep secrets out of celorga.json`);
    return;
  }
  if (Array.isArray(value)) { value.forEach((item, index) => assertNoSecrets(id, item, `${where}[${index}]`)); return; }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      if (SECRET_KEY_PATTERN.test(key)) throw new Error(`external source ${id} must not store ${key} in celorga.json; credentials stay machine-local`);
      assertNoSecrets(id, child, where ? `${where}.${key}` : key);
    }
  }
}

/**
 * Validates one celorga.json externalSources entry. The shared contract behind
 * `celorga source add` and the Celorga app's source sheet: only known, non-secret keys.
 */
export function validateExternalSourceProfile(id: string, value: unknown): Org2ExternalSourceConfig {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(id)) throw new Error("source PROFILE ids use letters, digits, ., _, or - (at most 64 characters)");
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`external source ${id} must be a JSON object`);
  const profile = value as Record<string, unknown>;
  assertNoSecrets(id, profile, "");
  for (const key of Object.keys(profile)) {
    if (!EXTERNAL_SOURCE_KEYS.has(key)) throw new Error(`external source ${id} has unknown key ${key}`);
  }
  if (!EXTERNAL_SOURCE_TYPES.includes(profile.type as typeof EXTERNAL_SOURCE_TYPES[number])) {
    throw new Error(`external source ${id} type must be one of ${EXTERNAL_SOURCE_TYPES.join(", ")}`);
  }
  if (profile.enabled !== undefined && typeof profile.enabled !== "boolean") throw new Error(`external source ${id} enabled must be true or false`);
  if (profile.scopes !== undefined) assertStringList(id, "scopes", profile.scopes);
  if (profile.syncArgs !== undefined) assertStringList(id, "syncArgs", profile.syncArgs);
  if (profile.workspaceId !== undefined && typeof profile.workspaceId !== "string") throw new Error(`external source ${id} workspaceId must be a string`);
  if (profile.rawZone !== undefined) assertCorpusRelative(id, "rawZone", profile.rawZone);
  if (profile.media !== undefined && profile.media !== "lazy" && profile.media !== "metadata-only") {
    throw new Error(`external source ${id} media must be lazy or metadata-only`);
  }
  if (profile.ingestion !== undefined) {
    const ingestion = profile.ingestion as Record<string, unknown>;
    if (!ingestion || typeof ingestion !== "object" || Array.isArray(ingestion)) throw new Error(`external source ${id} ingestion must be an object`);
    for (const key of Object.keys(ingestion)) {
      if (!["since", "maxItems", "reviewZone"].includes(key)) throw new Error(`external source ${id} ingestion has unknown key ${key}`);
    }
    if (ingestion.since !== undefined && (typeof ingestion.since !== "string" || !ingestion.since.trim())) {
      throw new Error(`external source ${id} ingestion.since must be a window such as 14d or a timestamp`);
    }
    if (ingestion.maxItems !== undefined && (!Number.isInteger(ingestion.maxItems) || (ingestion.maxItems as number) <= 0)) {
      throw new Error(`external source ${id} ingestion.maxItems must be a positive integer`);
    }
    if (ingestion.reviewZone !== undefined) assertCorpusRelative(id, "ingestion.reviewZone", ingestion.reviewZone);
  }
  const typed = profile as Org2ExternalSourceConfig;
  if (typed.schedule !== undefined) normalizedSchedule(id, typed);
  if (typed.type === "email") emailSourceSettings(id, typed);
  else if (typed.email !== undefined) throw new Error(`external source ${id} email settings apply only to type email`);
  if (typed.type === "google-calendar") googleCalendarSourceSettings(id, typed);
  else if (typed.googleCalendar !== undefined) throw new Error(`external source ${id} googleCalendar settings apply only to type google-calendar`);
  return typed;
}

/** Merges an update into an existing profile; `null` removes a key. */
export function mergeExternalSourceProfile(existing: Org2ExternalSourceConfig, update: Record<string, unknown>): Record<string, unknown> {
  const merged: Record<string, unknown> = { ...existing };
  for (const [key, value] of Object.entries(update)) {
    if (value === null) delete merged[key];
    else if (key === "ingestion" && value && typeof value === "object" && !Array.isArray(value)) {
      const ingestion: Record<string, unknown> = { ...(existing.ingestion || {}) };
      for (const [child, childValue] of Object.entries(value)) {
        if (childValue === null) delete ingestion[child];
        else ingestion[child] = childValue;
      }
      if (Object.keys(ingestion).length) merged.ingestion = ingestion;
      else delete merged.ingestion;
    } else merged[key] = value;
  }
  return merged;
}

function usage(): string {
  return `External source commands:
  celorga source list [--dir CORPUS] [--json]
  celorga source doctor [PROFILE...] [--timeout SECONDS] [--dir CORPUS] [--json]
  celorga source bind PROFILE [--binary PATH] [--config PATH] [--working-directory PATH] [--password-env VAR] [--password-command CMD] [--dir CORPUS] [--apply] [--json]
  celorga source add PROFILE --source-json JSON [--update] [--dir CORPUS] [--apply] [--json]
  celorga source add-email PROFILE --host HOST --username USER [--port 993] [--security tls|starttls] [--mailbox INBOX]... [--smtp-host HOST --smtp-port 587] [--dir CORPUS] [--apply] [--json]
  celorga source schedule PROFILE (--pause|--resume) [--dir CORPUS] [--apply] [--json]
  celorga source schedule PROFILE --kind interval --every-minutes N [--timezone ZONE] [--dir CORPUS] [--apply] [--json]
  celorga source schedule PROFILE --kind daily --time HH:MM [--timezone ZONE] [--dir CORPUS] [--apply] [--json]
  celorga source status [PROFILE...] [--timeout SECONDS] [--dir CORPUS] [--json]
  celorga source import [PROFILE...] [--since 14d|TIMESTAMP] [--limit N] [--timeout SECONDS] [--dir CORPUS] [--apply] [--json]
  celorga source sync [PROFILE...] [--ingest] [--since 14d|TIMESTAMP] [--limit N] [--timeout SECONDS] [--dir CORPUS] [--apply] [--json]

The corpus declares non-secret externalSources in celorga.json; \`source add\` validates one entry of any
supported type (${EXTERNAL_SOURCE_TYPES.join(", ")}) and refuses credential-like keys or values. Machine-local bindings are stored
outside the corpus under ORG2_INDEX_HOME (or ~/.org2/index). Slack and Notion sync delegates to
slacrawl/notcrawl. Email profiles read IMAP directly (read-only EXAMINE and BODY.PEEK, so mail is not
marked read) and keep a machine-local UID cursor; the password comes from ORG2_EMAIL_PASSWORD, a
--password-env or --password-command binding, or the Celorga app's Keychain, and never enters the corpus.
Google Calendar profiles read the Calendar API directly and stage a snapshot of the configured window
(ingestion.since back, googleCalendar.lookaheadDays ahead). Sign in from the Celorga app's Sources view;
the app sends the credential to the connected server, which syncs with ${GOOGLE_CALENDAR_CREDENTIAL_ENV}.`;
}

function optionValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("-")) throw new Error(`${option} requires a value`);
  return value;
}

function parseArgs(args: string[]) {
  const positional: string[] = [];
  let dir = "";
  let json = false;
  let apply = false;
  let ingest = false;
  let binary: string | undefined;
  let configPath: string | undefined;
  let workingDirectory: string | undefined;
  let since: string | undefined;
  let limit: number | undefined;
  let pause = false;
  let resume = false;
  let scheduleKind: "interval" | "daily" | undefined;
  let everyMinutes: number | undefined;
  let scheduleTime: string | undefined;
  let timezone: string | undefined;
  let timeoutMs = DEFAULT_CRAWLER_TIMEOUT_MS;
  let passwordEnv: string | undefined;
  let passwordCommand: string | undefined;
  let host: string | undefined;
  let username: string | undefined;
  let port: number | undefined;
  let security: string | undefined;
  const mailboxes: string[] = [];
  let smtpHost: string | undefined;
  let smtpPort: number | undefined;
  let sourceJSON: string | undefined;
  let update = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]!;
    if (arg === "--dir") {
      dir = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--json") json = true;
    else if (arg === "--format") {
      const format = optionValue(args, i, arg);
      i += 1;
      if (format !== "json") throw new Error("source --format must be json");
      json = true;
    } else if (arg === "--apply") apply = true;
    else if (arg === "--ingest") ingest = true;
    else if (arg === "--pause") pause = true;
    else if (arg === "--resume") resume = true;
    else if (arg === "--binary") {
      binary = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--config") {
      configPath = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--working-directory") {
      workingDirectory = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--since") {
      since = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--limit") {
      const value = Number(optionValue(args, i, arg));
      if (!Number.isInteger(value) || value <= 0) throw new Error("source --limit must be a positive integer");
      limit = value;
      i += 1;
    } else if (arg === "--kind") {
      const value = optionValue(args, i, arg);
      if (value !== "interval" && value !== "daily") throw new Error("source --kind must be interval or daily");
      scheduleKind = value;
      i += 1;
    } else if (arg === "--every-minutes") {
      const value = Number(optionValue(args, i, arg));
      if (!Number.isInteger(value) || value <= 0) throw new Error("source --every-minutes must be a positive integer");
      everyMinutes = value;
      i += 1;
    } else if (arg === "--time") {
      scheduleTime = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--timezone") {
      timezone = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--timeout") {
      const seconds = Number(optionValue(args, i, arg));
      if (!Number.isFinite(seconds) || seconds <= 0 || seconds > MAX_CRAWLER_TIMEOUT_SECONDS) {
        throw new Error(`source --timeout must be a positive number of seconds no greater than ${MAX_CRAWLER_TIMEOUT_SECONDS}`);
      }
      timeoutMs = Math.max(1, Math.ceil(seconds * 1_000));
      i += 1;
    } else if (arg === "--password-env") {
      passwordEnv = optionValue(args, i, arg);
      if (!/^[A-Z_][A-Z0-9_]*$/.test(passwordEnv)) throw new Error("source --password-env must be an environment variable name");
      i += 1;
    } else if (arg === "--password-command") {
      passwordCommand = args[i + 1];
      if (!passwordCommand) throw new Error("--password-command requires a value");
      i += 1;
    } else if (arg === "--host") {
      host = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--username") {
      username = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--port" || arg === "--smtp-port") {
      const value = Number(optionValue(args, i, arg));
      if (!Number.isInteger(value) || value <= 0 || value > 65_535) throw new Error(`source ${arg} must be a TCP port`);
      if (arg === "--port") port = value; else smtpPort = value;
      i += 1;
    } else if (arg === "--security") {
      security = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--mailbox") {
      mailboxes.push(optionValue(args, i, arg));
      i += 1;
    } else if (arg === "--smtp-host") {
      smtpHost = optionValue(args, i, arg);
      i += 1;
    } else if (arg === "--source-json") {
      sourceJSON = args[i + 1];
      if (!sourceJSON) throw new Error("--source-json requires a value");
      i += 1;
    } else if (arg === "--update") update = true;
    else if (arg === "--help" || arg === "-h") positional.push("help");
    else if (arg.startsWith("-")) throw new Error(`unknown source option: ${arg}`);
    else positional.push(arg);
  }
  return {
    positional, dir, json, apply, ingest, binary, configPath, workingDirectory, since, limit,
    pause, resume, scheduleKind, everyMinutes, scheduleTime, timezone, timeoutMs,
    passwordEnv, passwordCommand, host, username, port, security, mailboxes, smtpHost, smtpPort,
    sourceJSON, update,
  };
}

function resolveCorpus(dir: string): { root: string; configFile: string; profiles: Record<string, Org2ExternalSourceConfig> } {
  const start = path.resolve(dir || process.cwd());
  const configFile = findConfigFile(start);
  if (!configFile) throw new Error(`no celorga.json found from ${start}`);
  const root = path.dirname(configFile);
  return { root, configFile, profiles: loadConfig(configFile).externalSources || {} };
}

function writeJSONAtomic(file: string, value: unknown): void {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n", "utf8");
    fs.renameSync(temporary, file);
  } finally {
    try { fs.rmSync(temporary, { force: true }); } catch {}
  }
}

export function sourceBindingsPath(root: string): string {
  return path.join(org2CorpusIndexDir(root), "source-bindings-v1.json");
}

function readBindings(root: string): SourceBindingsEnvelope {
  const file = sourceBindingsPath(root);
  if (!fs.existsSync(file)) return { schemaVersion: 1, bindings: {} };
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as SourceBindingsEnvelope;
  if (parsed.schemaVersion !== 1 || !parsed.bindings || typeof parsed.bindings !== "object") {
    throw new Error(`invalid source bindings file: ${file}`);
  }
  return parsed;
}

function binaryFor(profile: Org2ExternalSourceConfig, binding: SourceBinding): string {
  return binding.binary || (profile.type === "slack" ? "slacrawl" : "notcrawl");
}

function configFor(profile: Org2ExternalSourceConfig, binding: SourceBinding): string {
  return path.resolve(binding.configPath || path.join(os.homedir(), profile.type === "slack" ? ".slacrawl/config.toml" : ".notcrawl/config.toml"));
}

function commandAvailable(binary: string): boolean {
  if (binary.includes(path.sep)) return fs.existsSync(path.resolve(binary));
  return spawnSync("/usr/bin/env", ["which", binary], { encoding: "utf8" }).status === 0;
}

function statuses(root: string, profiles: Record<string, Org2ExternalSourceConfig>): SourceStatus[] {
  const bindingFile = sourceBindingsPath(root);
  const bindings = readBindings(root).bindings;
  return Object.entries(profiles).sort(([a], [b]) => a.localeCompare(b)).map(([id, profile]) => {
    const binding = bindings[id] || {};
    if (profile.type === "email") return emailStatus(id, profile, binding, bindingFile);
    if (profile.type === "google-calendar") return googleCalendarStatus(id, profile, bindingFile);
    const binary = binaryFor(profile, binding);
    const configPath = configFor(profile, binding);
    const binaryAvailable = commandAvailable(binary);
    const configAvailable = fs.existsSync(configPath);
    return {
      id,
      type: profile.type,
      enabled: profile.enabled !== false,
      scopes: profile.scopes || [],
      ...(profile.workspaceId ? { workspaceId: profile.workspaceId } : {}),
      rawZone: profile.rawZone || `raw/connectors/${profile.type}/${id}`,
      reviewZone: profile.ingestion?.reviewZone || `views/connectors/${profile.type}/${id}`,
      ...(profile.ingestion?.since ? { ingestionSince: profile.ingestion.since } : {}),
      ingestionLimit: profile.ingestion?.maxItems || 5_000,
      syncArgs: profile.syncArgs || (profile.type === "slack" ? ["--source", "api", "--latest-only"] : ["--source", "api"]),
      media: profile.media || "metadata-only",
      ...(profile.schedule ? { schedule: normalizedSchedule(id, profile) } : {}),
      bindingPath: bindingFile,
      binary,
      binaryAvailable,
      configPath,
      configAvailable,
      ready: profile.enabled !== false && binaryAvailable && configAvailable,
    };
  });
}

function emailStatus(id: string, profile: Org2ExternalSourceConfig, binding: SourceBinding, bindingFile: string): SourceStatus {
  let email: SourceStatus["email"];
  let setupError: string | undefined;
  try {
    const settings = emailSourceSettings(id, profile);
    email = {
      host: settings.host,
      port: settings.port,
      security: settings.security,
      username: settings.username,
      mailboxes: settings.mailboxes,
      ...(settings.smtp ? { smtp: { host: settings.smtp.host, port: settings.smtp.port } } : {}),
    };
  } catch (error) {
    setupError = error instanceof Error ? error.message : String(error);
  }
  const credentialAvailable = emailCredentialAvailable(binding);
  return {
    id,
    type: "email",
    enabled: profile.enabled !== false,
    scopes: profile.scopes || [],
    rawZone: profile.rawZone || `raw/connectors/email/${id}`,
    reviewZone: profile.ingestion?.reviewZone || `views/connectors/email/${id}`,
    ...(profile.ingestion?.since ? { ingestionSince: profile.ingestion.since } : {}),
    ingestionLimit: profile.ingestion?.maxItems || 5_000,
    syncArgs: [],
    media: profile.media || "metadata-only",
    ...(profile.schedule ? { schedule: normalizedSchedule(id, profile) } : {}),
    bindingPath: bindingFile,
    binary: "celorga (built-in IMAP)",
    binaryAvailable: true,
    configAvailable: !setupError,
    // The password may also arrive from the Celorga app's Keychain at sync time.
    ready: profile.enabled !== false && !setupError,
    ...(email ? { email } : {}),
    credentialAvailable,
    ...(setupError ? { setupError } : {}),
  };
}

function googleCalendarStatus(id: string, profile: Org2ExternalSourceConfig, bindingFile: string): SourceStatus {
  let googleCalendar: SourceStatus["googleCalendar"];
  let setupError: string | undefined;
  try {
    const settings = googleCalendarSourceSettings(id, profile);
    googleCalendar = { calendars: settings.calendars, lookaheadDays: settings.lookaheadDays };
  } catch (error) {
    setupError = error instanceof Error ? error.message : String(error);
  }
  return {
    id,
    type: "google-calendar",
    enabled: profile.enabled !== false,
    scopes: profile.scopes || [],
    rawZone: profile.rawZone || `raw/connectors/google-calendar/${id}`,
    reviewZone: profile.ingestion?.reviewZone || `views/connectors/google-calendar/${id}`,
    ...(profile.ingestion?.since ? { ingestionSince: profile.ingestion.since } : {}),
    ingestionLimit: profile.ingestion?.maxItems || 5_000,
    syncArgs: [],
    media: profile.media || "metadata-only",
    ...(profile.schedule ? { schedule: normalizedSchedule(id, profile) } : {}),
    bindingPath: bindingFile,
    binary: "celorga (built-in Google Calendar)",
    binaryAvailable: true,
    configAvailable: !setupError,
    // The credential arrives from the Celorga app (Keychain or the server's store) at sync time.
    ready: profile.enabled !== false && !setupError,
    ...(googleCalendar ? { googleCalendar } : {}),
    credentialAvailable: googleCalendarCredentialAvailable(),
    ...(setupError ? { setupError } : {}),
  };
}

async function importGoogleCalendarProfile(options: {
  root: string;
  id: string;
  profile: Org2ExternalSourceConfig;
  limit?: number;
  timeoutMs: number;
  apply: boolean;
}) {
  const settings = googleCalendarSourceSettings(options.id, options.profile);
  const timeoutMs = Math.min(options.timeoutMs, 120_000);
  const accessToken = await googleCalendarAccessToken(process.env, timeoutMs);
  const fetched = await fetchGoogleCalendarRecords({ settings, accessToken, timeoutMs });
  const imported = importSourceRecords({
    root: options.root,
    profileId: options.id,
    profile: options.profile,
    since: settings.lookback,
    limit: options.limit,
    apply: options.apply,
  }, fetched.records);
  return { imported, calendars: fetched.calendars, window: fetched.window };
}

function emailPassword(id: string, binding: SourceBinding): string {
  const resolved = resolveEmailPassword(binding);
  if (!resolved.password) throw new Error(`email source ${id} has no password: ${resolved.source}`);
  return resolved.password;
}

async function importEmailProfile(options: {
  root: string;
  id: string;
  profile: Org2ExternalSourceConfig;
  binding: SourceBinding;
  since?: string;
  limit?: number;
  timeoutMs: number;
  apply: boolean;
}) {
  const settings = emailSourceSettings(options.id, options.profile);
  const limit = Math.max(1, Math.min(options.limit || options.profile.ingestion?.maxItems || 5_000, 50_000));
  const sinceRaw = options.since || options.profile.ingestion?.since;
  const relative = sinceRaw?.match(/^(\d+)([dhwm])$/i);
  const sinceTimestamp = sinceRaw
    ? relative
      ? Date.now() - Number(relative[1]) * ({ m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 }[relative[2]!.toLowerCase() as "m" | "h" | "d" | "w"])
      : Date.parse(sinceRaw)
    : undefined;
  if (sinceTimestamp !== undefined && !Number.isFinite(sinceTimestamp)) throw new Error(`invalid source --since value: ${sinceRaw}`);
  const fetched = await fetchEmailRecords({
    root: options.root,
    profileId: options.id,
    settings,
    password: emailPassword(options.id, options.binding),
    sinceTimestamp,
    limit,
    advanceCursor: options.apply,
    timeoutMs: Math.min(options.timeoutMs, 120_000),
  });
  const imported = importSourceRecords({
    root: options.root,
    profileId: options.id,
    profile: options.profile,
    since: options.since,
    limit: options.limit,
    apply: options.apply,
  }, fetched.records);
  return { imported, mailboxes: fetched.mailboxes };
}

function googleCalendarStatePath(root: string, id: string): string {
  return path.join(org2CorpusIndexDir(root), `source-google-calendar-${id.replace(/[^A-Za-z0-9_.-]/gu, "_")}-state.json`);
}

/** Machine-local record of this host's last successful Google Calendar sync. */
function readGoogleCalendarLastSync(root: string, id: string): string | null {
  try {
    const value = JSON.parse(fs.readFileSync(googleCalendarStatePath(root, id), "utf8")) as { syncedAt?: unknown };
    return typeof value.syncedAt === "string" ? value.syncedAt : null;
  } catch {
    return null;
  }
}

function writeGoogleCalendarLastSync(root: string, id: string, details: Record<string, unknown>): void {
  const file = googleCalendarStatePath(root, id);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  writeJSONAtomic(file, { schema: "org2:google-calendar-source-state:v1", profile: id, syncedAt: new Date().toISOString(), ...details });
}

function emit(value: unknown, json: boolean): void {
  if (json) process.stdout.write(JSON.stringify(value, null, 2) + "\n");
  else if (Array.isArray(value)) {
    for (const item of value as SourceStatus[]) {
      process.stdout.write(`${item.id}\t${item.type}\t${item.ready ? "ready" : item.enabled ? "needs-setup" : "disabled"}\t${item.binary}\n`);
    }
  } else if (value && typeof value === "object" && "sources" in value) {
    const payload = value as { ok?: boolean; sources: Array<SourceStatus & { doctorOk?: boolean }> };
    process.stdout.write(`${payload.ok === false ? "Source checks need attention" : "Source checks passed"}\n`);
    for (const item of payload.sources) process.stdout.write(`${item.id}\t${item.doctorOk ? "ready" : item.enabled ? "needs-setup" : "disabled"}\n`);
  } else process.stdout.write(String(value) + "\n");
}

function truncateOutput(value: string | null | undefined, max = 8_000): string {
  const text = value || "";
  return text.length <= max ? text : `${text.slice(0, max)}\n… ${text.length - max} characters omitted`;
}

function crawlerProcessError(binary: string, error: Error | undefined, timeoutMs: number): string | undefined {
  if (!error) return undefined;
  if ((error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
    return `${path.basename(binary)} timed out after ${timeoutMs / 1_000} seconds`;
  }
  return `${path.basename(binary)} failed: ${error.message}`;
}

export async function runSourceCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "source" && args[0] !== "sources") return false;
  const parsed = parseArgs(args.slice(1));
  const action = parsed.positional.shift() || "list";
  if (action === "help") { process.stdout.write(usage() + "\n"); return true; }
  const { root, configFile, profiles } = resolveCorpus(parsed.dir);
  const selected = parsed.positional;
  const select = <T extends { id: string }>(items: T[]) => selected.length ? items.filter((item) => selected.includes(item.id)) : items;
  if (action !== "add-email" && action !== "add" && selected.some((id) => !profiles[id])) throw new Error(`unknown external source profile: ${selected.find((id) => !profiles[id])}`);

  if (action === "list" || action === "doctor") {
    const result = select(statuses(root, profiles));
    if (action === "list") emit(result, parsed.json);
    else {
      const bindingsForDoctor = readBindings(root).bindings;
      const checked = [];
      for (const item of result) {
        if (item.type !== "google-calendar") continue;
        if (!item.enabled || !item.ready) { checked.push({ ...item, doctorOk: false }); continue; }
        try {
          await googleCalendarAccessToken(process.env, Math.min(parsed.timeoutMs, 60_000));
          checked.push({ ...item, doctorOk: true });
        } catch (error) {
          checked.push({ ...item, doctorOk: false, doctorError: error instanceof Error ? error.message : String(error) });
        }
      }
      for (const item of result) {
        if (item.type !== "email") continue;
        if (!item.enabled || !item.ready) { checked.push({ ...item, doctorOk: false }); continue; }
        try {
          const settings = emailSourceSettings(item.id, profiles[item.id]!);
          const check = await checkEmailSource(settings, emailPassword(item.id, bindingsForDoctor[item.id] || {}), Math.min(parsed.timeoutMs, 60_000));
          checked.push({ ...item, doctorOk: true, mailboxes: check.mailboxes });
        } catch (error) {
          checked.push({ ...item, doctorOk: false, doctorError: error instanceof Error ? error.message : String(error) });
        }
      }
      checked.push(...result.filter((item) => item.type !== "email" && item.type !== "google-calendar").map((item) => {
        if (!item.enabled || !item.ready) return { ...item, doctorOk: false };
        const child = spawnSync(item.binary, ["--config", item.configPath!, "doctor", "--json"], {
          encoding: "utf8",
          env: process.env,
          timeout: parsed.timeoutMs,
          killSignal: "SIGTERM",
        });
        const doctorError = crawlerProcessError(item.binary, child.error, parsed.timeoutMs);
        return {
          ...item,
          doctorOk: child.status === 0 && !doctorError,
          doctorStatus: child.status,
          ...(doctorError ? { doctorError } : {}),
          ...(parsed.json ? { doctorStdout: child.stdout, doctorStderr: child.stderr } : {}),
        };
      }));
      checked.sort((a, b) => a.id.localeCompare(b.id));
      const ok = checked.every((item) => !item.enabled || item.doctorOk);
      emit({ schema: "org2:source-doctor:v1", root, ok, sources: checked }, parsed.json);
      if (!ok) process.exitCode = 1;
    }
    return true;
  }

  if (action === "status") {
    const result = [];
    for (const item of select(statuses(root, profiles))) {
      if (item.type === "google-calendar") {
        if (!item.googleCalendar) {
          result.push({ id: item.id, type: item.type, ok: false, error: item.setupError || "Google Calendar settings are incomplete" });
          continue;
        }
        const latest = readGoogleCalendarLastSync(root, item.id);
        result.push({
          id: item.id,
          type: item.type,
          ok: true,
          status: 0,
          crawlerStatus: {
            app_id: "org2-google-calendar",
            state: latest ? "synced" : "never-synced",
            summary: `${item.googleCalendar.calendars.join(", ")} · next ${item.googleCalendar.lookaheadDays} days`,
            database_path: googleCalendarStatePath(root, item.id),
            database_bytes: 0,
            last_sync_at: latest,
            counts: [],
          },
        });
        continue;
      }
      if (item.type === "email") {
        if (!item.email) {
          result.push({ id: item.id, type: "email", ok: false, error: item.setupError || "email settings are incomplete" });
          continue;
        }
        const account = `${item.email.username}@${item.email.host}:${item.email.port}`;
        const state = readEmailSourceState(root, item.id, account);
        const cursors = Object.entries(state.mailboxes);
        const lastSyncAt = cursors.map(([, cursor]) => cursor.syncedAt).sort().at(-1) ?? null;
        result.push({
          id: item.id,
          type: "email",
          ok: true,
          status: 0,
          crawlerStatus: {
            app_id: "org2-imap",
            state: cursors.length ? "synced" : "never-synced",
            summary: cursors.length
              ? `${item.email.username} · ${cursors.map(([mailbox, cursor]) => `${mailbox} through UID ${cursor.lastUid}`).join(", ")}`
              : `${item.email.username} on ${item.email.host} has not synced on this machine`,
            database_path: emailSourceStatePath(root, item.id),
            database_bytes: 0,
            last_sync_at: lastSyncAt,
            counts: cursors.map(([mailbox, cursor]) => ({ id: mailbox, label: mailbox, value: cursor.lastUid })),
          },
        });
        continue;
      }
      if (!item.enabled || !item.ready) {
        result.push({ id: item.id, ok: false, skipped: true, error: "source binding is not ready; run celorga source doctor" });
        continue;
      }
      const child = spawnSync(item.binary, ["--config", item.configPath!, "status", "--json"], {
        encoding: "utf8",
        env: process.env,
        maxBuffer: 16 * 1024 * 1024,
        timeout: parsed.timeoutMs,
        killSignal: "SIGTERM",
      });
      const processError = crawlerProcessError(item.binary, child.error, parsed.timeoutMs);
      let crawlerStatus: unknown;
      try { crawlerStatus = JSON.parse(child.stdout || "null"); } catch { crawlerStatus = null; }
      result.push({
        id: item.id,
        type: item.type,
        ok: child.status === 0 && crawlerStatus !== null && !processError,
        status: child.status,
        crawlerStatus,
        ...(processError ? { error: processError } : {}),
        ...(child.status === 0 ? {} : { stderr: truncateOutput(child.stderr) }),
      });
    }
    emit({ schema: "org2:source-status:v1", root, sources: result }, parsed.json);
    if (result.some((item) => !item.ok)) process.exitCode = 1;
    return true;
  }

  if (action === "schedule") {
    const id = selected[0];
    if (!id || selected.length !== 1) throw new Error("celorga source schedule requires exactly one PROFILE");
    if (parsed.pause && parsed.resume) throw new Error("source schedule accepts only one of --pause or --resume");
    const isToggle = parsed.pause || parsed.resume;
    const hasScheduleFields = parsed.scheduleKind !== undefined
      || parsed.everyMinutes !== undefined
      || parsed.scheduleTime !== undefined
      || parsed.timezone !== undefined;
    if (isToggle && hasScheduleFields) throw new Error("source schedule cannot combine --pause or --resume with schedule fields");
    if (!isToggle && !parsed.scheduleKind) {
      throw new Error("source schedule requires --pause, --resume, or --kind interval|daily");
    }

    const profile = profiles[id]!;
    let candidate: Org2ExternalSourceConfig["schedule"];
    if (isToggle) {
      if (!profile.schedule) throw new Error(`external source ${id} has no schedule to ${parsed.pause ? "pause" : "resume"}`);
      candidate = { ...profile.schedule, enabled: parsed.resume };
    } else if (parsed.scheduleKind === "interval") {
      if (parsed.everyMinutes === undefined) throw new Error("interval source schedule requires --every-minutes N");
      if (parsed.scheduleTime !== undefined) throw new Error("interval source schedule does not accept --time");
      candidate = {
        enabled: profile.schedule?.enabled !== false,
        kind: "interval",
        everyMinutes: parsed.everyMinutes,
        timezone: parsed.timezone || profile.schedule?.timezone || "local",
      };
    } else {
      if (parsed.scheduleTime === undefined) throw new Error("daily source schedule requires --time HH:MM");
      if (parsed.everyMinutes !== undefined) throw new Error("daily source schedule does not accept --every-minutes");
      candidate = {
        enabled: profile.schedule?.enabled !== false,
        kind: "daily",
        time: parsed.scheduleTime,
        timezone: parsed.timezone || profile.schedule?.timezone || "local",
      };
    }
    const normalized = normalizedSchedule(id, { ...profile, schedule: candidate });
    if (!normalized) throw new Error(`external source ${id} schedule could not be normalized`);
    const previous = profile.schedule ? normalizedSchedule(id, profile) : undefined;
    const changed = JSON.stringify(previous) !== JSON.stringify(normalized);
    if (parsed.apply && changed) {
      const config = loadConfig(configFile);
      config.externalSources = config.externalSources || {};
      config.externalSources[id] = { ...profile, schedule: normalized };
      writeJSONAtomic(configFile, config);
    }
    emit({
      schema: "org2:source-schedule:v1",
      root,
      configFile,
      profile: id,
      ...(previous ? { previous } : {}),
      schedule: normalized,
      changed,
      applied: parsed.apply,
    }, parsed.json);
    return true;
  }

  if (action === "bind") {
    const id = selected[0];
    if (!id || selected.length !== 1) throw new Error("celorga source bind requires exactly one PROFILE");
    const envelope = readBindings(root);
    const current = envelope.bindings[id] || {};
    const next = {
      ...current,
      ...(parsed.binary !== undefined ? { binary: parsed.binary } : {}),
      ...(parsed.configPath !== undefined ? { configPath: path.resolve(parsed.configPath) } : {}),
      ...(parsed.workingDirectory !== undefined ? { workingDirectory: path.resolve(parsed.workingDirectory) } : {}),
      ...(parsed.passwordEnv !== undefined ? { passwordEnv: parsed.passwordEnv } : {}),
      ...(parsed.passwordCommand !== undefined ? { passwordCommand: parsed.passwordCommand } : {}),
    };
    const preview = { profile: id, bindingPath: sourceBindingsPath(root), binding: next, applied: parsed.apply };
    if (parsed.apply) {
      fs.mkdirSync(path.dirname(preview.bindingPath), { recursive: true });
      envelope.bindings[id] = next;
      fs.writeFileSync(preview.bindingPath, JSON.stringify(envelope, null, 2) + "\n", { mode: 0o600 });
      try { fs.chmodSync(preview.bindingPath, 0o600); } catch {}
    }
    emit(preview, parsed.json);
    return true;
  }

  if (action === "add") {
    const id = selected[0];
    if (!id || selected.length !== 1) throw new Error("celorga source add requires exactly one PROFILE");
    if (!parsed.sourceJSON) throw new Error("celorga source add requires --source-json with an externalSources entry");
    let requested: unknown;
    try { requested = JSON.parse(parsed.sourceJSON); } catch { throw new Error("--source-json must be valid JSON"); }
    if (!requested || typeof requested !== "object" || Array.isArray(requested)) throw new Error("--source-json must be a JSON object");
    const existing = profiles[id];
    if (existing && !parsed.update) throw new Error(`external source ${id} already exists; pass --update to change it`);
    if (!existing && parsed.update) throw new Error(`external source ${id} does not exist`);
    const candidate = existing ? mergeExternalSourceProfile(existing, requested as Record<string, unknown>) : requested;
    if (existing && (candidate as Org2ExternalSourceConfig).type !== existing.type) throw new Error(`external source ${id} cannot change type from ${existing.type}`);
    const profile = validateExternalSourceProfile(id, candidate);
    const changed = JSON.stringify(existing ?? null) !== JSON.stringify(profile);
    if (parsed.apply && changed) {
      const config = loadConfig(configFile);
      config.externalSources = { ...(config.externalSources || {}), [id]: profile };
      writeJSONAtomic(configFile, config);
    }
    const credential = profile.type === "google-calendar"
      ? `Sign in with Google from the Celorga app's Sources view (it sends the credential to the connected server), or set ${GOOGLE_CALENDAR_CREDENTIAL_ENV}`
      : profile.type === "email"
      ? `Provide the password with ${DEFAULT_EMAIL_PASSWORD_ENV}, celorga source bind ${id} --password-command CMD --apply, or the Celorga app's Sources view`
      : `Provide the crawler token through its environment (${profile.type === "slack" ? "SLACK_BOT_TOKEN" : "NOTION_TOKEN"}) or the Celorga app's Sources view, and bind a non-default crawler with celorga source bind ${id} --binary PATH --config PATH --apply`;
    emit({
      schema: "org2:source-add:v1",
      root,
      configFile,
      profile: id,
      source: profile,
      ...(existing ? { previous: existing } : {}),
      created: !existing,
      changed,
      applied: parsed.apply,
      next: `${credential}; then celorga source doctor ${id}.`,
    }, parsed.json);
    return true;
  }

  if (action === "add-email") {
    const id = selected[0] ?? parsed.positional[0];
    if (!id || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(id)) throw new Error("celorga source add-email requires a PROFILE id (letters, digits, ., _, -)");
    if (profiles[id]) throw new Error(`external source ${id} already exists`);
    if (!parsed.host || !parsed.username) throw new Error("source add-email requires --host and --username");
    const profile: Org2ExternalSourceConfig = {
      type: "email",
      enabled: true,
      email: {
        host: parsed.host,
        ...(parsed.port ? { port: parsed.port } : {}),
        ...(parsed.security ? { security: parsed.security as "tls" | "starttls" | "none" } : {}),
        username: parsed.username,
        mailboxes: parsed.mailboxes.length ? parsed.mailboxes : ["INBOX"],
        ...(parsed.smtpHost ? { smtp: { host: parsed.smtpHost, ...(parsed.smtpPort ? { port: parsed.smtpPort } : {}) } } : {}),
      },
      ingestion: { since: parsed.since || "14d" },
    };
    emailSourceSettings(id, profile);
    if (parsed.apply) {
      const config = loadConfig(configFile);
      config.externalSources = { ...(config.externalSources || {}), [id]: profile };
      writeJSONAtomic(configFile, config);
    }
    emit({
      schema: "org2:source-add:v1",
      root,
      configFile,
      profile: id,
      source: profile,
      applied: parsed.apply,
      next: `Provide the password with ${DEFAULT_EMAIL_PASSWORD_ENV}, celorga source bind ${id} --password-command CMD --apply, or the Celorga app's Sources view; then celorga source doctor ${id}.`,
    }, parsed.json);
    return true;
  }

  if (action === "import") {
    const allStatuses = statuses(root, profiles);
    const requested = select(allStatuses).filter((item) => item.enabled);
    const importBindings = readBindings(root).bindings;
    const results = [];
    for (const status of requested) {
      if (status.type !== "google-calendar") continue;
      if (!status.ready) { results.push({ id: status.id, ok: false, skipped: true, error: status.setupError || "Google Calendar settings are incomplete" }); continue; }
      try {
        const { imported, calendars } = await importGoogleCalendarProfile({
          root, id: status.id, profile: profiles[status.id]!, limit: parsed.limit, timeoutMs: parsed.timeoutMs, apply: parsed.apply,
        });
        results.push({ id: status.id, ok: true, imported, calendars });
      } catch (error) {
        results.push({ id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) });
      }
    }
    for (const status of requested) {
      if (status.type !== "email") continue;
      if (!status.ready) { results.push({ id: status.id, ok: false, skipped: true, error: status.setupError || "email settings are incomplete" }); continue; }
      try {
        const { imported, mailboxes } = await importEmailProfile({
          root, id: status.id, profile: profiles[status.id]!, binding: importBindings[status.id] || {},
          since: parsed.since, limit: parsed.limit, timeoutMs: parsed.timeoutMs, apply: parsed.apply,
        });
        results.push({ id: status.id, ok: true, imported, mailboxes });
      } catch (error) {
        results.push({ id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) });
      }
    }
    results.push(...requested.filter((status) => status.type !== "email" && status.type !== "google-calendar").map((status) => {
      if (!status.ready) return { id: status.id, ok: false, skipped: true, error: "source binding is not ready; run celorga source doctor" };
      try {
        const imported = importCrawlerArchive({
          root,
          profileId: status.id,
          profile: profiles[status.id]!,
          binary: status.binary,
          configPath: status.configPath!,
          since: parsed.since,
          limit: parsed.limit,
          timeoutMs: parsed.timeoutMs,
          apply: parsed.apply,
        });
        return { id: status.id, ok: true, imported };
      } catch (error) {
        return { id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) };
      }
    }));
    emit({ schema: "org2:source-import-run:v1", root, applied: parsed.apply, results }, parsed.json);
    if (results.some((result) => !result.ok)) process.exitCode = 1;
    return true;
  }

  if (action === "sync") {
    const allStatuses = statuses(root, profiles);
    const requested = select(allStatuses).filter((item) => item.enabled);
    const bindings = readBindings(root).bindings;
    const results = [];
    for (const status of requested) {
      if (status.type === "google-calendar") {
        if (!status.ready) {
          results.push({ id: status.id, ok: false, skipped: true, error: status.setupError || "Google Calendar settings are incomplete" });
          continue;
        }
        const lockDir = path.join(org2CorpusIndexDir(root), `source-${status.id}.lock`);
        fs.mkdirSync(path.dirname(lockDir), { recursive: true });
        const syncLock = acquireSourceSyncLock(lockDir, status.id, root, parsed.timeoutMs);
        if (!syncLock) {
          results.push({ id: status.id, ok: true, skipped: true, reason: "sync-in-progress", message: "Sync already in progress on this machine." });
          continue;
        }
        try {
          // Like email, there is no separate archive: sync fetches the window
          // and stages it (with --apply) in one step.
          const { imported, calendars, window } = await importGoogleCalendarProfile({
            root, id: status.id, profile: profiles[status.id]!, limit: parsed.limit, timeoutMs: parsed.timeoutMs, apply: parsed.apply,
          });
          if (parsed.apply) writeGoogleCalendarLastSync(root, status.id, { calendars, window });
          results.push({ id: status.id, ok: true, status: 0, imported, calendars, window, ...(syncLock.recoveredStaleLock ? { recoveredStaleLock: true } : {}) });
        } catch (error) {
          results.push({ id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) });
        } finally {
          releaseSourceSyncLock(lockDir, syncLock.owner);
        }
        continue;
      }
      if (status.type === "email") {
        if (!status.ready) {
          results.push({ id: status.id, ok: false, skipped: true, error: status.setupError || "email settings are incomplete" });
          continue;
        }
        const lockDir = path.join(org2CorpusIndexDir(root), `source-${status.id}.lock`);
        fs.mkdirSync(path.dirname(lockDir), { recursive: true });
        const syncLock = acquireSourceSyncLock(lockDir, status.id, root, parsed.timeoutMs);
        if (!syncLock) {
          results.push({ id: status.id, ok: true, skipped: true, reason: "sync-in-progress", message: "Sync already in progress on this machine." });
          continue;
        }
        try {
          // Email has no separate crawler archive: sync fetches new mail and
          // stages it (with --apply) in one step.
          const { imported, mailboxes } = await importEmailProfile({
            root, id: status.id, profile: profiles[status.id]!, binding: bindings[status.id] || {},
            since: parsed.since, limit: parsed.limit, timeoutMs: parsed.timeoutMs, apply: parsed.apply,
          });
          results.push({ id: status.id, ok: true, status: 0, imported, mailboxes, ...(syncLock.recoveredStaleLock ? { recoveredStaleLock: true } : {}) });
        } catch (error) {
          results.push({ id: status.id, ok: false, error: error instanceof Error ? error.message : String(error) });
        } finally {
          releaseSourceSyncLock(lockDir, syncLock.owner);
        }
        continue;
      }
      if (!status.ready) {
        results.push({ id: status.id, ok: false, skipped: true, error: "source binding is not ready; run celorga source doctor" });
        continue;
      }
      const profile = profiles[status.id]!;
      const binding = bindings[status.id] || {};
      const crawlerArgs = [
        "--config", configFor(profile, binding),
        "sync",
        ...(profile.syncArgs || (profile.type === "slack" ? ["--source", "api", "--latest-only"] : ["--source", "api"])),
      ];
      const lockDir = path.join(org2CorpusIndexDir(root), `source-${status.id}.lock`);
      const syncLock = acquireSourceSyncLock(lockDir, status.id, root, parsed.timeoutMs);
      if (!syncLock) {
        results.push({
          id: status.id,
          ok: true,
          skipped: true,
          reason: "sync-in-progress",
          message: "Sync already in progress on this machine.",
        });
        continue;
      }
      try {
        const child = spawnSync(status.binary, crawlerArgs, {
          cwd: binding.workingDirectory ? path.resolve(binding.workingDirectory) : root,
          encoding: "utf8",
          stdio: parsed.json ? "pipe" : "inherit",
          env: process.env,
          timeout: parsed.timeoutMs,
          killSignal: "SIGTERM",
        });
        const processError = crawlerProcessError(status.binary, child.error, parsed.timeoutMs);
        const ok = child.status === 0 && !processError;
        let imported: unknown;
        if (ok && parsed.ingest) {
          try {
            imported = importCrawlerArchive({
              root,
              profileId: status.id,
              profile,
              binary: status.binary,
              configPath: status.configPath!,
              since: parsed.since,
              limit: parsed.limit,
              timeoutMs: parsed.timeoutMs,
              apply: parsed.apply,
            });
          } catch (error) {
            results.push({
              id: status.id,
              ok: false,
              status: child.status,
              error: `crawler sync succeeded but Celorga import failed: ${error instanceof Error ? error.message : String(error)}`,
              ...(parsed.json ? { stdout: truncateOutput(child.stdout), stderr: truncateOutput(child.stderr) } : {}),
            });
            continue;
          }
        }
        results.push({
          id: status.id,
          ok,
          status: child.status,
          signal: child.signal,
          ...(syncLock.recoveredStaleLock ? { recoveredStaleLock: true } : {}),
          ...(processError ? { error: processError } : {}),
          ...(imported ? { imported } : {}),
          ...(parsed.json ? { stdout: truncateOutput(child.stdout), stderr: truncateOutput(child.stderr) } : {}),
        });
      } finally {
        releaseSourceSyncLock(lockDir, syncLock.owner);
      }
    }
    if (parsed.json) emit({ schema: "org2:source-sync:v1", root, results }, true);
    if (results.some((result) => !result.ok)) process.exitCode = 1;
    return true;
  }

  throw new Error(`unknown source action: ${action}\n${usage()}`);
}
