// Attention digest: a deterministic answer to "does anything need me now?"
//
// The digest composes existing engines and never judges importance on its
// own: approvals come from `celorga approvals`, deadlines and scheduled items
// from `celorga agenda`, and blocked runs, artifact reviews, failed runs, and
// chats awaiting the person from the workspace coordinator. The person's
// `attention` preferences in celorga.json filter the result. `interrupt` is
// true only for fingerprints that were never delivered before, outside quiet
// hours; delivery is recorded only by an explicit `--mark-delivered --apply`.
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { configFileIn, stateDir } from "./brandNames.js";
import {
  ATTENTION_CATEGORIES,
  configPathMatches,
  loadConfig,
  validateAttentionConfig,
  type AttentionCategory,
  type AttentionPreferences,
} from "./config.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { ACTIVITY_ATTENTION_WINDOW_SECONDS } from "./activityState.js";
import { isOpenClawThreadSettled, loadOpenClawThreadState, openClawDateMilliseconds, type OpenClawChatThreadRecord } from "./openClawThreadState.js";
import { coordinateWorkspace, type CoordinatorCorpus, type CoordinatorEvidence, type CoordinatorItem } from "./workspaceCoordinator.js";

export const ATTENTION_DIGEST_SCHEMA = "org2:attention-digest:v1" as const;
export const ATTENTION_DELIVERED_SCHEMA = "org2:attention-delivered:v1" as const;
/** Delivered fingerprints no longer in the digest are forgotten after this many days. */
export const ATTENTION_DELIVERED_RETENTION_DAYS = 30;

export type AttentionMode = "check" | "brief";

export interface AttentionEvidence {
  kind: "file" | "run" | "approval" | "thread" | "artifact" | "workflow";
  ref: string;
  path?: string;
  line?: number;
  detail?: string;
}

export interface AttentionItem {
  /** Stable identity of this attention-worthy state; changes when the state does. */
  fingerprint: string;
  category: AttentionCategory;
  title: string;
  summary: string;
  corpus: { id: string; root: string };
  /** Primary evidence: `path:line`, `run:ID`, or `thread:ID`. */
  ref: string;
  evidence: AttentionEvidence[];
  tags: string[];
  at?: string;
  /** A native command that inspects or resolves the item. Decisions remain the person's. */
  command?: string;
  delivered: boolean;
  deliveredAt?: string;
}

export interface AttentionNotification {
  title: string;
  body: string;
  fingerprints: string[];
}

export interface AttentionDigest {
  schema: typeof ATTENTION_DIGEST_SCHEMA;
  generatedAt: string;
  mode: AttentionMode;
  local: { date: string; time: string; timezone: string };
  corpora: CoordinatorCorpus[];
  issues: Array<{ root: string; message: string }>;
  preferences: AttentionPreferences;
  preferencesFile: string | null;
  quietHours: { active: boolean; start?: string; end?: string };
  items: AttentionItem[];
  summary: { total: number; new: number; delivered: number; byCategory: Record<AttentionCategory, number> };
  interrupt: boolean;
  interruptReason: string;
  notification: AttentionNotification | null;
  delivery: {
    file: string | null;
    revision: string | null;
    requested: boolean;
    applied: boolean;
    /** Fingerprints marked (or, in preview, that would be marked) delivered. */
    marked: string[];
  };
}

export interface AttentionDigestOptions {
  mounts?: string[];
  root?: string;
  now?: Date;
  /** Drop run and chat items whose last signal is older than this. Approvals and agenda items are unaffected. */
  sinceSeconds?: number;
  mode?: AttentionMode;
  markDelivered?: boolean;
  /** Restrict marking to these fingerprints, for example the ones a notification showed. */
  fingerprints?: string[];
  apply?: boolean;
  /** Expected delivery-ledger revision; `absent` requires that no ledger exists yet. */
  ifRevision?: string;
}

interface DeliveredEntry { deliveredAt: string; category: string; title: string }
interface DeliveredLedger { schema: typeof ATTENTION_DELIVERED_SCHEMA; corpusId: string; delivered: Record<string, DeliveredEntry> }

