import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { guardedWriteFile, readGuardedFile, type GuardedFileWriteOptions } from "./guardedFile.js";
import { isOrgRecordFileName, orgRecordPath, schemaMatches } from "./brandNames.js";

export const ORG2_WORK_LEDGER_ACCOUNT_SCHEMA = "org2:work-ledger-account:v1" as const;
export const WORK_LEDGER_ACCOUNT_STATES = ["active", "paused", "suppressed", "closed"] as const;
export type WorkLedgerAccountState = (typeof WORK_LEDGER_ACCOUNT_STATES)[number];

export interface WorkLedgerEvent {
  id: string;
  idempotencyKey: string;
  type: string;
  at: string;
  actor?: string;
  note?: string;
  runId?: string;
  approvalId?: string;
  decisionKey?: string;
  externalId?: string;
  sourceRefs: string[];
  data: Record<string, string>;
}

export interface WorkLedgerAccount {
  schema: typeof ORG2_WORK_LEDGER_ACCOUNT_SCHEMA;
  ledger: string;
  id: string;
  title: string;
  state: WorkLedgerAccountState;
  aliases: string[];
  identityKeys: string[];
  fields: Record<string, string>;
  context: string;
  events: WorkLedgerEvent[];
  createdAt: string;
  updatedAt: string;
}

export interface WorkLedgerAccountSnapshot {
  file: string;
  revision: string;
  raw: string;
  account: WorkLedgerAccount;
  sourceIssues: WorkLedgerSourceConsistencyIssue[];
}

export interface WorkLedgerSourceConsistencyIssue {
  field: "eventHistory";
  readable: string;
  canonical: string;
}

export interface SaveWorkLedgerAccountOptions extends GuardedFileWriteOptions {
  rejectSourceDrift?: boolean;
}

export interface WorkLedgerValidationIssue {
  path: string;
  message: string;
}

export interface WorkLedgerValidationResult {
  valid: boolean;
  issues: WorkLedgerValidationIssue[];
}

export interface WorkLedgerAccountSummary {
  ledger: string;
  id: string;
  title: string;
  state: WorkLedgerAccountState;
  aliases: string[];
  identityKeys: string[];
  fields: Record<string, string>;
  eventCount: number;
  lastEventAt?: string;
  lastContactAt?: string;
  openApprovalCount: number;
  openWorkCount: number;
  sourceIssueCount: number;
  eligible: boolean;
  eligibilityReason: string;
  file: string;
  revision: string;
}

function safeSegment(raw: string, label: string): string {
  const value = String(raw || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(value)) {
    throw new Error(`${label} must contain only lowercase letters, numbers, dots, underscores, or hyphens`);
  }
  return value;
}

function nowIso(raw?: string): string {
  const date = raw ? new Date(raw) : new Date();
  if (!Number.isFinite(date.getTime())) throw new Error(`invalid timestamp: ${raw}`);
  return date.toISOString();
}

function unique(values: readonly string[] = []): string[] {
  return [...new Set(values.map((value) => String(value || "").trim()).filter(Boolean))];
}

function optional(raw: unknown): string | undefined {
  const value = String(raw || "").trim();
  return value || undefined;
}

function normalizedDecisionKey(raw: unknown): string | undefined {
  const value = optional(raw)?.toLowerCase();
  if (!value) return undefined;
  return value.startsWith("artifact:") ? value : `artifact:${value}`;
}

