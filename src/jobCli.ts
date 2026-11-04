import path from "node:path";
import {
  backgroundJobCommandLine,
  backgroundJobStatus,
  formatBackgroundJobDuration,
  listBackgroundJobs,
  startBackgroundJob,
  stopBackgroundJob,
  superviseBackgroundJob,
  type BackgroundJobView,
} from "./backgroundJob.js";

const HELP = `celorga job: run long commands that outlive the agent turn that started them

Usage:
  celorga job start [--dir CORPUS] [--thread THREAD_ID] [--label TEXT] [--cwd DIR]
                    [--author NAME] [--agent-ref ID] [--apply] [--json] -- COMMAND [ARGS...]
  celorga job list [--dir CORPUS] [--thread THREAD_ID] [--all] [--limit N] [--json]
  celorga job status JOB_ID [--dir CORPUS] [--lines N] [--json]
  celorga job stop JOB_ID [--dir CORPUS] [--grace SECONDS] [--apply] [--json]

start   Preview, or with --apply start, COMMAND in a detached session that survives the caller
        (an agent turn, a terminal) exiting. Output goes to a log file. COMMAND runs without a
        shell; use sh -c 'A && B' for pipelines. With --thread, one message with the outcome,
        duration, and last lines of output is posted to that AI chat when the job ends
        (author defaults to "Background job"; idempotency key job:JOB_ID:exit).
list    Running jobs for the corpus, newest first. --all includes recent finished jobs.
status  State (starting, running, succeeded, failed, stopped, or lost), exit code, and log tail.
        lost means the supervisor died before recording an exit.
stop    Preview, or with --apply send SIGTERM to the job's process group, then SIGKILL after
        --grace seconds (default 5). A stopped job with a thread reports that it was stopped.

Job records and logs are disposable machine-local state outside the corpus.
`;

interface Parsed {
  positional: string[];
  flags: Map<string, string>;
  command: string[];
}

const BOOLEAN_FLAGS = new Set(["apply", "json", "all", "help"]);

function parse(args: string[]): Parsed {
  const positional: string[] = [];
  const flags = new Map<string, string>();
  let command: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index]!;
    if (item === "--") { command = args.slice(index + 1); break; }
    if (item === "-h") { flags.set("help", "true"); continue; }
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    let value: string;
    if (equal >= 0) value = item.slice(equal + 1);
    else if (BOOLEAN_FLAGS.has(name)) value = "true";
    else {
      const next = args[index + 1];
      if (next === undefined || next.startsWith("--")) throw new Error(`--${name} requires a value`);
      value = next;
      index += 1;
    }
    flags.set(name, value);
  }
  return { positional, flags, command };
}

