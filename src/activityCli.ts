import path from "node:path";
import process from "node:process";
import { activityHosts, describeAge, explainActivity, renderActivityExplanationText } from "./activityState.js";
import { renderRunTraceText, traceRun } from "./runTrace.js";
import {
  ACTIVITY_EVENT_TYPES,
  RUN_WAIT_CONDITIONS,
  THREAD_WAIT_CONDITIONS,
  activityEventHistory,
  followActivityEvents,
  waitExitCode,
  waitForRun,
  waitForThread,
  type ActivityEvent,
  type ActivityEventFilter,
  type ActivityWaitResult,
  type RunWaitCondition,
  type ThreadWaitCondition,
} from "./activityEvents.js";

const HELP = `Usage: celorga activity <explain|trace|hosts|events> [options]

  celorga activity explain [--thread ID | --run ID | --workflow ID] [--all] [--dir DIR] [--json]
      Explain why each thread, run, and workflow is working or needs attention:
      the reporting host/runtime, last heartbeat or transition, whether the
      state is live, cached, or uncertain, and the exact blocking approval or
      question. Derived from structured presence, transcript, and run records.

  celorga activity trace --run ID [--dir DIR] [--json]
      Trace one run through dispatch -> executor -> tools -> result -> delivery
      with evidence for each stage. The verdict is queued, running, waiting,
      failed, completed, completed-undelivered, canceled, or unknown, and can
      differ from the run record (for example, a run marked failed whose
      executor is still live). Reports slow tools, shell errors, stale or
      mismatched hosts, uncertain delivery, and whether a retry is safe.

  celorga activity hosts [--dir DIR] [--json]
      List Celorga app hosts sharing this corpus with online/reconnecting/
      authentication-needed/stale/offline state, active turns, last-seen time,
      and failover candidates.

  celorga activity events [--since ISO|DURATION] [--follow] [--type TYPE[,TYPE]]
                       [--thread ID] [--run ID] [--workflow ID] [--limit N]
                       [--interval-ms N] [--dir DIR] [--json]
      Print activity events (NDJSON with --json). Without --follow, replays
      durable events after --since (default: 1h). With --follow, replays and
      then streams new events until interrupted. TYPE accepts prefixes such as
      run.* or approval.*.

Related waits:
  celorga thread wait ID --until reply|needs-you|idle|working [--after MESSAGE_ID] [--since ISO] [--timeout SECONDS]
  celorga run wait ID --until approval|blocked|needs-you|running|completed|failed|terminal|status:STATUS [--timeout SECONDS]
  Waits check durable state first, so events that land before the wait starts
  are not missed. Exit status: 0 matched, 2 unreachable, 124 timed out.

Event types: ${ACTIVITY_EVENT_TYPES.join(", ")}
`;

interface ParsedArgs { positional: string[]; flags: Map<string, string[]>; }

function parseArgs(args: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index]!;
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    const explicit = equal >= 0 ? item.slice(equal + 1) : undefined;
    const value = explicit ?? (args[index + 1] && !args[index + 1]!.startsWith("--") ? args[++index]! : "true");
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags };
}

const flag = (parsed: ParsedArgs, name: string) => parsed.flags.get(name)?.at(-1);
const enabled = (parsed: ParsedArgs, name: string) => parsed.flags.has(name) && flag(parsed, name) !== "false";
const json = (parsed: ParsedArgs) => enabled(parsed, "json") || flag(parsed, "format") === "json";

/** Parses an ISO timestamp or a relative duration such as 90s, 15m, 2h, 7d. */
export function parseSince(raw: string | undefined, now = new Date(), fallbackSeconds = 3600): Date {
  if (!raw) return new Date(now.getTime() - fallbackSeconds * 1000);
  const relative = /^(\d+(?:\.\d+)?)(s|m|h|d)$/u.exec(raw.trim());
  if (relative) {
    const unit = { s: 1, m: 60, h: 3600, d: 86_400 }[relative[2] as "s" | "m" | "h" | "d"];
    return new Date(now.getTime() - Number(relative[1]) * unit * 1000);
  }
  const parsed = new Date(raw);
  if (!Number.isFinite(parsed.getTime())) throw new Error(`--since must be an ISO timestamp or a duration such as 15m: ${raw}`);
  return parsed;
}