export function createWorkLedgerAccount(input: {
  ledger: string;
  id: string;
  title: string;
  state?: WorkLedgerAccountState;
  aliases?: string[];
  identityKeys?: string[];
  fields?: Record<string, string>;
  context?: string;
  now?: string;
}): WorkLedgerAccount {
  const at = nowIso(input.now);
  const state = input.state || "active";
  if (!WORK_LEDGER_ACCOUNT_STATES.includes(state)) throw new Error(`invalid account state: ${state}`);
  const account: WorkLedgerAccount = {
    schema: ORG2_WORK_LEDGER_ACCOUNT_SCHEMA,
    ledger: safeSegment(input.ledger, "ledger id"),
    id: safeSegment(input.id, "account id"),
    title: String(input.title || "").trim(),
    state,
    aliases: unique(input.aliases),
    identityKeys: unique(input.identityKeys).map((key) => key.toLowerCase()).sort(),
    fields: Object.fromEntries(Object.entries(input.fields || {}).map(([key, value]) => [safeSegment(key, "field name"), String(value)])),
    context: String(input.context || "").trim(),
    events: [],
    createdAt: at,
    updatedAt: at,
  };
  const validation = validateWorkLedgerAccount(account);
  if (!validation.valid) throw new Error(`invalid work-ledger account: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return account;
}

export function validateWorkLedgerAccount(value: unknown): WorkLedgerValidationResult {
  const issues: WorkLedgerValidationIssue[] = [];
  if (!value || typeof value !== "object" || Array.isArray(value)) return { valid: false, issues: [{ path: "$", message: "must be an object" }] };
  const account = value as Partial<WorkLedgerAccount>;
  if (!schemaMatches(account.schema, ORG2_WORK_LEDGER_ACCOUNT_SCHEMA)) issues.push({ path: "$.schema", message: `must be ${ORG2_WORK_LEDGER_ACCOUNT_SCHEMA}` });
  for (const [key, label] of [[account.ledger, "ledger"], [account.id, "account"]] as const) {
    if (typeof key !== "string" || !/^[a-z0-9][a-z0-9._-]*$/.test(key)) issues.push({ path: `$.${label}`, message: "has an invalid stable id" });
  }
  if (typeof account.title !== "string" || !account.title.trim()) issues.push({ path: "$.title", message: "is required" });
  if (!WORK_LEDGER_ACCOUNT_STATES.includes(account.state as WorkLedgerAccountState)) issues.push({ path: "$.state", message: "is invalid" });
  for (const field of ["createdAt", "updatedAt"] as const) {
    if (typeof account[field] !== "string" || !Number.isFinite(new Date(account[field]).getTime())) issues.push({ path: `$.${field}`, message: "must be an ISO timestamp" });
  }
  if (!Array.isArray(account.aliases)) issues.push({ path: "$.aliases", message: "must be an array" });
  if (!Array.isArray(account.identityKeys)) issues.push({ path: "$.identityKeys", message: "must be an array" });
  for (const [field, values] of [["aliases", account.aliases], ["identityKeys", account.identityKeys]] as const) {
    if (Array.isArray(values) && values.some((item) => typeof item !== "string" || !item.trim())) {
      issues.push({ path: `$.${field}`, message: "must contain non-empty strings" });
    }
  }
  if (Array.isArray(account.aliases) && new Set(account.aliases).size !== account.aliases.length) issues.push({ path: "$.aliases", message: "must be unique" });
  if (Array.isArray(account.identityKeys) && new Set(account.identityKeys).size !== account.identityKeys.length) issues.push({ path: "$.identityKeys", message: "must be unique" });
  if (!account.fields || typeof account.fields !== "object" || Array.isArray(account.fields)) issues.push({ path: "$.fields", message: "must be an object" });
  for (const [key, fieldValue] of Object.entries(account.fields || {})) {
    if (!/^[a-z0-9][a-z0-9._-]*$/.test(key) || typeof fieldValue !== "string") issues.push({ path: `$.fields.${key}`, message: "must be a string field with a safe key" });
  }
  if (typeof account.context !== "string") issues.push({ path: "$.context", message: "must be a string" });
  if (!Array.isArray(account.events)) issues.push({ path: "$.events", message: "must be an array" });
  const eventIds = new Set<string>();
  const eventKeys = new Set<string>();
  for (const [index, event] of (account.events || []).entries()) {
    if (!event || typeof event !== "object") { issues.push({ path: `$.events[${index}]`, message: "must be an object" }); continue; }
    if (typeof event.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(event.id)) issues.push({ path: `$.events[${index}].id`, message: "is invalid" });
    if (eventIds.has(event.id)) issues.push({ path: `$.events[${index}].id`, message: "is duplicated" });
    eventIds.add(event.id);
    if (typeof event.idempotencyKey !== "string" || !/^\S+$/.test(event.idempotencyKey)) issues.push({ path: `$.events[${index}].idempotencyKey`, message: "must be a non-empty key without whitespace" });
    if (eventKeys.has(event.idempotencyKey)) issues.push({ path: `$.events[${index}].idempotencyKey`, message: "is duplicated" });
    eventKeys.add(event.idempotencyKey);
    if (typeof event.type !== "string" || !/^[a-z0-9][a-z0-9._-]*$/.test(event.type)) issues.push({ path: `$.events[${index}].type`, message: "is invalid" });
    if (typeof event.at !== "string" || !Number.isFinite(new Date(event.at).getTime())) issues.push({ path: `$.events[${index}].at`, message: "must be an ISO timestamp" });
    if (Boolean(event.runId) !== Boolean(event.approvalId)) issues.push({ path: `$.events[${index}]`, message: "runId and approvalId must be supplied together" });
    if (event.type === "approval-linked" && (!event.runId || !event.approvalId)) issues.push({ path: `$.events[${index}]`, message: "approval-linked requires runId and approvalId" });
    if (event.type === "outreach-sent" && !event.externalId) issues.push({ path: `$.events[${index}].externalId`, message: "is required for outreach-sent" });
    if (!Array.isArray(event.sourceRefs)) issues.push({ path: `$.events[${index}].sourceRefs`, message: "must be an array" });
    if (Array.isArray(event.sourceRefs)) {
      if (event.sourceRefs.some((item) => typeof item !== "string" || !item.trim())) issues.push({ path: `$.events[${index}].sourceRefs`, message: "must contain non-empty strings" });
      if (new Set(event.sourceRefs).size !== event.sourceRefs.length) issues.push({ path: `$.events[${index}].sourceRefs`, message: "must be unique" });
    }
    if (!event.data || typeof event.data !== "object" || Array.isArray(event.data)) issues.push({ path: `$.events[${index}].data`, message: "must be an object" });
    for (const [key, dataValue] of Object.entries(event.data || {})) {
      if (!/^[a-z0-9][a-z0-9._-]*$/.test(key) || typeof dataValue !== "string") issues.push({ path: `$.events[${index}].data.${key}`, message: "must be a string field with a safe key" });
    }
    for (const key of ["actor", "note", "runId", "approvalId", "decisionKey", "externalId"] as const) {
      if (event[key] !== undefined && typeof event[key] !== "string") issues.push({ path: `$.events[${index}].${key}`, message: "must be a string" });
    }
  }
  return { valid: issues.length === 0, issues };
}

function orgEscape(raw: string): string {
  return String(raw || "").replace(/\r?\n/g, " ").trim();
}

function renderWorkLedgerEventHistory(events: WorkLedgerEvent[]): string {
  return events.length ? events.map((event) => [
    `- ${event.at} ${event.type} =${event.id}= [${event.idempotencyKey}]`,
    ...(event.actor ? [`  Actor: ${orgEscape(event.actor)}`] : []),
    ...(event.note ? [`  ${orgEscape(event.note)}`] : []),
    ...(event.runId ? [`  Run approval: ${event.runId}:${event.approvalId}`] : []),
    ...(event.decisionKey ? [`  Decision key: ${event.decisionKey}`] : []),
    ...(event.externalId ? [`  External ID: ${event.externalId}`] : []),
    ...event.sourceRefs.map((source) => `  Source: ${orgEscape(source)}`),
    ...(Object.keys(event.data).length ? [`  Data: ${Object.entries(event.data).sort(([left], [right]) => left.localeCompare(right)).map(([key, value]) => `${key}=${orgEscape(value)}`).join("; ")}`] : []),
  ].join("\n")).join("\n") : "- No events recorded.";
}

export function renderWorkLedgerAccount(account: WorkLedgerAccount): string {
  const validation = validateWorkLedgerAccount(account);
  if (!validation.valid) throw new Error(`invalid work-ledger account: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return [
    `#+TITLE: ${orgEscape(account.title)}`,
    "#+ORG2_KIND: work-ledger-account",
    "",
    `* ${orgEscape(account.title)} :account:`,
    ":PROPERTIES:",
    `:ID: ${account.ledger}--${account.id}`,
    `:ORG2_LEDGER: ${account.ledger}`,
    `:ORG2_ACCOUNT_ID: ${account.id}`,
    ":ORG2_ARTIFACT_ROLE: canonical",
    `:ACCOUNT_STATE: ${account.state}`,
    `:CREATED_AT: ${account.createdAt}`,
    `:UPDATED_AT: ${account.updatedAt}`,
    ":END:",
    "",
    "** Aliases",
    ...(account.aliases.length ? account.aliases.map((alias) => `- ${alias}`) : ["- None recorded."]),
    "",
    "** Identity keys",
    ...(account.identityKeys.length ? account.identityKeys.map((key) => `- ${key}`) : ["- None recorded."]),
    "",
    "** Human context",
    account.context || "No curated context recorded yet.",
    "",
    "** Event history",
    renderWorkLedgerEventHistory(account.events),
    "",
    "** Machine state",
    "#+begin_src json :org2-work-ledger-account",
    JSON.stringify(account, null, 2),
    "#+end_src",
    "",
  ].join("\n");
}

function section(raw: string, title: string): string | undefined {
  return new RegExp(`^\\*\\* ${title}\\s*\\r?\\n([\\s\\S]*?)(?=\\r?\\n\\*\\* )`, "m").exec(raw)?.[1]?.trim();
}

function bulletSection(raw: string, title: string): string[] | undefined {
  const body = section(raw, title);
  if (body === undefined) return undefined;
  if (body === "- None recorded.") return [];
  return body.split(/\r?\n/).map((line) => /^\s*-\s+(.*?)\s*$/.exec(line)?.[1]).filter((value): value is string => Boolean(value));
}

export function parseWorkLedgerAccount(rawInput: string): WorkLedgerAccount {
  const raw = String(rawInput || "").replace(/\r\n/g, "\n");
  const match = /#\+begin_src\s+json\s+:org2-work-ledger-account\s*\n([\s\S]*?)\n#\+end_src/i.exec(raw);
  if (!match) throw new Error("work-ledger account is missing its machine-state JSON block");
  const parsed = JSON.parse(match[1]!) as WorkLedgerAccount;
  const title = /^\*\s+(.+?)(?:\s+:account:)?\s*$/m.exec(raw)?.[1]?.trim();
  const state = /^:ACCOUNT_STATE:\s*(.*?)\s*$/mi.exec(raw)?.[1]?.trim() as WorkLedgerAccountState | undefined;
  const aliases = bulletSection(raw, "Aliases");
  const identityKeys = bulletSection(raw, "Identity keys");
  const context = section(raw, "Human context");
  const account: WorkLedgerAccount = {
    ...parsed,
    ...(title ? { title } : {}),
    ...(state ? { state } : {}),
    ...(aliases ? { aliases } : {}),
    ...(identityKeys ? { identityKeys: identityKeys.map((key) => key.toLowerCase()).sort() } : {}),
    ...(context && context !== "No curated context recorded yet." ? { context } : context !== undefined ? { context: "" } : {}),
    events: parsed.events || [],
    fields: parsed.fields || {},
  };
  const validation = validateWorkLedgerAccount(account);
  if (!validation.valid) throw new Error(`invalid work-ledger account: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return account;
}

export function workLedgerSourceConsistency(
  raw: string,
  account: WorkLedgerAccount = parseWorkLedgerAccount(raw),
): WorkLedgerSourceConsistencyIssue[] {
  const readable = section(String(raw || "").replace(/\r\n/g, "\n"), "Event history");
  if (readable === undefined) return [];
  const canonical = renderWorkLedgerEventHistory(account.events);
  return readable === canonical ? [] : [{ field: "eventHistory", readable, canonical }];
}

export function workLedgerAccountDirectory(root: string, ledger: string): string {
  return path.join(path.resolve(root), "notes", safeSegment(ledger, "ledger id"), "accounts");
}

export function workLedgerAccountPath(root: string, ledger: string, id: string): string {
  return orgRecordPath(workLedgerAccountDirectory(root, ledger), safeSegment(id, "account id"));
}

export function workLedgerMutationLockPath(root: string, ledger: string): string {
  return path.join(workLedgerAccountDirectory(root, ledger), ".org2-ledger.lock");
}

export function acquireWorkLedgerMutationLock(root: string, ledger: string): () => void {
  const lockFile = workLedgerMutationLockPath(root, ledger);
  fs.mkdirSync(path.dirname(lockFile), { recursive: true });
  let descriptor: number;
  try {
    descriptor = fs.openSync(lockFile, "wx", 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    throw new Error(`work ledger is already being updated: ${safeSegment(ledger, "ledger id")}`);
  }
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify({
      schema: "org2:work-ledger-lock:v1",
      pid: process.pid,
      createdAt: new Date().toISOString(),
      ledger: safeSegment(ledger, "ledger id"),
    }, null, 2)}\n`, "utf8");
    fs.fsyncSync(descriptor);
  } catch (error) {
    fs.closeSync(descriptor);
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
    throw error;
  }
  return () => {
    fs.closeSync(descriptor);
    if (fs.existsSync(lockFile)) fs.unlinkSync(lockFile);
  };
}