type AgendaItem = { todo?: string | null; todoTerminal?: boolean; headline: string; kind: string; file: string; line: number; tags?: string[]; id?: string; time?: string; habit?: unknown; deadlineWarning?: unknown };
type AgendaPayload = { overdue: Array<{ date: string; items: AgendaItem[] }>; days: Array<{ date: string; items: AgendaItem[] }> };
type ApprovalItem = { kind: "headline" | "run"; title: string; status: string; file: string; line: number; idValue: string | null; tags?: string[]; approvalId?: string; fingerprint?: string; action?: string; requestedAt?: string; runId?: string; runGoal?: string };
type ApprovalsPayload = { items: ApprovalItem[] };

const CATEGORY_ORDER = new Map<AttentionCategory, number>(ATTENTION_CATEGORIES.map((category, index) => [category, index]));
const REPLY_REASONS = new Set(["reply-received", "background-reply", "turn-interrupted", "delivery-failed"]);

const execFileAsync = promisify(execFile);

function cliPath(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "cli.js");
}

function fingerprint(parts: unknown[]): string {
  return `att_${crypto.createHash("sha256").update(JSON.stringify(parts)).digest("hex").slice(0, 24)}`;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

export function localDate(now: Date): string {
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

export function localClock(now: Date): string {
  return `${pad(now.getHours())}:${pad(now.getMinutes())}`;
}

function minutesOf(clock: string): number {
  const [hours, minutes] = clock.split(":").map(Number);
  return hours! * 60 + minutes!;
}

/** True when the local clock time falls in [start, end), wrapping past midnight when start > end. */
export function inQuietHours(now: Date, quiet: { start: string; end: string } | null): boolean {
  if (!quiet) return false;
  const current = now.getHours() * 60 + now.getMinutes();
  const start = minutesOf(quiet.start);
  const end = minutesOf(quiet.end);
  return start < end ? current >= start && current < end : current >= start || current < end;
}

function relativeInside(root: string, file: string | undefined): string | undefined {
  if (!file) return undefined;
  const relative = path.relative(root, path.resolve(root, file));
  if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return undefined;
  return relative.split(path.sep).join("/");
}

function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:@=+,-]+$/u.test(value) ? value : `'${value.replace(/'/gu, `'\\''`)}'`;
}

function clip(text: string, limit = 160): string {
  const compact = text.replace(/\s+/gu, " ").trim();
  return compact.length > limit ? `${compact.slice(0, limit - 1)}…` : compact;
}

export function loadAttentionPreferences(root: string): { preferences: AttentionPreferences; file: string | null } {
  const file = configFileIn(root);
  if (!file) return { preferences: validateAttentionConfig(undefined).preferences, file: null };
  const { preferences, issues } = validateAttentionConfig(loadConfig(file).attention);
  if (issues.length) throw new Error(`invalid attention settings in ${file}:\n  ${issues.join("\n  ")}`);
  return { preferences, file };
}

export function attentionDeliveredFile(root: string): string {
  return stateDir(root, "attention", "delivered.json");
}

function readLedger(root: string, corpusId: string): { ledger: DeliveredLedger; revision: string | null; file: string } {
  const file = attentionDeliveredFile(root);
  if (!fs.existsSync(file)) return { ledger: { schema: ATTENTION_DELIVERED_SCHEMA, corpusId, delivered: {} }, revision: null, file };
  const snapshot = readGuardedFile(file);
  let parsed: Partial<DeliveredLedger>;
  try {
    parsed = JSON.parse(snapshot.content) as Partial<DeliveredLedger>;
  } catch (error) {
    throw new Error(`attention delivery ledger is not valid JSON: ${file}: ${error instanceof Error ? error.message : String(error)}`);
  }
  const delivered = parsed.delivered && typeof parsed.delivered === "object" ? parsed.delivered : {};
  return { ledger: { schema: ATTENTION_DELIVERED_SCHEMA, corpusId, delivered }, revision: snapshot.revision, file };
}

function isEmptyCorpusError(message: string): boolean {
  return /no Org files found|no matching files/iu.test(message);
}

async function runCorpusJSON<T>(root: string, args: string[]): Promise<T> {
  const { stdout } = await execFileAsync(process.execPath, [cliPath(), ...args, "--dir", root, "--recursive", "--format", "json"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(stdout) as T;
}

function errorText(error: unknown): string {
  if (error && typeof error === "object" && "stderr" in error) {
    const stderr = String((error as { stderr?: unknown }).stderr || "").trim();
    if (stderr) return stderr;
  }
  return error instanceof Error ? error.message : String(error);
}

function coordinatorEvidence(root: string, evidence: CoordinatorEvidence[]): AttentionEvidence[] {
  const result: AttentionEvidence[] = [];
  for (const item of evidence) {
    if (item.kind === "run-file") result.push({ kind: "run", ref: item.ref, ...(item.path ? { path: item.path } : {}), detail: item.detail });
    else if (item.kind === "source-task") result.push({ kind: "file", ref: `${relativeInside(root, item.path) ?? item.path}:${item.line ?? 1}`, ...(item.path ? { path: item.path } : {}), ...(item.line ? { line: item.line } : {}), detail: item.detail });
    else if (item.kind === "thread") result.push({ kind: "thread", ref: item.ref, detail: item.detail });
  }
  return result;
}

function coordinatorItems(corpus: CoordinatorCorpus, needsYou: CoordinatorItem[], stuck: CoordinatorItem[]): Omit<AttentionItem, "delivered">[] {
  const root = corpus.root;
  const dir = `--dir ${shellQuote(root)}`;
  const items: Omit<AttentionItem, "delivered">[] = [];
  const corpusRef = { id: corpus.id, root };
  for (const item of needsYou) {
    const evidence = coordinatorEvidence(root, item.evidence);
    const at = item.lastSignal?.at;
    if (item.kind === "run" && item.reasonCode === "blocked-question") {
      const question = item.blocking.find((blocker) => blocker.kind === "question")?.summary ?? item.summary;
      items.push({
        fingerprint: fingerprint(["blocked", corpus.id, item.id, question]),
        category: "blocked", title: item.title, summary: clip(`Blocked: ${question}`), corpus: corpusRef,
        ref: `run:${item.id}`, evidence, tags: [], ...(at ? { at } : {}),
        command: `celorga run show ${item.id} ${dir}`,
      });
    } else if (item.kind === "run" && item.reasonCode === "artifact-review") {
      const artifacts = item.blocking.filter((blocker) => blocker.kind === "artifact-review");
      for (const artifact of artifacts) {
        if (artifact.path) evidence.push({ kind: "artifact", ref: `run:${item.id}#artifact:${artifact.artifactId}`, path: path.resolve(root, artifact.path), detail: artifact.summary });
      }
      items.push({
        fingerprint: fingerprint(["review", corpus.id, item.id, artifacts.map((artifact) => artifact.artifactId ?? artifact.path ?? "").sort()]),
        category: "review", title: item.title, summary: clip(item.summary), corpus: corpusRef,
        ref: `run:${item.id}`, evidence, tags: [], ...(at ? { at } : {}),
        command: `celorga review show ${item.id} ${dir}`,
      });
    } else if (item.kind === "thread" && REPLY_REASONS.has(item.reasonCode)) {
      const messageId = item.blocking.find((blocker) => blocker.messageId)?.messageId;
      items.push({
        fingerprint: fingerprint(["reply", corpus.id, item.id.toLowerCase(), item.reasonCode, messageId ?? at ?? null]),
        category: "reply", title: item.title, summary: clip(item.summary), corpus: corpusRef,
        ref: `thread:${item.id}`, evidence, tags: [], ...(at ? { at } : {}),
        command: `celorga thread show ${item.id} ${dir}`,
      });
    } else if (item.kind === "workflow" && item.reasonCode === "dispatch-lock-orphaned") {
      items.push({
        fingerprint: fingerprint(["blocked", corpus.id, `workflow:${item.id}`, item.reasonCode]),
        category: "blocked", title: item.title, summary: clip(item.summary), corpus: corpusRef,
        ref: `workflow:${item.id}`, evidence: [{ kind: "workflow", ref: `workflow:${item.id}`, detail: item.summary }], tags: [], ...(at ? { at } : {}),
        command: `celorga workflow show ${item.id} ${dir}`,
      });
    }
    // Pending approvals (and chats or workflows blocked on them) come from the
    // approvals queue below, so one decision is reported exactly once.
  }
  for (const item of stuck) {
    if (item.kind !== "run" || item.state !== "failed") continue;
    const at = item.lastSignal?.at;
    items.push({
      fingerprint: fingerprint(["failed", corpus.id, item.id, item.summary, at ?? null]),
      category: "failed", title: item.title, summary: clip(item.summary), corpus: corpusRef,
      ref: `run:${item.id}`, evidence: coordinatorEvidence(root, item.evidence), tags: [], ...(at ? { at } : {}),
      command: `celorga run show ${item.id} ${dir}`,
    });
  }
  return items;
}

