import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { configFileIn, schemaMatches } from "./brandNames.js";
import {
  aiChatInboxDirectory,
  encodedJSONEnvelope,
  publishJSONEnvelope,
} from "./aiChatOperationJournal.js";
import { guardedContentRevision, guardedWriteFile } from "./guardedFile.js";
import { findOpenClawThread, loadOpenClawThreadState } from "./openClawThreadState.js";
import { normalizePgpArmorForDecrypt } from "./pgp.js";

export const SECRET_REQUEST_SCHEMA = "org2:secret-request:v1";
export const SECRET_RECEIPT_SCHEMA = "org2:secret-request-receipt:v1";
export const SECRET_STATUS_SCHEMA = "org2:secret-request-status:v1";
export const SECRET_LIST_SCHEMA = "org2:secret-list:v1";
export const DEFAULT_SECRETS_FILE = "secrets.org";

const SECRET_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]{0,127}$/u;
const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/u;

export type SecretRecipientSource = "config" | "agent" | "request" | "client";

export interface SecretRecipientEntry {
  kind: "recipient" | "file";
  /** GPG recipient identifier, or a corpus-relative armored public-key path. */
  value: string;
  source: SecretRecipientSource;
}

export interface SecretRequestEnvelope {
  schema: typeof SECRET_REQUEST_SCHEMA;
  id: string;
  name: string;
  reason: string;
  createdAt: string;
  authorLabel: string;
  authorAgentRef?: string;
  threadID?: string;
  destination: { file: string };
  recipients: { defaultKey: boolean; entries: SecretRecipientEntry[] };
}

export interface SecretRequestReceipt {
  schema: typeof SECRET_RECEIPT_SCHEMA;
  id: string;
  name: string;
  status: "fulfilled" | "declined";
  decidedAt: string;
  file?: string;
  headingID?: string;
  recipients?: { defaultKey: string | null; recipients: string[]; recipientFiles: string[] };
  note?: string;
}

export type SecretRequestStatus = "pending" | "fulfilled" | "declined";

export interface SecretsConfig {
  file: string;
  defaultRecipientSelf: boolean;
  recipients: string[];
  recipientFiles: string[];
  agents: Record<string, { recipients: string[]; recipientFiles: string[] }>;
}

export interface GpgOptions {
  gpgProgram?: string;
  timeoutMs?: number;
}

export function validateSecretName(raw: string): string {
  const name = String(raw || "").trim();
  if (!SECRET_NAME_PATTERN.test(name)) {
    throw new Error("secret NAME must start with a letter or underscore and contain only letters, digits, and underscores (at most 128 characters)");
  }
  return name;
}

export function validateEnvName(raw: string): string {
  const name = String(raw || "").trim();
  if (!ENV_NAME_PATTERN.test(name)) throw new Error(`invalid environment variable name: ${raw}`);
  return name;
}

export function secretRequestDirectory(corpusRoot: string): string {
  return path.join(aiChatInboxDirectory(corpusRoot), "secret-requests");
}

export function secretReceiptDirectory(corpusRoot: string): string {
  return path.join(secretRequestDirectory(corpusRoot), "receipts");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function stringList(value: unknown, label: string): string[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`celorga.json ${label} must be an array of strings`);
  }
  return (value as string[]).map((item) => item.trim()).filter(Boolean);
}