export function workLedgerMutationLockFiles(root: string): string[] {
  const notes = path.join(path.resolve(root), "notes");
  if (!fs.existsSync(notes)) return [];
  const files: string[] = [];
  for (const ledgerEntry of fs.readdirSync(notes, { withFileTypes: true })) {
    if (!ledgerEntry.isDirectory()) continue;
    const lockFile = path.join(notes, ledgerEntry.name, "accounts", ".org2-ledger.lock");
    if (fs.existsSync(lockFile)) files.push(lockFile);
  }
  return files.sort();
}

export function workLedgerAccountFiles(root: string): string[] {
  const notes = path.join(path.resolve(root), "notes");
  if (!fs.existsSync(notes)) return [];
  const files: string[] = [];
  for (const ledgerEntry of fs.readdirSync(notes, { withFileTypes: true })) {
    if (!ledgerEntry.isDirectory() || !/^[a-z0-9][a-z0-9._-]*$/.test(ledgerEntry.name)) continue;
    const accounts = path.join(notes, ledgerEntry.name, "accounts");
    if (!fs.existsSync(accounts)) continue;
    for (const accountEntry of fs.readdirSync(accounts, { withFileTypes: true })) {
      if (!accountEntry.isFile() || !isOrgRecordFileName(accountEntry.name)) continue;
      const file = path.join(accounts, accountEntry.name);
      const raw = fs.readFileSync(file, "utf8");
      if (/^#\+(?:CELORGA|ORG2)_KIND:\s*work-ledger-account\s*$/im.test(raw) || /#\+begin_src\s+json\s+:org2-work-ledger-account\b/i.test(raw)) files.push(file);
    }
  }
  return files.sort();
}

export function loadWorkLedgerAccount(root: string, ledger: string, id: string): WorkLedgerAccountSnapshot {
  const file = workLedgerAccountPath(root, ledger, id);
  if (!fs.existsSync(file)) throw new Error(`work-ledger account not found: ${ledger}/${id}`);
  const snapshot = readGuardedFile(file);
  const account = parseWorkLedgerAccount(snapshot.content);
  if (account.ledger !== safeSegment(ledger, "ledger id") || account.id !== safeSegment(id, "account id")) {
    throw new Error(`work-ledger account identity does not match its path: ${snapshot.file}`);
  }
  return {
    file: snapshot.file,
    revision: snapshot.revision,
    raw: snapshot.content,
    account,
    sourceIssues: workLedgerSourceConsistency(snapshot.content, account),
  };
}

export function listWorkLedgerAccounts(root: string, ledger: string): WorkLedgerAccountSnapshot[] {
  const dir = workLedgerAccountDirectory(root, ledger);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && isOrgRecordFileName(entry.name))
    .map((entry) => {
      const snapshot = readGuardedFile(path.join(dir, entry.name));
      const account = parseWorkLedgerAccount(snapshot.content);
      return {
        file: snapshot.file,
        revision: snapshot.revision,
        raw: snapshot.content,
        account,
        sourceIssues: workLedgerSourceConsistency(snapshot.content, account),
      };
    })
    .sort((left, right) => left.account.title.localeCompare(right.account.title) || left.account.id.localeCompare(right.account.id));
}