function positiveNumber(raw: string | undefined, name: string): number | undefined {
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`--${name} must be a non-negative number`);
  return value;
}

function eventText(event: ActivityEvent): string {
  const title = event.subject.title ? ` ${event.subject.title}` : "";
  return `${event.at}\t${event.type}\t${event.subject.kind}:${event.subject.id}${title}${event.detail ? ` — ${event.detail}` : ""}`;
}

function eventFilter(parsed: ParsedArgs): ActivityEventFilter {
  const types = (parsed.flags.get("type") ?? []).flatMap((value) => value.split(",")).map((value) => value.trim()).filter(Boolean);
  for (const type of types) {
    const known = ACTIVITY_EVENT_TYPES.some((candidate) => candidate === type || (type.endsWith("*") && candidate.startsWith(type.slice(0, -1))));
    if (!known) throw new Error(`unknown event type: ${type}`);
  }
  return {
    ...(types.length ? { types } : {}),
    ...(flag(parsed, "run") ? { runId: flag(parsed, "run") } : {}),
    ...(flag(parsed, "thread") ? { threadId: flag(parsed, "thread") } : {}),
    ...(flag(parsed, "workflow") ? { workflowId: flag(parsed, "workflow") } : {}),
  };
}

export async function runActivityCommand(args: string[]): Promise<void> {
  const parsed = parseArgs(args);
  const action = parsed.positional[0] || "explain";
  if (action === "help" || enabled(parsed, "help")) { process.stdout.write(HELP); return; }
  const corpus = path.resolve(flag(parsed, "dir") ?? ".");
  if (action === "explain") {
    const result = explainActivity(corpus, {
      thread: flag(parsed, "thread"),
      run: flag(parsed, "run"),
      workflow: flag(parsed, "workflow"),
      all: enabled(parsed, "all"),
    });
    process.stdout.write(json(parsed) ? `${JSON.stringify(result, null, 2)}\n` : `${renderActivityExplanationText(result)}\n`);
    return;
  }
  if (action === "trace") {
    const run = flag(parsed, "run") ?? parsed.positional[1];
    if (!run) throw new Error("activity trace requires --run ID");
    const trace = traceRun(corpus, run);
    process.stdout.write(json(parsed) ? `${JSON.stringify(trace, null, 2)}\n` : `${renderRunTraceText(trace)}\n`);
    return;
  }
  if (action === "hosts") {
    const result = activityHosts(corpus);
    if (json(parsed)) { process.stdout.write(`${JSON.stringify(result, null, 2)}\n`); return; }
    if (!result.hosts.length) { process.stdout.write("No host presence records.\n"); return; }
    for (const host of result.hosts) {
      process.stdout.write(`${host.hostName}\t${host.hostKind}\t${host.state}\tlast seen ${describeAge(host.lastSeenAgeSeconds)}\t${host.turns.length} turn(s)${host.confidence === "cached" ? " (cached)" : ""}${host.isAutomationHost ? "\tautomation host" : ""}${host.failoverHostRefs.length ? `\tfailover: ${host.failoverHostRefs.join(", ")}` : ""}\n`);
    }
    return;
  }
  if (action === "events") {
    const filter = eventFilter(parsed);
    const limit = positiveNumber(flag(parsed, "limit"), "limit");
    const write = (event: ActivityEvent) => process.stdout.write(json(parsed) ? `${JSON.stringify(event)}\n` : `${eventText(event)}\n`);
    if (!enabled(parsed, "follow")) {
      const events = activityEventHistory(corpus, { since: parseSince(flag(parsed, "since")), filter });
      for (const event of limit !== undefined ? events.slice(-limit) : events) write(event);
      return;
    }
    const controller = new AbortController();
    const stop = () => controller.abort();
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    try {
      await followActivityEvents(corpus, write, {
        since: flag(parsed, "since") ? parseSince(flag(parsed, "since")) : undefined,
        filter,
        intervalMs: positiveNumber(flag(parsed, "interval-ms"), "interval-ms") ?? 1000,
        signal: controller.signal,
        ...(limit !== undefined ? { limit } : {}),
      });
    } finally {
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
    }
    return;
  }
  throw new Error(`unknown activity action: ${action}\n\n${HELP}`);
}