/**
 * The coordinator lists only chats with live or failing deliveries; an agent
 * reply the person has not read is read from the committed thread summary.
 */
function unreadReplyItems(corpus: CoordinatorCorpus, now: Date, reported: Set<string>): Omit<AttentionItem, "delivered">[] {
  let threads: OpenClawChatThreadRecord[] = [];
  try { threads = loadOpenClawThreadState(corpus.root).threads; } catch { return []; }
  const items: Omit<AttentionItem, "delivered">[] = [];
  for (const thread of threads) {
    const id = String(thread.id);
    if (reported.has(id.toLowerCase()) || thread.isArchived === true || isOpenClawThreadSettled(thread)) continue;
    const unread = typeof thread.unreadMessageCount === "number" ? thread.unreadMessageCount : 0;
    const latest = thread.messages?.at(-1);
    const latestAssistantId = typeof thread.storedLatestAssistantMessageID === "string" ? thread.storedLatestAssistantMessageID
      : latest?.role === "assistant" && latest.id ? String(latest.id) : undefined;
    const lastIsAssistant = latest ? latest.role === "assistant" : Boolean(latestAssistantId);
    if (unread <= 0 || !lastIsAssistant) continue;
    const updatedMs = openClawDateMilliseconds(thread.updatedAt);
    if (!Number.isFinite(updatedMs) || now.getTime() - updatedMs > ACTIVITY_ATTENTION_WINDOW_SECONDS * 1000) continue;
    const at = new Date(updatedMs).toISOString();
    items.push({
      fingerprint: fingerprint(["reply", corpus.id, id.toLowerCase(), "reply-received", latestAssistantId ?? at]),
      category: "reply",
      title: String(thread.title || "Untitled chat"),
      summary: `Agent replied; ${unread} unread message(s)`,
      corpus: { id: corpus.id, root: corpus.root },
      ref: `thread:${id}`,
      evidence: [{ kind: "thread", ref: `thread:${id}`, detail: "Committed chat transcript" }],
      tags: [],
      at,
      command: `celorga thread show ${id} --dir ${shellQuote(corpus.root)}`,
    });
  }
  return items;
}