export function saveWorkLedgerAccount(
  root: string,
  account: WorkLedgerAccount,
  options: SaveWorkLedgerAccountOptions = {},
): WorkLedgerAccountSnapshot {
  const outputPath = workLedgerAccountPath(root, account.ledger, account.id);
  if (options.rejectSourceDrift && fs.existsSync(outputPath)) {
    const current = fs.readFileSync(outputPath, "utf8");
    const issues = workLedgerSourceConsistency(current);
    if (issues.length > 0) {
      throw new Error(
        `work-ledger source has out-of-band event-history changes; run celorga doctor and reconcile the source before writing: ${outputPath}`,
      );
    }
  }
  const result = guardedWriteFile(outputPath, renderWorkLedgerAccount(account), options);
  return {
    file: result.file,
    revision: result.revision,
    raw: result.content,
    account,
    sourceIssues: [],
  };
}

export function updateWorkLedgerAccount(
  account: WorkLedgerAccount,
  input: {
    title?: string;
    state?: WorkLedgerAccountState;
    aliases?: string[];
    identityKeys?: string[];
    fields?: Record<string, string>;
    context?: string;
    now?: string;
  },
): WorkLedgerAccount {
  const state = input.state || account.state;
  if (!WORK_LEDGER_ACCOUNT_STATES.includes(state)) throw new Error(`invalid account state: ${state}`);
  return {
    ...account,
    title: optional(input.title) || account.title,
    state,
    aliases: input.aliases ? unique(input.aliases) : account.aliases,
    identityKeys: input.identityKeys ? unique(input.identityKeys).map((key) => key.toLowerCase()).sort() : account.identityKeys,
    fields: input.fields ? { ...account.fields, ...input.fields } : account.fields,
    ...(input.context !== undefined ? { context: input.context.trim() } : {}),
    updatedAt: nowIso(input.now),
  };
}

