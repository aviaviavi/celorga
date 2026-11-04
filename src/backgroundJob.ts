import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { queueAIChatInboxMessage } from "./aiChatInbox.js";
import { org2CorpusIndexDir } from "./indexPaths.js";

/**
 * Background jobs that outlive the agent turn that started them.
 *
 * A job is a detached supervisor process that runs one command with its output
 * in a log file, records the exit, and optionally posts one message to an AI
 * chat thread. Records hold process IDs, so they live in the machine-local
 * per-corpus index directory rather than the (possibly synced) corpus.
 */

export const BACKGROUND_JOB_SCHEMA = "celorga:background-job:v1";
export const BACKGROUND_JOB_DEFAULT_AUTHOR = "Background job";
export const BACKGROUND_JOB_TAIL_LINES = 20;

export type BackgroundJobState = "starting" | "running" | "succeeded" | "failed" | "stopped" | "lost";

export interface BackgroundJobDelivery {
  status: "queued" | "delivered" | "failed";
  messageID?: string;
  file?: string;
  error?: string;
}

export interface BackgroundJobRecord {
  schema: typeof BACKGROUND_JOB_SCHEMA;
  id: string;
  label: string;
  command: string[];
  cwd: string;
  corpusRoot: string;
  host: string;
  threadID?: string;
  authorLabel: string;
  authorAgentRef?: string;
  logFile: string;
  createdAt: string;
  state: Exclude<BackgroundJobState, "lost">;
  supervisorPid?: number;
  /** Command PID; the command leads its own process group. */
  pid?: number;
  startedAt?: string;
  endedAt?: string;
  exitCode?: number | null;
  signal?: string | null;
  stopRequestedAt?: string;
  delivery?: BackgroundJobDelivery;
}

export interface BackgroundJobView extends Omit<BackgroundJobRecord, "state"> {
  state: BackgroundJobState;
  running: boolean;
  durationMs?: number;
}

const JOB_ID_PATTERN = /^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$/u;
/** A supervisor that never recorded a start within this window is lost. */
const STARTING_TIMEOUT_MS = 60_000;

function resolvedRoot(corpusRoot: string): string {
  const resolved = path.resolve(corpusRoot);
  try {
    return fs.realpathSync(resolved);
  } catch {
    return resolved;
  }
}

export function backgroundJobsDirectory(corpusRoot: string): string {
  return path.join(org2CorpusIndexDir(resolvedRoot(corpusRoot)), "jobs");
}

export function validateBackgroundJobID(raw: string): string {
  const id = String(raw || "").trim();
  if (!JOB_ID_PATTERN.test(id)) throw new Error(`invalid job ID: ${raw}`);
  return id;
}

function jobDirectory(corpusRoot: string, id: string): string {
  return path.join(backgroundJobsDirectory(corpusRoot), validateBackgroundJobID(id));
}

function recordFile(corpusRoot: string, id: string): string {
  return path.join(jobDirectory(corpusRoot, id), "job.json");
}

function stopMarkerFile(corpusRoot: string, id: string): string {
  return path.join(jobDirectory(corpusRoot, id), "stop-requested");
}

function newJobID(now: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `${stamp}-${crypto.randomBytes(3).toString("hex")}`;
}

function writeRecord(corpusRoot: string, record: BackgroundJobRecord): void {
  const file = recordFile(corpusRoot, record.id);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, file);
}

export function readBackgroundJobRecord(corpusRoot: string, id: string): BackgroundJobRecord {
  const file = recordFile(corpusRoot, id);
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    throw new Error(`unknown job: ${id}`);
  }
  const record = JSON.parse(raw) as BackgroundJobRecord;
  if (record?.schema !== BACKGROUND_JOB_SCHEMA || record.id !== id) {
    throw new Error(`invalid job record: ${file}`);
  }
  return record;
}