function waitText(result: ActivityWaitResult): string {
  const head = `${result.outcome}\t${result.subject.kind} ${result.subject.id}\tuntil ${result.until}\t${result.elapsedSeconds}s`;
  const reply = result.reply ? `\nreply ${result.reply.messageId} at ${result.reply.at}${result.reply.author ? ` from ${result.reply.author}` : ""}` : "";
  const explanation = result.explanation ? `\n${result.explanation.state}: ${result.explanation.reason.summary}` : "";
  return `${head}${reply}${explanation}`;
}

function controllerForSignals(): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  return { signal: controller.signal, dispose: () => { process.off("SIGINT", stop); process.off("SIGTERM", stop); } };
}

/** `celorga thread wait ID --until ...` */
export async function runThreadWaitCommand(corpus: string, id: string | undefined, flags: Map<string, string[]>): Promise<void> {
  if (!id) throw new Error("thread id is required");
  const until = flags.get("until")?.at(-1) ?? "reply";
  if (!(THREAD_WAIT_CONDITIONS as readonly string[]).includes(until)) throw new Error(`--until must be one of ${THREAD_WAIT_CONDITIONS.join(", ")}`);
  const parsed: ParsedArgs = { positional: [], flags };
  const signals = controllerForSignals();
  try {
    const result = await waitForThread(corpus, id, until as ThreadWaitCondition, {
      timeoutSeconds: positiveNumber(flag(parsed, "timeout"), "timeout"),
      intervalMs: positiveNumber(flag(parsed, "interval-ms"), "interval-ms"),
      afterMessageId: flag(parsed, "after"),
      since: flag(parsed, "since") ? parseSince(flag(parsed, "since")) : undefined,
      signal: signals.signal,
    });
    process.stdout.write(json(parsed) ? `${JSON.stringify(result, null, 2)}\n` : `${waitText(result)}\n`);
    process.exitCode = waitExitCode(result);
  } finally {
    signals.dispose();
  }
}

/** `celorga run wait ID --until ...` */
export async function runRunWaitCommand(corpus: string, id: string | undefined, flags: Map<string, string[]>): Promise<void> {
  if (!id) throw new Error("run id is required");
  const until = flags.get("until")?.at(-1) ?? "terminal";
  if (!(RUN_WAIT_CONDITIONS as readonly string[]).includes(until) && !/^status:[a-z-]+$/u.test(until)) {
    throw new Error(`--until must be one of ${RUN_WAIT_CONDITIONS.join(", ")}, or status:STATUS`);
  }
  const parsed: ParsedArgs = { positional: [], flags };
  const signals = controllerForSignals();
  try {
    const result = await waitForRun(corpus, id, until as RunWaitCondition, {
      timeoutSeconds: positiveNumber(flag(parsed, "timeout"), "timeout"),
      intervalMs: positiveNumber(flag(parsed, "interval-ms"), "interval-ms"),
      signal: signals.signal,
    });
    process.stdout.write(json(parsed) ? `${JSON.stringify(result, null, 2)}\n` : `${waitText(result)}\n`);
    process.exitCode = waitExitCode(result);
  } finally {
    signals.dispose();
  }
}