function approvalItems(corpus: CoordinatorCorpus, payload: ApprovalsPayload): Omit<AttentionItem, "delivered">[] {
  const root = corpus.root;
  const dir = `--dir ${shellQuote(root)}`;
  return payload.items.map((item) => {
    const tags = (item.tags ?? []).map((tag) => tag.toLowerCase());
    if (item.kind === "run" && item.runId && item.approvalId) {
      return {
        fingerprint: fingerprint(["approval", corpus.id, item.runId, item.approvalId, item.fingerprint ?? null]),
        category: "approval" as const,
        title: item.title,
        summary: clip(`Approve: ${item.title}${item.runGoal && item.runGoal !== item.title ? ` (${item.runGoal})` : ""}`),
        corpus: { id: corpus.id, root },
        ref: `run:${item.runId}`,
        evidence: [
          { kind: "approval" as const, ref: `run:${item.runId}#approval:${item.approvalId}`, ...(item.action ? { detail: clip(item.action, 200) } : {}) },
          { kind: "run" as const, ref: `run:${item.runId}`, path: item.file },
        ],
        tags,
        ...(item.requestedAt ? { at: item.requestedAt } : {}),
        command: `celorga run approval-decide ${item.runId} ${item.approvalId} --decision approved|rejected --fingerprint ${item.fingerprint ?? "SHA256"} --actor NAME ${dir}`,
      };
    }
    const relative = relativeInside(root, item.file) ?? item.file;
    return {
      fingerprint: fingerprint(["approval", corpus.id, item.idValue ? `id:${item.idValue}` : `${relative}::${item.title}`, item.status]),
      category: "approval" as const,
      title: item.title,
      summary: clip(`Review: ${item.title} (${item.status})`),
      corpus: { id: corpus.id, root },
      ref: `${relative}:${item.line}`,
      evidence: [{ kind: "file" as const, ref: `${relative}:${item.line}`, path: item.file, line: item.line }],
      tags,
      command: `celorga approvals ${dir}`,
    };
  });
}