export function appendWorkLedgerEvent(
  account: WorkLedgerAccount,
  input: {
    id?: string;
    idempotencyKey: string;
    type: string;
    at?: string;
    actor?: string;
    note?: string;
    runId?: string;
    approvalId?: string;
    decisionKey?: string;
    externalId?: string;
    sourceRefs?: string[];
    data?: Record<string, string>;
  },
): { account: WorkLedgerAccount; event: WorkLedgerEvent; changed: boolean } {
  const idempotencyKey = String(input.idempotencyKey || "").trim().toLowerCase();
  if (!idempotencyKey) throw new Error("event idempotency key is required");
  const type = safeSegment(input.type, "event type");
  const existing = account.events.find((event) => event.idempotencyKey === idempotencyKey);
  if (existing) {
    const requestedSources = unique(input.sourceRefs).sort();
    const existingSources = [...existing.sourceRefs].sort();
    const requestedData = Object.fromEntries(Object.entries(input.data || {}).sort(([left], [right]) => left.localeCompare(right)));
    const existingData = Object.fromEntries(Object.entries(existing.data).sort(([left], [right]) => left.localeCompare(right)));
    const matches = existing.type === type
      && (!input.id || existing.id === safeSegment(input.id, "event id"))
      && (existing.actor || "") === (optional(input.actor) || "")
      && (existing.runId || "") === (optional(input.runId) || "")
      && (existing.approvalId || "") === (optional(input.approvalId) || "")
      && (existing.decisionKey || "") === (normalizedDecisionKey(input.decisionKey) || "")
      && (existing.externalId || "") === (optional(input.externalId) || "")
      && (existing.note || "") === (optional(input.note) || "")
      && JSON.stringify(existingSources) === JSON.stringify(requestedSources)
      && JSON.stringify(existingData) === JSON.stringify(requestedData);
    if (!matches) throw new Error(`idempotency key already records different material: ${idempotencyKey}`);
    return { account, event: existing, changed: false };
  }
  const at = nowIso(input.at);
  const event: WorkLedgerEvent = {
    id: safeSegment(input.id || crypto.randomUUID(), "event id"),
    idempotencyKey,
    type,
    at,
    ...(optional(input.actor) ? { actor: optional(input.actor) } : {}),
    ...(optional(input.note) ? { note: optional(input.note) } : {}),
    ...(optional(input.runId) ? { runId: optional(input.runId) } : {}),
    ...(optional(input.approvalId) ? { approvalId: optional(input.approvalId) } : {}),
    ...(normalizedDecisionKey(input.decisionKey) ? { decisionKey: normalizedDecisionKey(input.decisionKey) } : {}),
    ...(optional(input.externalId) ? { externalId: optional(input.externalId) } : {}),
    sourceRefs: unique(input.sourceRefs),
    data: { ...(input.data || {}) },
  };
  const next: WorkLedgerAccount = {
    ...account,
    state: type === "suppressed" ? "suppressed" : type === "reopened" ? "active" : type === "closed" ? "closed" : account.state,
    events: [...account.events, event],
    updatedAt: at,
  };
  const validation = validateWorkLedgerAccount(next);
  if (!validation.valid) throw new Error(`invalid work-ledger event: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return { account: next, event, changed: true };
}

export function summarizeWorkLedgerAccount(
  snapshot: WorkLedgerAccountSnapshot,
  options: { asOf?: string; cooldownDays?: number; openApprovalCount?: number } = {},
): WorkLedgerAccountSummary {
  const asOf = new Date(options.asOf || Date.now());
  if (!Number.isFinite(asOf.getTime())) throw new Error("as-of must be an ISO timestamp");
  const cooldownDays = options.cooldownDays ?? 90;
  if (!Number.isFinite(cooldownDays) || cooldownDays < 0) throw new Error("cooldown days must be non-negative");
  const ordered = [...snapshot.account.events].sort((left, right) => left.at.localeCompare(right.at));
  const contactEvents = ordered.filter((event) => ["outreach-sent", "reply-received"].includes(event.type));
  const lastContactAt = contactEvents.at(-1)?.at;
  const openApprovalCount = options.openApprovalCount || 0;
  const workStarts = ordered.filter((event) => ["outreach-proposed", "approval-linked"].includes(event.type));
  const workSettlements = ordered.filter((event) => ["outreach-sent", "outreach-canceled", "outreach-skipped"].includes(event.type));
  const correlationKey = (event: WorkLedgerEvent): string | undefined => event.runId && event.approvalId
    ? `approval:${event.runId}:${event.approvalId}`
    : event.decisionKey
      ? `decision:${event.decisionKey}`
      : event.data.cycle
        ? `cycle:${event.data.cycle}`
        : undefined;
  const openWorkCount = workStarts.filter((start) => {
    const key = correlationKey(start);
    return !workSettlements.some((settlement) => settlement.at >= start.at && (!key || correlationKey(settlement) === key));
  }).length;
  const withinCooldown = lastContactAt
    ? asOf.getTime() - new Date(lastContactAt).getTime() < cooldownDays * 86_400_000
    : false;
  const sourceIssueCount = snapshot.sourceIssues.length;
  const eligible = snapshot.account.state === "active" && sourceIssueCount === 0 && openApprovalCount === 0 && openWorkCount === 0 && !withinCooldown;
  const eligibilityReason = snapshot.account.state !== "active"
    ? `account is ${snapshot.account.state}`
    : sourceIssueCount > 0
      ? "source event history requires reconciliation"
      : openApprovalCount > 0
      ? `${openApprovalCount} linked approval${openApprovalCount === 1 ? " is" : "s are"} still pending`
      : openWorkCount > 0
        ? "linked outreach work has not reached a sent, canceled, or skipped outcome"
      : withinCooldown
        ? `contacted within the ${cooldownDays}-day cooldown`
        : "eligible";
  return {
    ledger: snapshot.account.ledger,
    id: snapshot.account.id,
    title: snapshot.account.title,
    state: snapshot.account.state,
    aliases: snapshot.account.aliases,
    identityKeys: snapshot.account.identityKeys,
    fields: snapshot.account.fields,
    eventCount: snapshot.account.events.length,
    ...(ordered.at(-1)?.at ? { lastEventAt: ordered.at(-1)!.at } : {}),
    ...(lastContactAt ? { lastContactAt } : {}),
    openApprovalCount,
    openWorkCount,
    sourceIssueCount,
    eligible,
    eligibilityReason,
    file: snapshot.file,
    revision: snapshot.revision,
  };
}