function processAlive(pid: number | undefined): boolean {
  if (!pid || !Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function processGroupAlive(pid: number | undefined): boolean {
  if (!pid || !Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

function signalGroup(pid: number | undefined, signal: NodeJS.Signals): boolean {
  if (!pid || !Number.isInteger(pid) || pid <= 1) return false;
  try {
    process.kill(-pid, signal);
    return true;
  } catch {
    return false;
  }
}

export function effectiveBackgroundJobState(record: BackgroundJobRecord, now = Date.now()): BackgroundJobState {
  if (record.state === "running") return processAlive(record.supervisorPid) ? "running" : "lost";
  if (record.state === "starting") {
    if (record.supervisorPid) return processAlive(record.supervisorPid) ? "starting" : "lost";
    const created = Date.parse(record.createdAt);
    return Number.isFinite(created) && now - created > STARTING_TIMEOUT_MS ? "lost" : "starting";
  }
  return record.state;
}

export function backgroundJobView(record: BackgroundJobRecord, now = Date.now()): BackgroundJobView {
  const state = effectiveBackgroundJobState(record, now);
  const started = Date.parse(record.startedAt || record.createdAt);
  const ended = record.endedAt ? Date.parse(record.endedAt) : now;
  return {
    ...record,
    state,
    running: state === "starting" || state === "running",
    ...(Number.isFinite(started) && Number.isFinite(ended) ? { durationMs: Math.max(0, ended - started) } : {}),
  };
}

function stripTerminalControls(text: string): string {
  return text
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/gu, "")
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/gu, "")
    .replace(/\u001b[@-_]/gu, "")
    .split("\n")
    .map((line) => line.slice(line.lastIndexOf("\r") + 1))
    .join("\n")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/gu, "");
}

export function backgroundJobLogTail(logFile: string, lines = BACKGROUND_JOB_TAIL_LINES, maxCharacters = 4_000): string {
  let text: string;
  try {
    const size = fs.statSync(logFile).size;
    const length = Math.min(size, 64 * 1024);
    const buffer = Buffer.alloc(length);
    const descriptor = fs.openSync(logFile, "r");
    try {
      fs.readSync(descriptor, buffer, 0, length, size - length);
    } finally {
      fs.closeSync(descriptor);
    }
    text = buffer.toString("utf8");
  } catch {
    return "";
  }
  const kept = stripTerminalControls(text).replace(/\s+$/u, "").split("\n").slice(-Math.max(1, lines)).join("\n");
  return kept.length > maxCharacters ? kept.slice(kept.length - maxCharacters) : kept;
}

export function formatBackgroundJobDuration(milliseconds: number | undefined): string {
  if (milliseconds === undefined || !Number.isFinite(milliseconds)) return "unknown time";
  const seconds = Math.round(milliseconds / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

function shellQuote(argument: string): string {
  return /^[A-Za-z0-9_./:=@%+,-]+$/u.test(argument) ? argument : `'${argument.replace(/'/gu, `'\\''`)}'`;
}

export function backgroundJobCommandLine(command: readonly string[]): string {
  return command.map(shellQuote).join(" ");
}

function orgVerbatim(text: string): string {
  return /[=\n]/u.test(text) ? text.replace(/\n/gu, " ") : `=${text}=`;
}

function outcomeText(view: BackgroundJobView): string {
  const duration = formatBackgroundJobDuration(view.durationMs);
  if (view.state === "succeeded") return `succeeded after ${duration}`;
  if (view.state === "stopped") return `was stopped after ${duration}`;
  if (view.state === "lost") return `lost its supervisor after ${duration}`;
  if (view.signal) return `ended by ${view.signal} after ${duration}`;
  return `failed with exit code ${view.exitCode ?? "unknown"} after ${duration}`;
}

/** The single message a job posts to its thread when it ends. */
export function backgroundJobExitMessage(view: BackgroundJobView, tail: string): string {
  const escapedTail = (tail || "(no output)")
    .split("\n")
    .map((line) => (/^\s*(?:\*|#\+|,\*|,#\+)/u.test(line) ? `,${line}` : line))
    .join("\n");
  return [
    `Background job *${view.label.replace(/\*/gu, "")}* ${outcomeText(view)}.`,
    "",
    `- Command: ${orgVerbatim(backgroundJobCommandLine(view.command))}`,
    `- Directory: ${orgVerbatim(view.cwd)}`,
    `- Log: ${orgVerbatim(view.logFile)}`,
    `- Job: ${orgVerbatim(view.id)}`,
    "",
    "Last lines of output:",
    "",
    "#+begin_example",
    escapedTail,
    "#+end_example",
  ].join("\n");
}

export function backgroundJobIdempotencyKey(id: string): string {
  return `job:${id}:exit`;
}

function deliverExitMessage(record: BackgroundJobRecord): BackgroundJobDelivery | undefined {
  if (!record.threadID) return undefined;
  const view = backgroundJobView(record);
  try {
    const result = queueAIChatInboxMessage(record.corpusRoot, record.threadID, backgroundJobExitMessage(view, backgroundJobLogTail(record.logFile)), {
      authorLabel: record.authorLabel,
      ...(record.authorAgentRef ? { authorAgentRef: record.authorAgentRef } : {}),
      source: `job:${record.id}`,
      idempotencyKey: backgroundJobIdempotencyKey(record.id),
      apply: true,
    });
    return {
      status: result.deliveryStatus === "delivered" ? "delivered" : "queued",
      messageID: result.message.id,
      file: result.file,
    };
  } catch (error) {
    return { status: "failed", error: error instanceof Error ? error.message : String(error) };
  }
}

export interface StartBackgroundJobOptions {
  command: string[];
  label?: string;
  cwd?: string;
  threadID?: string;
  authorLabel?: string;
  authorAgentRef?: string;
  apply?: boolean;
  now?: Date;
  /** Override the CLI entry used for the supervisor (tests). */
  cliPath?: string;
}

export interface StartBackgroundJobResult {
  applied: boolean;
  job: BackgroundJobView;
  commandLine: string;
}

export function startBackgroundJob(corpusRoot: string, options: StartBackgroundJobOptions): StartBackgroundJobResult {
  const command = options.command.filter((part, index) => index > 0 || part.trim());
  if (command.length === 0) throw new Error("job start requires -- COMMAND [ARGS...]");
  const root = path.resolve(corpusRoot);
  const cwd = path.resolve(options.cwd || process.cwd());
  if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error(`--cwd is not a directory: ${cwd}`);
  const authorAgentRef = options.authorAgentRef?.trim() || undefined;
  const authorLabel = options.authorLabel?.trim() || BACKGROUND_JOB_DEFAULT_AUTHOR;
  const label = (options.label?.trim() || backgroundJobCommandLine(command)).slice(0, 200);
  let threadID: string | undefined;
  if (options.threadID?.trim()) {
    // Validate the thread and author now so a typo fails before the job runs.
    const preview = queueAIChatInboxMessage(root, options.threadID, "Background job preview", {
      authorLabel,
      ...(authorAgentRef ? { authorAgentRef } : {}),
      source: "job:preview",
    });
    threadID = preview.message.threadID;
  }
  const now = options.now || new Date();
  const id = newJobID(now);
  const directory = jobDirectory(root, id);
  const record: BackgroundJobRecord = {
    schema: BACKGROUND_JOB_SCHEMA,
    id,
    label,
    command,
    cwd,
    corpusRoot: root,
    host: os.hostname(),
    ...(threadID ? { threadID } : {}),
    authorLabel,
    ...(authorAgentRef ? { authorAgentRef } : {}),
    logFile: path.join(directory, "output.log"),
    createdAt: now.toISOString(),
    state: "starting",
  };
  const commandLine = backgroundJobCommandLine(command);
  if (!options.apply) return { applied: false, job: backgroundJobView(record, now.getTime()), commandLine };

  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.writeFileSync(record.logFile, "", { flag: "a", mode: 0o600 });
  writeRecord(root, record);
  const cliPath = options.cliPath || fileURLToPath(new URL("./cli.js", import.meta.url));
  const supervisorLog = fs.openSync(path.join(directory, "supervisor.log"), "a", 0o600);
  try {
    // A new session and no inherited stdio: ending the caller's process tree
    // (for example an agent turn) leaves the supervisor running.
    const supervisor = spawn(process.execPath, [cliPath, "job", "_supervise", id, "--dir", root], {
      cwd,
      detached: true,
      stdio: ["ignore", supervisorLog, supervisorLog],
      env: process.env,
    });
    supervisor.unref();
    if (!supervisor.pid) throw new Error("could not start the job supervisor");
  } finally {
    fs.closeSync(supervisorLog);
  }
  return { applied: true, job: backgroundJobView(readBackgroundJobRecord(root, id)), commandLine };
}

/** Runs inside the detached supervisor: execute, record, and report once. */
export async function superviseBackgroundJob(corpusRoot: string, id: string): Promise<BackgroundJobRecord> {
  const root = path.resolve(corpusRoot);
  let record = readBackgroundJobRecord(root, id);
  if (record.state !== "starting") return record;
  process.on("SIGHUP", () => {});
  const finish = (fields: Partial<BackgroundJobRecord>): BackgroundJobRecord => {
    let stopRequestedAt: string | undefined;
    if (fields.state === "stopped") {
      try {
        stopRequestedAt = fs.readFileSync(stopMarkerFile(root, id), "utf8").trim() || undefined;
      } catch {
        stopRequestedAt = undefined;
      }
    }
    record = {
      ...record,
      ...fields,
      ...(stopRequestedAt ? { stopRequestedAt } : {}),
      endedAt: new Date().toISOString(),
    } as BackgroundJobRecord;
    writeRecord(root, record);
    const delivery = deliverExitMessage(record);
    if (delivery) {
      record = { ...record, delivery };
      writeRecord(root, record);
    }
    return record;
  };
  const stopRequested = () => fs.existsSync(stopMarkerFile(root, id));
  if (stopRequested()) {
    return finish({ state: "stopped", supervisorPid: process.pid, startedAt: new Date().toISOString(), exitCode: null, signal: null });
  }

  const log = fs.openSync(record.logFile, "a");
  let child;
  try {
    child = spawn(record.command[0]!, record.command.slice(1), {
      cwd: record.cwd,
      detached: true,
      stdio: ["ignore", log, log],
      env: process.env,
    });
  } catch (error) {
    fs.closeSync(log);
    fs.appendFileSync(record.logFile, `celorga job: ${error instanceof Error ? error.message : String(error)}\n`);
    return finish({ state: "failed", supervisorPid: process.pid, startedAt: new Date().toISOString(), exitCode: 127, signal: null });
  }
  fs.closeSync(log);
  const outcome = await new Promise<{ code: number | null; signal: NodeJS.Signals | null; error?: Error }>((resolve) => {
    let settled = false;
    child.once("error", (error) => {
      if (settled) return;
      settled = true;
      resolve({ code: 127, signal: null, error });
    });
    child.once("exit", (code, signal) => {
      if (settled) return;
      settled = true;
      resolve({ code, signal });
    });
    if (child.pid) {
      record = { ...record, state: "running", supervisorPid: process.pid, pid: child.pid, startedAt: new Date().toISOString() };
      writeRecord(root, record);
      // A stop may have arrived while the command was launching.
      if (stopRequested()) signalGroup(child.pid, "SIGTERM");
    }
  });
  if (outcome.error) {
    fs.appendFileSync(record.logFile, `celorga job: could not run ${record.command[0]}: ${outcome.error.message}\n`);
  }
  const state: BackgroundJobRecord["state"] = stopRequested()
    ? "stopped"
    : outcome.code === 0 ? "succeeded" : "failed";
  return finish({
    state,
    supervisorPid: process.pid,
    startedAt: record.startedAt || new Date().toISOString(),
    exitCode: outcome.code,
    signal: outcome.signal,
  });
}

export interface ListBackgroundJobsOptions {
  threadID?: string;
  all?: boolean;
  limit?: number;
}

export interface ListBackgroundJobsResult {
  schema: "celorga:background-jobs:v1";
  directory: string;
  jobs: BackgroundJobView[];
}

export function listBackgroundJobs(corpusRoot: string, options: ListBackgroundJobsOptions = {}): ListBackgroundJobsResult {
  const directory = backgroundJobsDirectory(corpusRoot);
  const thread = options.threadID?.trim().toLowerCase();
  let names: string[] = [];
  try {
    names = fs.readdirSync(directory).filter((name) => JOB_ID_PATTERN.test(name));
  } catch {
    names = [];
  }
  const now = Date.now();
  const jobs: BackgroundJobView[] = [];
  for (const name of names) {
    let record: BackgroundJobRecord;
    try {
      record = readBackgroundJobRecord(corpusRoot, name);
    } catch {
      continue;
    }
    if (thread && record.threadID?.toLowerCase() !== thread) continue;
    const view = backgroundJobView(record, now);
    if (!options.all && !view.running) continue;
    jobs.push(view);
  }
  jobs.sort((left, right) => right.createdAt.localeCompare(left.createdAt) || right.id.localeCompare(left.id));
  const limit = options.limit ?? (options.all ? 20 : Number.POSITIVE_INFINITY);
  return { schema: "celorga:background-jobs:v1", directory, jobs: jobs.slice(0, limit) };
}

export interface BackgroundJobStatus {
  schema: "celorga:background-job-status:v1";
  job: BackgroundJobView;
  logTail: string;
}

export function backgroundJobStatus(corpusRoot: string, id: string, tailLines = BACKGROUND_JOB_TAIL_LINES): BackgroundJobStatus {
  const record = readBackgroundJobRecord(corpusRoot, validateBackgroundJobID(id));
  return {
    schema: "celorga:background-job-status:v1",
    job: backgroundJobView(record),
    logTail: backgroundJobLogTail(record.logFile, tailLines),
  };
}

export interface StopBackgroundJobOptions {
  apply?: boolean;
  graceMs?: number;
}

export interface StopBackgroundJobResult {
  applied: boolean;
  changed: boolean;
  job: BackgroundJobView;
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitFor(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await sleep(100);
  }
  return condition();
}

export async function stopBackgroundJob(corpusRoot: string, rawID: string, options: StopBackgroundJobOptions = {}): Promise<StopBackgroundJobResult> {
  const root = path.resolve(corpusRoot);
  const id = validateBackgroundJobID(rawID);
  const graceMs = Math.max(0, options.graceMs ?? 5_000);
  let record = readBackgroundJobRecord(root, id);
  let view = backgroundJobView(record);
  if (!view.running && view.state !== "lost") return { applied: false, changed: false, job: view };
  if (!options.apply) return { applied: false, changed: true, job: view };

  const requestedAt = new Date().toISOString();
  fs.writeFileSync(stopMarkerFile(root, id), `${requestedAt}\n`, { mode: 0o600 });
  const isFinal = () => {
    record = readBackgroundJobRecord(root, id);
    return !["starting", "running"].includes(record.state);
  };

  if (view.state === "starting" && !record.pid) {
    // The supervisor checks the stop marker before and after launching.
    await waitFor(() => isFinal() || Boolean(record.pid), graceMs);
  }
  if (!isFinal()) {
    const pid = record.pid;
    signalGroup(pid, "SIGTERM");
    if (!(await waitFor(() => !processGroupAlive(pid), graceMs))) signalGroup(pid, "SIGKILL");
    await waitFor(() => !processGroupAlive(pid), 2_000);
    if (processAlive(record.supervisorPid)) await waitFor(isFinal, 5_000);
  }
  if (!isFinal()) {
    // The supervisor is gone, so record the stop and report it here once.
    record = {
      ...record,
      state: "stopped",
      exitCode: null,
      signal: null,
      endedAt: new Date().toISOString(),
      stopRequestedAt: requestedAt,
    };
    writeRecord(root, record);
    const delivery = deliverExitMessage(record);
    if (delivery) {
      record = { ...record, delivery };
      writeRecord(root, record);
    }
  }
  view = backgroundJobView(readBackgroundJobRecord(root, id));
  return { applied: true, changed: true, job: view };
}