function agendaItems(corpus: CoordinatorCorpus, payload: AgendaPayload, today: string): Omit<AttentionItem, "delivered">[] {
  const root = corpus.root;
  const items: Omit<AttentionItem, "delivered">[] = [];
  const make = (category: "overdue" | "today", date: string, item: AgendaItem): Omit<AttentionItem, "delivered"> => {
    const relative = relativeInside(root, item.file) ?? item.file;
    const line = item.line + 1; // agenda JSON lines are 0-based
    const kind = item.kind.toUpperCase();
    const identity = item.id ? `id:${item.id}` : `${relative}::${item.headline}`;
    const when = `${date}${item.time ? ` ${item.time}` : ""}`;
    const summary = category === "overdue"
      ? `Deadline passed on ${date}`
      : kind === "DEADLINE" ? `Due today${item.time ? ` at ${item.time}` : ""}` : `Scheduled today${item.time ? ` at ${item.time}` : ""}`;
    return {
      fingerprint: fingerprint([category, corpus.id, identity, kind, date, item.time ?? null]),
      category,
      title: `${item.todo ? `${item.todo} ` : ""}${item.headline}`,
      summary,
      corpus: { id: corpus.id, root },
      ref: `${relative}:${line}`,
      evidence: [{ kind: "file", ref: `${relative}:${line}`, path: item.file, line, detail: `${kind} ${when}` }],
      tags: (item.tags ?? []).map((tag) => tag.toLowerCase()),
      at: when,
    };
  };
  const actionable = (item: AgendaItem) => !item.todoTerminal && !item.deadlineWarning && !item.habit;
  for (const day of payload.overdue ?? []) {
    for (const item of day.items) if (actionable(item) && item.kind.toUpperCase() === "DEADLINE") items.push(make("overdue", day.date, item));
  }
  for (const day of payload.days ?? []) {
    if (day.date !== today) continue;
    for (const item of day.items) {
      const kind = item.kind.toUpperCase();
      if (actionable(item) && (kind === "DEADLINE" || kind === "SCHEDULED")) items.push(make("today", day.date, item));
    }
  }
  return items;
}

function itemPaths(root: string, item: Omit<AttentionItem, "delivered">): string[] {
  return item.evidence.map((evidence) => relativeInside(root, evidence.path)).filter((value): value is string => Boolean(value));
}

function keepItem(item: Omit<AttentionItem, "delivered">, preferences: AttentionPreferences, cutoffMs: number | undefined): boolean {
  if (!preferences.categories.includes(item.category)) return false;
  if (item.tags.some((tag) => preferences.excludeTags.includes(tag))) return false;
  if (preferences.excludePaths.length) {
    const paths = itemPaths(item.corpus.root, item);
    if (paths.some((candidate) => preferences.excludePaths.some((pattern) => configPathMatches(candidate, pattern)))) return false;
  }
  if (cutoffMs !== undefined && ["blocked", "review", "reply", "failed"].includes(item.category) && item.at) {
    if (Date.parse(item.at) < cutoffMs) return false;
  }
  return true;
}

const CATEGORY_LABELS: Record<AttentionCategory, string> = {
  approval: "Approval",
  blocked: "Blocked",
  review: "Review",
  reply: "Reply",
  failed: "Failed",
  overdue: "Overdue",
  today: "Today",
};

/** Deterministic notification text: counts plus the first few titles. */
export function attentionNotificationText(items: AttentionItem[], mode: AttentionMode): { title: string; body: string } {
  const count = items.length;
  const title = mode === "brief"
    ? `Celorga brief: ${count} item${count === 1 ? "" : "s"} need${count === 1 ? "s" : ""} you`
    : `Celorga: ${count} new item${count === 1 ? "" : "s"} need${count === 1 ? "s" : ""} you`;
  const lines = items.slice(0, 3).map((item) => `${CATEGORY_LABELS[item.category]}: ${clip(item.title, 80)}`);
  if (count > 3) lines.push(`and ${count - 3} more`);
  return { title, body: lines.join("\n") };
}