function json(parsed: Parsed): boolean { return parsed.flags.has("json") || parsed.flags.get("format") === "json"; }
function output(parsed: Parsed, value: unknown, text: string): void {
  process.stdout.write(json(parsed) ? `${JSON.stringify(value, null, 2)}\n` : `${text}\n`);
}
function required(value: string | undefined, message: string): string {
  if (!value) throw new Error(message);
  return value;
}
function count(raw: string | undefined, label: string): number | undefined {
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${label} must be a positive whole number`);
  return value;
}

function describe(job: BackgroundJobView): string {
  const exit = job.state === "failed" ? ` exit ${job.signal || job.exitCode}` : "";
  return `${job.id}\t${job.state}${exit}\t${formatBackgroundJobDuration(job.durationMs)}\t${job.label}`;
}

const KNOWN_FLAGS: Record<string, string[]> = {
  start: ["dir", "thread", "label", "cwd", "author", "agent-ref", "apply", "json", "format"],
  list: ["dir", "thread", "all", "limit", "json", "format"],
  status: ["dir", "lines", "json", "format"],
  stop: ["dir", "grace", "apply", "json", "format"],
  _supervise: ["dir"],
};

export async function runJobCommand(args: string[]): Promise<void> {
  const parsed = parse(args);
  const action = parsed.positional[0];
  if (!action || action === "help" || parsed.flags.has("help")) {
    process.stdout.write(HELP);
    return;
  }
  const allowed = KNOWN_FLAGS[action];
  if (!allowed) throw new Error(`unknown job action: ${action}. Run celorga job --help`);
  for (const name of parsed.flags.keys()) {
    if (!allowed.includes(name)) throw new Error(`job ${action} does not accept --${name}. Run celorga job --help`);
  }
  if (action !== "start" && parsed.command.length) throw new Error(`job ${action} does not take a -- COMMAND`);
  const corpus = path.resolve(parsed.flags.get("dir") || ".");

  if (action === "_supervise") {
    await superviseBackgroundJob(corpus, required(parsed.positional[1], "job ID is required"));
    return;
  }

  if (action === "start") {
    const result = startBackgroundJob(corpus, {
      command: parsed.command,
      label: parsed.flags.get("label"),
      cwd: parsed.flags.get("cwd"),
      threadID: parsed.flags.get("thread"),
      authorLabel: parsed.flags.get("author"),
      authorAgentRef: parsed.flags.get("agent-ref"),
      apply: parsed.flags.has("apply"),
    });
    const { job } = result;
    const dirFlag = ` --dir ${backgroundJobCommandLine([corpus])}`;
    output(parsed, result, [
      `${result.applied ? "started" : "would start"} job ${job.id}: ${job.label}`,
      `Command: ${result.commandLine}`,
      `Directory: ${job.cwd}`,
      `Log: ${job.logFile}`,
      job.threadID ? `Reports into thread ${job.threadID} as ${job.authorLabel} when it exits.` : "No thread: the outcome is recorded but not posted.",
      result.applied
        ? `Check with celorga job status ${job.id}${dirFlag}; stop with celorga job stop ${job.id}${dirFlag} --apply.`
        : "Re-run with --apply to start it.",
    ].join("\n"));
    return;
  }

  if (action === "list") {
    const result = listBackgroundJobs(corpus, {
      threadID: parsed.flags.get("thread"),
      all: parsed.flags.has("all"),
      limit: count(parsed.flags.get("limit"), "--limit"),
    });
    output(parsed, result, result.jobs.length
      ? result.jobs.map(describe).join("\n")
      : parsed.flags.has("all") ? "No background jobs." : "No running background jobs.");
    return;
  }

  if (action === "status") {
    const status = backgroundJobStatus(
      corpus,
      required(parsed.positional[1], "job ID is required"),
      count(parsed.flags.get("lines"), "--lines"),
    );
    const { job } = status;
    output(parsed, status, [
      describe(job),
      `Command: ${backgroundJobCommandLine(job.command)}`,
      `Log: ${job.logFile}`,
      ...(job.delivery ? [`Thread delivery: ${job.delivery.status}${job.delivery.error ? ` (${job.delivery.error})` : ""}`] : []),
      "--- log tail ---",
      status.logTail || "(no output)",
    ].join("\n"));
    return;
  }

  const id = required(parsed.positional[1], "job ID is required");
  const graceRaw = parsed.flags.get("grace");
  const grace = graceRaw === undefined ? undefined : Number(graceRaw);
  if (grace !== undefined && (!Number.isFinite(grace) || grace < 0)) throw new Error("--grace must be a non-negative number of seconds");
  const result = await stopBackgroundJob(corpus, id, {
    apply: parsed.flags.has("apply"),
    ...(grace !== undefined ? { graceMs: Math.round(grace * 1000) } : {}),
  });
  output(parsed, result, result.applied
    ? `stopped job ${result.job.id} (${result.job.state})`
    : result.changed ? `would stop job ${result.job.id} (${result.job.state}). Re-run with --apply.` : `job ${result.job.id} is not running (${result.job.state})`);
}