function insideCorpus(corpusRoot: string, candidate: string): boolean {
  const relative = path.relative(path.resolve(corpusRoot), path.resolve(candidate));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function corpusRelativeFile(corpusRoot: string, raw: string, label: string): string {
  const value = raw.trim();
  if (!value) throw new Error(`${label} is required`);
  const absolute = path.resolve(corpusRoot, value);
  if (!insideCorpus(corpusRoot, absolute) || absolute === path.resolve(corpusRoot)) {
    throw new Error(`${label} must stay inside the active corpus: ${raw}`);
  }
  return path.relative(path.resolve(corpusRoot), absolute).split(path.sep).join("/");
}

export function loadSecretsConfig(corpusRoot: string): SecretsConfig {
  const configFile = configFileIn(path.resolve(corpusRoot));
  let raw: unknown;
  if (configFile) {
    const parsed = JSON.parse(fs.readFileSync(configFile, "utf8")) as Record<string, unknown>;
    raw = parsed.secrets;
  }
  const section = isRecord(raw) ? raw : {};
  const file = corpusRelativeFile(
    corpusRoot,
    typeof section.file === "string" && section.file.trim() ? section.file : DEFAULT_SECRETS_FILE,
    "secrets.file",
  );
  if (!/\.org2?$/iu.test(file)) throw new Error("celorga.json secrets.file must be an .org file");
  const agents: SecretsConfig["agents"] = {};
  if (isRecord(section.agents)) {
    for (const [ref, value] of Object.entries(section.agents)) {
      if (!isRecord(value)) continue;
      agents[ref.trim()] = {
        recipients: stringList(value.recipients, `secrets.agents.${ref}.recipients`),
        recipientFiles: stringList(value.recipientFiles, `secrets.agents.${ref}.recipientFiles`),
      };
    }
  }
  return {
    file,
    defaultRecipientSelf: section.defaultRecipientSelf !== false,
    recipients: stringList(section.recipients, "secrets.recipients"),
    recipientFiles: stringList(section.recipientFiles, "secrets.recipientFiles"),
    agents,
  };
}

function uuidForIdempotencyKey(key: string): string {
  const bytes = crypto.createHash("sha256").update(key).digest().subarray(0, 16);
  bytes[6] = (bytes[6]! & 0x0f) | 0x50;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function normalizedOptional(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

function singleLine(value: string, max: number): string {
  return value.replace(/[\r\n\t]+/gu, " ").replace(/\s{2,}/gu, " ").trim().slice(0, max);
}

function validRequestID(raw: string): string {
  const id = String(raw || "").trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(id)) {
    throw new Error(`invalid secret request ID: ${raw}`);
  }
  return id;
}

function sameRequest(left: SecretRequestEnvelope, right: SecretRequestEnvelope): boolean {
  const { createdAt: _left, ...l } = left;
  const { createdAt: _right, ...r } = right;
  return JSON.stringify(l) === JSON.stringify(r);
}

export interface QueueSecretRequestOptions {
  reason: string;
  authorLabel?: string;
  authorAgentRef?: string;
  threadID?: string;
  recipients?: string[];
  recipientFiles?: string[];
  idempotencyKey?: string;
  apply?: boolean;
  now?: Date;
}

export interface QueueSecretRequestResult {
  applied: boolean;
  changed: boolean;
  status: SecretRequestStatus | "preview";
  file: string;
  request: SecretRequestEnvelope;
}

export function queueSecretRequest(
  corpusRoot: string,
  rawName: string,
  options: QueueSecretRequestOptions,
): QueueSecretRequestResult {
  const root = path.resolve(corpusRoot);
  const name = validateSecretName(rawName);
  const reason = singleLine(String(options.reason || ""), 2_001);
  if (!reason) throw new Error("--reason is required: tell the person why the secret is needed");
  if (reason.length > 2_000) throw new Error("--reason exceeds 2000 characters");
  const authorAgentRef = normalizedOptional(options.authorAgentRef);
  const authorLabel = normalizedOptional(options.authorLabel) || authorAgentRef;
  if (!authorLabel) throw new Error("secret request needs --author LABEL or --agent-ref REF to identify the requester");
  if (authorLabel.length > 200) throw new Error("--author exceeds 200 characters");
  if (authorAgentRef && authorAgentRef.length > 1_000) throw new Error("--agent-ref exceeds 1000 characters");

  let threadID: string | undefined;
  const requestedThread = normalizedOptional(options.threadID);
  if (requestedThread) {
    const state = loadOpenClawThreadState(root, { hydrateThreadID: requestedThread });
    const thread = findOpenClawThread(state, requestedThread);
    if (!thread) throw new Error(`unknown AI chat thread: ${requestedThread}`);
    threadID = thread.id.toLowerCase();
  }

  const config = loadSecretsConfig(root);
  const entries: SecretRecipientEntry[] = [];
  const add = (kind: SecretRecipientEntry["kind"], rawValue: string, source: SecretRecipientSource) => {
    const value = kind === "file" ? corpusRelativeFile(root, rawValue, "recipient file") : rawValue.trim();
    if (!value) return;
    if (kind === "file" && !fs.existsSync(path.join(root, value))) {
      throw new Error(`recipient file does not exist: ${value}`);
    }
    if (!entries.some((entry) => entry.kind === kind && entry.value === value)) entries.push({ kind, value, source });
  };
  for (const value of config.recipients) add("recipient", value, "config");
  for (const value of config.recipientFiles) add("file", value, "config");
  const agentConfig = authorAgentRef ? config.agents[authorAgentRef] : undefined;
  for (const value of agentConfig?.recipients || []) add("recipient", value, "agent");
  for (const value of agentConfig?.recipientFiles || []) add("file", value, "agent");
  for (const value of options.recipients || []) add("recipient", value, "request");
  for (const value of options.recipientFiles || []) add("file", value, "request");
  if (entries.length > 32) throw new Error("secret request accepts at most 32 recipients");

  const idempotencyKey = normalizedOptional(options.idempotencyKey);
  const id = idempotencyKey ? uuidForIdempotencyKey(`secret\u0000${name}\u0000${idempotencyKey}`) : crypto.randomUUID();
  const now = options.now || new Date();
  const request: SecretRequestEnvelope = {
    schema: SECRET_REQUEST_SCHEMA,
    id,
    name,
    reason,
    createdAt: now.toISOString(),
    authorLabel,
    ...(authorAgentRef ? { authorAgentRef } : {}),
    ...(threadID ? { threadID } : {}),
    destination: { file: config.file },
    recipients: { defaultKey: config.defaultRecipientSelf, entries },
  };
  const file = path.join(secretRequestDirectory(root), `${id}.json`);
  encodedJSONEnvelope(request);
  const existing = readSecretRequest(root, id);
  if (existing) {
    if (!sameRequest(existing, request)) {
      throw new Error(`secret request idempotency key already queues a different request: ${file}`);
    }
    return { applied: false, changed: false, status: requestStatus(root, id), file, request: existing };
  }
  if (!options.apply) return { applied: false, changed: true, status: "preview", file, request };
  const published = publishJSONEnvelope(file, request, sameRequest, "secret request");
  return {
    applied: published.applied,
    changed: published.applied,
    status: requestStatus(root, id),
    file,
    request: published.payload,
  };
}

function readJSONFile(file: string): unknown | undefined {
  let info: fs.Stats;
  try {
    info = fs.lstatSync(file);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > 512_000) {
    throw new Error(`unsafe or oversized secret request state: ${file}`);
  }
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

export function readSecretRequest(corpusRoot: string, rawID: string): SecretRequestEnvelope | undefined {
  const id = validRequestID(rawID);
  const value = readJSONFile(path.join(secretRequestDirectory(corpusRoot), `${id}.json`));
  if (value === undefined) return undefined;
  if (!isRecord(value) || !schemaMatches(value.schema, SECRET_REQUEST_SCHEMA) || value.id !== id
      || typeof value.name !== "string" || !isRecord(value.destination) || !isRecord(value.recipients)) {
    throw new Error(`invalid secret request envelope: ${id}`);
  }
  return value as unknown as SecretRequestEnvelope;
}

export function readSecretReceipt(corpusRoot: string, rawID: string): SecretRequestReceipt | undefined {
  const id = validRequestID(rawID);
  const value = readJSONFile(path.join(secretReceiptDirectory(corpusRoot), `${id}.json`));
  if (value === undefined) return undefined;
  if (!isRecord(value) || !schemaMatches(value.schema, SECRET_RECEIPT_SCHEMA) || value.id !== id
      || (value.status !== "fulfilled" && value.status !== "declined")) {
    throw new Error(`invalid secret request receipt: ${id}`);
  }
  return value as unknown as SecretRequestReceipt;
}

function requestStatus(corpusRoot: string, id: string): SecretRequestStatus {
  return readSecretReceipt(corpusRoot, id)?.status ?? "pending";
}

export function secretRequestStatus(corpusRoot: string, rawID: string) {
  const root = path.resolve(corpusRoot);
  const id = validRequestID(rawID);
  const request = readSecretRequest(root, id);
  if (!request) throw new Error(`unknown secret request: ${rawID}`);
  const receipt = readSecretReceipt(root, id);
  return {
    schema: SECRET_STATUS_SCHEMA,
    id,
    name: request.name,
    status: receipt?.status ?? ("pending" as SecretRequestStatus),
    reason: request.reason,
    requestedAt: request.createdAt,
    requestedBy: request.authorLabel,
    ...(request.authorAgentRef ? { agentRef: request.authorAgentRef } : {}),
    ...(request.threadID ? { threadID: request.threadID } : {}),
    destination: request.destination,
    ...(receipt ? { decidedAt: receipt.decidedAt } : {}),
    ...(receipt?.headingID ? { headingID: receipt.headingID } : {}),
    ...(receipt?.note ? { note: receipt.note } : {}),
  };
}

export function listSecretRequests(corpusRoot: string): Array<SecretRequestEnvelope & { status: SecretRequestStatus }> {
  const root = path.resolve(corpusRoot);
  let names: string[];
  try {
    names = fs.readdirSync(secretRequestDirectory(root)).filter((name) => /^[0-9a-f-]{36}\.json$/u.test(name));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  return names.flatMap((name) => {
    try {
      const request = readSecretRequest(root, name.slice(0, -5));
      return request ? [{ ...request, status: requestStatus(root, request.id) }] : [];
    } catch {
      return [];
    }
  }).sort((left, right) => left.createdAt.localeCompare(right.createdAt));
}

// --- Secrets file -----------------------------------------------------------

export interface SecretEntry {
  name: string;
  id?: string;
  line: number;
  encrypted: boolean;
  requestedBy?: string;
  agentRef?: string;
  updatedAt?: string;
  requestID?: string;
}

interface LocatedSecret extends SecretEntry {
  headingIndex: number;
  /** Exclusive end of this entry's own content (first child heading or subtree end). */
  bodyEnd: number;
  armor?: string;
}

const HEADING_RE = /^(\*+)\s+/u;

function locateSecrets(lines: string[]): LocatedSecret[] {
  const found: LocatedSecret[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!HEADING_RE.test(lines[index] ?? "")) continue;
    let bodyEnd = lines.length;
    for (let next = index + 1; next < lines.length; next += 1) {
      if (HEADING_RE.test(lines[next] ?? "")) { bodyEnd = next; break; }
    }
    const properties = new Map<string, string>();
    if (/^\s*:PROPERTIES:\s*$/iu.test(lines[index + 1] ?? "")) {
      for (let next = index + 2; next < bodyEnd; next += 1) {
        const line = lines[next] ?? "";
        if (/^\s*:END:\s*$/iu.test(line)) break;
        const match = /^\s*:([^:\s]+):\s*(.*?)\s*$/u.exec(line);
        if (match) properties.set(match[1]!.toUpperCase(), match[2] ?? "");
      }
    }
    const name = properties.get("SECRET_NAME");
    if (!name) continue;
    let armor: string | undefined;
    let begin = -1;
    for (let next = index + 1; next < bodyEnd; next += 1) {
      const line = lines[next] ?? "";
      if (begin < 0 && /^\s*-----BEGIN PGP MESSAGE-----\s*$/u.test(line)) begin = next;
      else if (begin >= 0 && /^\s*-----END PGP MESSAGE-----\s*$/u.test(line)) {
        armor = `${lines.slice(begin, next + 1).join("\n")}\n`;
        break;
      }
    }
    found.push({
      name,
      ...(properties.get("ID") ? { id: properties.get("ID") } : {}),
      line: index + 1,
      encrypted: Boolean(armor),
      ...(properties.get("SECRET_REQUESTED_BY") ? { requestedBy: properties.get("SECRET_REQUESTED_BY") } : {}),
      ...(properties.get("SECRET_AGENT_REF") ? { agentRef: properties.get("SECRET_AGENT_REF") } : {}),
      ...(properties.get("SECRET_UPDATED_AT") ? { updatedAt: properties.get("SECRET_UPDATED_AT") } : {}),
      ...(properties.get("SECRET_REQUEST_ID") ? { requestID: properties.get("SECRET_REQUEST_ID") } : {}),
      headingIndex: index,
      bodyEnd,
      ...(armor ? { armor } : {}),
    });
  }
  return found;
}

function readSecretsFile(corpusRoot: string, relativeFile?: string): { file: string; relative: string; text: string | null } {
  const root = path.resolve(corpusRoot);
  const relative = relativeFile ? corpusRelativeFile(root, relativeFile, "secrets file") : loadSecretsConfig(root).file;
  const file = path.join(root, relative);
  return { file, relative, text: fs.existsSync(file) ? fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n") : null };
}

export function listSecrets(corpusRoot: string) {
  const root = path.resolve(corpusRoot);
  const { relative, text } = readSecretsFile(root);
  const secrets = text === null ? [] : locateSecrets(text.split("\n")).map(({ headingIndex: _h, bodyEnd: _b, armor: _a, ...entry }) => entry);
  const pendingRequests = listSecretRequests(root)
    .filter((request) => request.status === "pending")
    .map((request) => ({
      id: request.id,
      name: request.name,
      requestedBy: request.authorLabel,
      ...(request.authorAgentRef ? { agentRef: request.authorAgentRef } : {}),
      requestedAt: request.createdAt,
    }));
  return { schema: SECRET_LIST_SCHEMA, file: relative, secrets, pendingRequests };
}

// --- GPG --------------------------------------------------------------------

export function resolveDefaultGpgRecipient(gpgProgram: string): string | null {
  const candidates: string[] = [];
  if (gpgProgram.includes("/") || gpgProgram.includes(path.sep)) candidates.push(path.join(path.dirname(gpgProgram), "gpgconf"));
  candidates.push("gpgconf");
  for (const candidate of candidates) {
    const res = spawnSync(candidate, ["--list-options", "gpg"], { encoding: "utf8", timeout: 5_000 });
    if (res.error || res.status !== 0) continue;
    const line = String(res.stdout || "").split(/\r?\n/u).find((entry) => entry.startsWith("default-key:"));
    if (!line) continue;
    const value = String(line.split(":")[9] || "").replace(/^"+|"+$/gu, "").trim();
    if (value) return value;
  }
  return null;
}

function gpgFailure(action: string, res: ReturnType<typeof spawnSync>): Error {
  const detail = [res.error?.message, String(res.stderr || "").trim()].filter(Boolean).join(" | ");
  return new Error(`gpg ${action} failed${detail ? `: ${detail}` : ""}`);
}

/** Encrypts in memory: the plaintext reaches gpg only through its stdin pipe. */
function encryptToRecipients(
  plaintext: string,
  recipients: { defaultKey: string | null; recipients: string[]; recipientFiles: string[] },
  options: GpgOptions,
): string {
  const args = ["--batch", "--yes", "--trust-model", "always", "--armor", "--encrypt"];
  if (recipients.defaultKey) args.push("--recipient", recipients.defaultKey);
  for (const recipient of recipients.recipients) args.push("--recipient", recipient);
  for (const file of recipients.recipientFiles) args.push("--recipient-file", file);
  const res = spawnSync(options.gpgProgram || "gpg", args, {
    input: plaintext,
    encoding: "utf8",
    timeout: options.timeoutMs ?? 30_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (res.error || res.status !== 0) throw gpgFailure("encrypt", res);
  const armor = String(res.stdout || "").replace(/\r\n/g, "\n").trim();
  if (!/^-----BEGIN PGP MESSAGE-----\n[\s\S]*\n-----END PGP MESSAGE-----$/u.test(armor)) {
    throw new Error("gpg encrypt did not return an armored PGP message; nothing was written");
  }
  const value = plaintext.replace(/\n$/u, "");
  if (value.length >= 6 && armor.includes(value)) {
    throw new Error("gpg output contained the plaintext; refusing to write it");
  }
  return armor;
}

export function decryptSecretValue(corpusRoot: string, rawName: string, options: GpgOptions = {}): string {
  const name = validateSecretName(rawName);
  const { relative, text } = readSecretsFile(corpusRoot);
  if (text === null) throw new Error(`secrets file does not exist: ${relative}`);
  const entry = locateSecrets(text.split("\n")).find((candidate) => candidate.name === name);
  if (!entry) throw new Error(`no secret named ${name} in ${relative}; request it with celorga secret request ${name} --reason TEXT --apply`);
  if (!entry.armor) throw new Error(`secret ${name} in ${relative} is not encrypted; seal it with celorga crypt encrypt before use`);
  // gpg may need gpg-agent/pinentry for the private key, so this is not --batch.
  const res = spawnSync(options.gpgProgram || "gpg", ["--yes", "--trust-model", "always", "--decrypt"], {
    input: normalizePgpArmorForDecrypt(entry.armor),
    encoding: "utf8",
    timeout: options.timeoutMs ?? 120_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (res.error || res.status !== 0) throw gpgFailure("decrypt", res);
  return String(res.stdout || "").replace(/\r?\n$/u, "");
}

// --- Fulfillment ------------------------------------------------------------

export interface FulfillSecretOptions extends GpgOptions {
  /** Overrides the request's default-key choice (the app passes its crypt setting). */
  defaultRecipientSelf?: boolean;
  /** Additional client-configured recipients, such as the app's crypt settings. */
  recipients?: string[];
  recipientFiles?: string[];
  now?: Date;
}

function orgTimestamp(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/u, "Z");
}

function resolveRecipients(
  root: string,
  request: SecretRequestEnvelope,
  options: FulfillSecretOptions,
): { defaultKey: string | null; recipients: string[]; recipientFiles: string[] } {
  const gpgProgram = options.gpgProgram || "gpg";
  const useDefault = options.defaultRecipientSelf ?? request.recipients.defaultKey;
  const defaultKey = useDefault ? resolveDefaultGpgRecipient(gpgProgram) : null;
  const recipients: string[] = [];
  const recipientFiles: string[] = [];
  for (const entry of request.recipients.entries || []) {
    if (entry.kind === "recipient") {
      if (entry.value.trim() && !recipients.includes(entry.value.trim())) recipients.push(entry.value.trim());
    } else {
      const relative = corpusRelativeFile(root, entry.value, "recipient file");
      const absolute = path.join(root, relative);
      if (!fs.existsSync(absolute)) throw new Error(`recipient file does not exist: ${relative}; nothing was written`);
      if (!recipientFiles.includes(absolute)) recipientFiles.push(absolute);
    }
  }
  for (const value of options.recipients || []) if (value.trim() && !recipients.includes(value.trim())) recipients.push(value.trim());
  for (const value of options.recipientFiles || []) {
    const absolute = path.resolve(root, value.trim());
    if (value.trim() && !recipientFiles.includes(absolute)) recipientFiles.push(absolute);
  }
  if (!defaultKey && recipients.length === 0 && recipientFiles.length === 0) {
    throw new Error(useDefault
      ? "no encryption recipient: GPG has no default-key configured. Set default-key in gpg.conf (check with gpgconf --list-options gpg), or add recipients to secrets.recipients in celorga.json. Nothing was written."
      : "no encryption recipient: add recipients to secrets.recipients in celorga.json or enable the default GPG key. Nothing was written.");
  }
  return { defaultKey, recipients, recipientFiles };
}

function writeReceipt(root: string, receipt: SecretRequestReceipt): void {
  const file = path.join(secretReceiptDirectory(root), `${receipt.id}.json`);
  publishJSONEnvelope(file, receipt, (left, right) => left.status === right.status && left.id === right.id, "secret receipt");
}

export function planSecretFulfillment(corpusRoot: string, rawID: string, options: FulfillSecretOptions = {}) {
  const root = path.resolve(corpusRoot);
  const id = validRequestID(rawID);
  const request = readSecretRequest(root, id);
  if (!request) throw new Error(`unknown secret request: ${rawID}`);
  const status = requestStatus(root, id);
  const recipients = resolveRecipients(root, request, options);
  return {
    request,
    status,
    file: corpusRelativeFile(root, request.destination.file, "secret destination"),
    resolved: recipients,
    recipients: {
      defaultKey: recipients.defaultKey,
      recipients: recipients.recipients,
      recipientFiles: recipients.recipientFiles.map((file) => (insideCorpus(root, file) ? path.relative(root, file) : file)),
    },
  };
}

/**
 * Seals a provided value into the corpus secrets file. The value travels only
 * through memory and gpg's stdin; only the armored ciphertext is written.
 */
export function fulfillSecretRequest(corpusRoot: string, rawID: string, value: string, options: FulfillSecretOptions = {}) {
  const root = path.resolve(corpusRoot);
  const plan = planSecretFulfillment(root, rawID, options);
  const { request } = plan;
  if (plan.status !== "pending") throw new Error(`secret request ${request.id} is already ${plan.status}`);
  if (!/\.org2?$/iu.test(plan.file)) throw new Error("secret destination must be an .org file");
  const secretValue = value.replace(/\r?\n$/u, "");
  if (!secretValue) throw new Error("secret value is empty; nothing was written");
  if (secretValue.length > 64_000) throw new Error("secret value exceeds 64000 characters");

  const recipients = plan.resolved;
  const armor = encryptToRecipients(`${secretValue}\n`, recipients, options);

  const target = path.join(root, plan.file);
  const beforeBytes = fs.existsSync(target) ? fs.readFileSync(target) : null;
  const before = beforeBytes === null ? null : beforeBytes.toString("utf8").replace(/\r\n/g, "\n");
  const lines = before === null ? ["#+title: Secrets", ""] : before.replace(/\n$/u, "").split("\n");
  const existing = locateSecrets(before === null ? [] : lines).find((entry) => entry.name === request.name);
  const headingID = existing?.id || crypto.randomUUID();
  const level = existing ? (HEADING_RE.exec(lines[existing.headingIndex] ?? "")?.[1] ?? "*") : "*";
  const propertyFiles = recipients.recipientFiles.map((file) => (
    insideCorpus(root, file) ? path.relative(path.dirname(target), file).split(path.sep).join("/") : file
  ));
  const now = options.now || new Date();
  const entryLines = [
    `${level} ${request.name} :secret:crypt:`,
    ":PROPERTIES:",
    `:ID: ${headingID}`,
    `:SECRET_NAME: ${request.name}`,
    `:SECRET_REASON: ${singleLine(request.reason, 500)}`,
    `:SECRET_REQUESTED_BY: ${singleLine(request.authorLabel, 200)}`,
    ...(request.authorAgentRef ? [`:SECRET_AGENT_REF: ${singleLine(request.authorAgentRef, 500)}`] : []),
    `:SECRET_REQUEST_ID: ${request.id}`,
    `:SECRET_UPDATED_AT: ${orgTimestamp(now)}`,
    ...(recipients.recipients.length ? [`:CRYPT_RECIPIENTS: ${recipients.recipients.join(", ")}`] : []),
    ...(propertyFiles.length ? [`:CRYPT_RECIPIENT_FILES: ${propertyFiles.join(", ")}`] : []),
    ":END:",
    ...armor.split("\n"),
  ];
  let nextLines: string[];
  if (existing) {
    nextLines = [...lines.slice(0, existing.headingIndex), ...entryLines, ...lines.slice(existing.bodyEnd)];
  } else {
    nextLines = [...lines];
    while (nextLines.length > 0 && nextLines.at(-1) === "") nextLines.pop();
    nextLines.push("", ...entryLines);
  }
  const nextText = `${nextLines.join("\n")}\n`;
  guardedWriteFile(target, nextText, {
    expectedRevision: beforeBytes === null ? null : guardedContentRevision(beforeBytes),
    preserveMode: true,
  });
  const receipt: SecretRequestReceipt = {
    schema: SECRET_RECEIPT_SCHEMA,
    id: request.id,
    name: request.name,
    status: "fulfilled",
    decidedAt: now.toISOString(),
    file: plan.file,
    headingID,
    recipients: plan.recipients,
  };
  writeReceipt(root, receipt);
  return { applied: true, status: "fulfilled" as const, id: request.id, name: request.name, file: plan.file, headingID, rotated: Boolean(existing), recipients: plan.recipients };
}

export function declineSecretRequest(corpusRoot: string, rawID: string, options: { note?: string; apply?: boolean; now?: Date } = {}) {
  const root = path.resolve(corpusRoot);
  const id = validRequestID(rawID);
  const request = readSecretRequest(root, id);
  if (!request) throw new Error(`unknown secret request: ${rawID}`);
  const status = requestStatus(root, id);
  if (status !== "pending") return { applied: false, status, id, name: request.name };
  if (!options.apply) return { applied: false, status: "preview" as const, id, name: request.name };
  const note = options.note ? singleLine(options.note, 500) : undefined;
  writeReceipt(root, {
    schema: SECRET_RECEIPT_SCHEMA,
    id,
    name: request.name,
    status: "declined",
    decidedAt: (options.now || new Date()).toISOString(),
    ...(note ? { note } : {}),
  });
  return { applied: true, status: "declined" as const, id, name: request.name };
}