export async function buildAttentionDigest(options: AttentionDigestOptions = {}): Promise<AttentionDigest> {
  const now = options.now ?? new Date();
  const mode = options.mode ?? "check";
  const today = localDate(now);
  const coordination = coordinateWorkspace({ mounts: options.mounts, root: options.root, now });
  const corpora = coordination.corpora;
  const issues = [...coordination.issues];
  if (options.apply && !options.markDelivered) throw new Error("--apply requires --mark-delivered; the attention digest itself is read-only");
  if (options.markDelivered && corpora.length !== 1) throw new Error("--mark-delivered writes one corpus's delivery ledger; name exactly one --dir or --mount corpus");

  // Schedule and quiet hours come from the first corpus; each corpus filters its own items.
  const primary = corpora[0];
  const primaryPreferences = primary ? loadAttentionPreferences(primary.root) : { preferences: validateAttentionConfig(undefined).preferences, file: null };
  const cutoffMs = options.sinceSeconds !== undefined ? now.getTime() - options.sinceSeconds * 1000 : undefined;

  const perCorpus = await Promise.all(corpora.map(async (corpus) => {
    const preferences = corpus === primary ? primaryPreferences.preferences : loadAttentionPreferences(corpus.root).preferences;
    const collected: Omit<AttentionItem, "delivered">[] = [];
    const corpusIssues: Array<{ root: string; message: string }> = [];
    const needsAgenda = preferences.categories.some((category) => category === "overdue" || category === "today");
    const needsApprovals = preferences.categories.includes("approval");
    const [agenda, approvals] = await Promise.all([
      needsAgenda ? runCorpusJSON<AgendaPayload>(corpus.root, ["agenda", "--from", today, "--to", today]).catch((error: unknown) => error) : undefined,
      needsApprovals ? runCorpusJSON<ApprovalsPayload>(corpus.root, ["approvals"]).catch((error: unknown) => error) : undefined,
    ]);
    if (approvals !== undefined) {
      if (approvals instanceof Error || !(approvals as ApprovalsPayload).items) {
        const message = errorText(approvals);
        if (!isEmptyCorpusError(message)) corpusIssues.push({ root: corpus.root, message: `approvals: ${message}` });
      } else collected.push(...approvalItems(corpus, approvals as ApprovalsPayload));
    }
    const needsYou = coordination.needsYou.filter((item) => item.corpus.id === corpus.id);
    collected.push(...coordinatorItems(corpus, needsYou, coordination.stuck.filter((item) => item.corpus.id === corpus.id)));
    if (preferences.categories.includes("reply")) {
      const reportedThreads = new Set(needsYou.filter((item) => item.kind === "thread").map((item) => item.id.toLowerCase()));
      collected.push(...unreadReplyItems(corpus, now, reportedThreads));
    }
    if (agenda !== undefined) {
      if (agenda instanceof Error || !(agenda as AgendaPayload).days) {
        const message = errorText(agenda);
        if (!isEmptyCorpusError(message)) corpusIssues.push({ root: corpus.root, message: `agenda: ${message}` });
      } else collected.push(...agendaItems(corpus, agenda as AgendaPayload, today));
    }
    const { ledger, revision, file } = readLedger(corpus.root, corpus.id);
    const seen = new Set<string>();
    const items: AttentionItem[] = [];
    for (const item of collected) {
      if (seen.has(item.fingerprint) || !keepItem(item, preferences, cutoffMs)) continue;
      seen.add(item.fingerprint);
      const delivered = ledger.delivered[item.fingerprint];
      items.push({ ...item, delivered: Boolean(delivered), ...(delivered ? { deliveredAt: delivered.deliveredAt } : {}) });
    }
    return { corpus, items, issues: corpusIssues, ledger, revision, file };
  }));

  const items = perCorpus.flatMap((entry) => entry.items).sort((left, right) =>
    (CATEGORY_ORDER.get(left.category)! - CATEGORY_ORDER.get(right.category)!)
    || String(left.at ?? "").localeCompare(String(right.at ?? ""))
    || left.title.localeCompare(right.title)
    || left.fingerprint.localeCompare(right.fingerprint));
  for (const entry of perCorpus) issues.push(...entry.issues);
  issues.sort((left, right) => left.root.localeCompare(right.root) || left.message.localeCompare(right.message));

  const preferences = primaryPreferences.preferences;
  const quiet = inQuietHours(now, preferences.quietHours);
  const fresh = items.filter((item) => !item.delivered);
  const announced = mode === "brief" ? items : fresh;
  let interrupt = false;
  let interruptReason: string;
  if (!items.length) interruptReason = "Nothing needs you";
  else if (quiet) interruptReason = `Quiet hours ${preferences.quietHours!.start}–${preferences.quietHours!.end}; ${announced.length} item(s) held`;
  else if (!announced.length) interruptReason = `All ${items.length} item(s) were already delivered`;
  else {
    interrupt = true;
    interruptReason = mode === "brief" ? `Brief: ${items.length} item(s) need you` : `${fresh.length} new item(s) need you`;
  }
  const notification = interrupt ? { ...attentionNotificationText(announced, mode), fingerprints: announced.map((item) => item.fingerprint) } : null;

  const single = perCorpus.length === 1 ? perCorpus[0]! : undefined;
  const delivery: AttentionDigest["delivery"] = {
    file: single?.file ?? null,
    revision: single?.revision ?? null,
    requested: options.markDelivered === true,
    applied: false,
    marked: [],
  };
  if (options.markDelivered && single) {
    const requested = options.fingerprints?.length ? new Set(options.fingerprints) : undefined;
    if (requested) {
      const known = new Set(single.items.map((item) => item.fingerprint));
      const unknown = [...requested].filter((value) => !known.has(value));
      if (unknown.length) throw new Error(`fingerprint(s) not in the current digest: ${unknown.join(", ")}. Nothing was marked.`);
    }
    const toMark = single.items.filter((item) => !item.delivered && (!requested || requested.has(item.fingerprint)));
    delivery.marked = toMark.map((item) => item.fingerprint);
    if (options.ifRevision !== undefined) {
      const expected = options.ifRevision === "absent" ? null : options.ifRevision;
      if (expected !== single.revision) throw new Error(`attention delivery ledger changed; expected ${options.ifRevision}, found ${single.revision ?? "absent"}. Nothing was marked.`);
    }
    if (options.apply && toMark.length) {
      const deliveredAt = now.toISOString();
      const current = new Set(single.items.map((item) => item.fingerprint));
      const retentionMs = ATTENTION_DELIVERED_RETENTION_DAYS * 86_400_000;
      const kept: Record<string, DeliveredEntry> = {};
      for (const [key, entry] of Object.entries(single.ledger.delivered)) {
        if (current.has(key) || now.getTime() - Date.parse(entry.deliveredAt) < retentionMs) kept[key] = entry;
      }
      for (const item of toMark) {
        kept[item.fingerprint] = { deliveredAt, category: item.category, title: clip(item.title, 120) };
        item.delivered = true;
        item.deliveredAt = deliveredAt;
      }
      const ledger: DeliveredLedger = { schema: ATTENTION_DELIVERED_SCHEMA, corpusId: single.corpus.id, delivered: kept };
      const saved = guardedWriteFile(single.file, `${JSON.stringify(ledger, null, 2)}\n`, { expectedRevision: single.revision });
      delivery.applied = true;
      delivery.revision = saved.revision;
    }
  }

  const byCategory = Object.fromEntries(ATTENTION_CATEGORIES.map((category) => [category, items.filter((item) => item.category === category).length])) as Record<AttentionCategory, number>;
  return {
    schema: ATTENTION_DIGEST_SCHEMA,
    generatedAt: now.toISOString(),
    mode,
    local: { date: today, time: localClock(now), timezone: Intl.DateTimeFormat().resolvedOptions().timeZone },
    corpora,
    issues,
    preferences,
    preferencesFile: primaryPreferences.file,
    quietHours: { active: quiet, ...(preferences.quietHours ?? {}) },
    items,
    summary: { total: items.length, new: fresh.length, delivered: items.length - fresh.length, byCategory },
    interrupt,
    interruptReason,
    notification,
    delivery,
  };
}

/** Plain-text rendering for terminals and chat; JSON remains the contract. */
export function renderAttentionDigestText(digest: AttentionDigest): string {
  const lines: string[] = [];
  lines.push(`Attention ${digest.local.date} ${digest.local.time}: ${digest.summary.total} item(s), ${digest.summary.new} new — interrupt: ${digest.interrupt ? "yes" : "no"} (${digest.interruptReason})`);
  for (const issue of digest.issues) lines.push(`  issue ${issue.root}: ${issue.message}`);
  const multi = digest.corpora.length > 1;
  for (const item of digest.items) {
    lines.push(`  ${item.delivered ? "    " : "NEW "}[${item.category}] ${multi ? `[${item.corpus.id}] ` : ""}${clip(item.title, 100)} — ${item.ref}`);
    lines.push(`      ${item.summary}${item.command ? `\n      → ${item.command}` : ""}`);
  }
  if (digest.delivery.requested) {
    lines.push("", digest.delivery.applied
      ? `Marked ${digest.delivery.marked.length} item(s) delivered in ${digest.delivery.file}`
      : `Would mark ${digest.delivery.marked.length} item(s) delivered; re-run with --apply to record it`);
  }
  return lines.join("\n");
}
