import path from "node:path";
import { spawnSync } from "node:child_process";
import { readStdinText } from "./stdin.js";
import {
  declineSecretRequest,
  decryptSecretValue,
  fulfillSecretRequest,
  listSecrets,
  planSecretFulfillment,
  queueSecretRequest,
  secretRequestStatus,
  validateEnvName,
  validateSecretName,
} from "./secretRequest.js";

const HELP = `celorga secret: request, store, and use credentials without putting them in chat

Usage:
  celorga secret request NAME --reason TEXT (--author LABEL | --agent-ref REF) [--thread THREAD_ID]
                         [--recipient ID]... [--recipient-file FILE]... [--idempotency-key KEY]
                         [--apply] [--wait SECONDS] [--dir CORPUS] [--json]
  celorga secret status REQUEST_ID [--dir CORPUS] [--json]
  celorga secret list [--dir CORPUS] [--json]
  celorga secret exec NAME [--env VAR] [--gpg-program PATH] [--gpg-timeout SECONDS] [--dir CORPUS] -- COMMAND [ARGS...]
  celorga secret fulfill REQUEST_ID --value-stdin [--apply] [--default-recipient-self | --no-default-recipient-self]
                         [--recipient ID]... [--recipient-file FILE]... [--gpg-program PATH] [--dir CORPUS] [--json]
  celorga secret decline REQUEST_ID [--note TEXT] [--apply] [--dir CORPUS] [--json]

request    Preview, or with --apply queue, a request for the Celorga app to ask the person for NAME in a
           secure entry sheet. The app seals the value with GPG into the corpus secrets file
           (celorga.json secrets.file, default secrets.org) as an encrypted :crypt: entry.
           --wait polls until the request is decided: exit 0 fulfilled, 2 declined, 124 timed out.
status     Report pending, fulfilled, or declined. Never reports the value.
list       Show secret names and metadata from the secrets file, plus pending requests. Never values.
exec       Decrypt NAME (gpg-agent may prompt) and run COMMAND with it in environment variable VAR
           (default NAME). The value is never printed.
fulfill    Store a value read from stdin for a pending request (used by the Celorga app).
           The value reaches gpg only through a pipe; only ciphertext is written.
decline    Record that the person declined a pending request.
`;

interface Parsed {
  positional: string[];
  flags: Map<string, string[]>;
  command: string[];
}

const BOOLEAN_FLAGS = new Set(["apply", "json", "value-stdin", "default-recipient-self", "no-default-recipient-self", "help"]);

function parse(args: string[]): Parsed {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  let command: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index]!;
    if (item === "--") { command = args.slice(index + 1); break; }
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
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags, command };
}

function flag(parsed: Parsed, name: string): string | undefined { return parsed.flags.get(name)?.at(-1); }
function flags(parsed: Parsed, name: string): string[] { return parsed.flags.get(name) || []; }
function enabled(parsed: Parsed, name: string): boolean { return parsed.flags.has(name); }
function json(parsed: Parsed): boolean { return enabled(parsed, "json") || flag(parsed, "format") === "json"; }
function root(parsed: Parsed): string { return path.resolve(flag(parsed, "dir") || "."); }
function output(parsed: Parsed, value: unknown, text: string): void {
  process.stdout.write(json(parsed) ? `${JSON.stringify(value, null, 2)}\n` : `${text}\n`);
}
function required(value: string | undefined, message: string): string {
  if (!value) throw new Error(message);
  return value;
}
function seconds(raw: string | undefined, label: string): number | undefined {
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${label} must be a non-negative number of seconds`);
  return value;
}

function gpgOptions(parsed: Parsed) {
  const timeout = seconds(flag(parsed, "gpg-timeout"), "--gpg-timeout");
  return {
    ...(flag(parsed, "gpg-program") ? { gpgProgram: flag(parsed, "gpg-program") } : {}),
    ...(timeout !== undefined ? { timeoutMs: Math.max(100, Math.round(timeout * 1000)) } : {}),
  };
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function runSecretCommand(args: string[]): Promise<void> {
  const parsed = parse(args);
  const action = parsed.positional[0];
  if (!action || action === "help" || enabled(parsed, "help")) {
    process.stdout.write(HELP);
    return;
  }
  const corpus = root(parsed);

  if (action === "request") {
    const name = validateSecretName(required(parsed.positional[1], "secret NAME is required"));
    const apply = enabled(parsed, "apply");
    const wait = seconds(flag(parsed, "wait"), "--wait");
    if (wait !== undefined && !apply) throw new Error("--wait requires --apply");
    const result = queueSecretRequest(corpus, name, {
      reason: required(flag(parsed, "reason"), "--reason is required"),
      authorLabel: flag(parsed, "author"),
      authorAgentRef: flag(parsed, "agent-ref"),
      threadID: flag(parsed, "thread"),
      recipients: flags(parsed, "recipient"),
      recipientFiles: flags(parsed, "recipient-file"),
      idempotencyKey: flag(parsed, "idempotency-key"),
      apply,
    });
    let status: string = result.status;
    if (wait !== undefined && status === "pending") {
      const deadline = Date.now() + wait * 1000;
      while (status === "pending" && Date.now() < deadline) {
        await sleep(Math.min(500, Math.max(0, deadline - Date.now())));
        status = secretRequestStatus(corpus, result.request.id).status;
      }
    }
    const verb = result.status === "preview" ? "would queue" : result.applied ? "queued" : "already queued";
    output(parsed, { ...result, status }, [
      `${verb} secret request ${result.request.id} for ${name} (status: ${status})`,
      `Destination: ${result.request.destination.file}, encrypted with GPG${result.request.recipients.defaultKey ? " to the default key" : ""}${result.request.recipients.entries.length ? ` and ${result.request.recipients.entries.map((entry) => entry.value).join(", ")}` : ""}.`,
      status === "pending"
        ? `Celorga asks the person in a secure sheet. Check with celorga secret status ${result.request.id}; then use celorga secret exec ${name} -- COMMAND.`
        : status === "preview" ? "Re-run with --apply to queue it." : "",
    ].filter(Boolean).join("\n"));
    if (wait !== undefined) {
      if (status === "declined") process.exitCode = 2;
      else if (status === "pending") process.exitCode = 124;
    }
    return;
  }

  if (action === "status") {
    const status = secretRequestStatus(corpus, required(parsed.positional[1], "secret request ID is required"));
    output(parsed, status, `${status.id}\t${status.status}\t${status.name}`);
    return;
  }

  if (action === "list") {
    const listing = listSecrets(corpus);
    const lines = [
      ...listing.secrets.map((entry) => `${entry.name}\t${entry.encrypted ? "encrypted" : "NOT ENCRYPTED"}\t${listing.file}:${entry.line}`),
      ...listing.pendingRequests.map((request) => `${request.name}\tpending request ${request.id}\t${request.requestedBy}`),
    ];
    output(parsed, listing, lines.length ? lines.join("\n") : `No secrets in ${listing.file}.`);
    return;
  }

  if (action === "exec") {
    const name = validateSecretName(required(parsed.positional[1], "secret NAME is required"));
    const envName = validateEnvName(flag(parsed, "env") || name);
    if (parsed.command.length === 0) throw new Error("secret exec requires -- COMMAND [ARGS...]");
    const value = decryptSecretValue(corpus, name, gpgOptions(parsed));
    const child = spawnSync(parsed.command[0]!, parsed.command.slice(1), {
      stdio: "inherit",
      env: { ...process.env, [envName]: value },
    });
    if (child.error) throw new Error(`could not run ${parsed.command[0]}: ${child.error.message}`);
    if (child.signal) {
      process.kill(process.pid, child.signal);
      return;
    }
    process.exitCode = child.status ?? 1;
    return;
  }

  if (action === "fulfill") {
    const id = required(parsed.positional[1], "secret request ID is required");
    const defaultRecipientSelf = enabled(parsed, "no-default-recipient-self")
      ? false
      : enabled(parsed, "default-recipient-self") ? true : undefined;
    const options = {
      ...gpgOptions(parsed),
      ...(defaultRecipientSelf !== undefined ? { defaultRecipientSelf } : {}),
      recipients: flags(parsed, "recipient"),
      recipientFiles: flags(parsed, "recipient-file"),
    };
    if (!enabled(parsed, "apply")) {
      const plan = planSecretFulfillment(corpus, id, options);
      const { resolved: _resolved, ...preview } = plan;
      output(parsed, { applied: false, ...preview }, `would store ${plan.request.name} in ${plan.file} (status: ${plan.status})`);
      return;
    }
    if (!enabled(parsed, "value-stdin")) throw new Error("secret fulfill --apply reads the value only from stdin; pass --value-stdin");
    const value = await readStdinText();
    const result = fulfillSecretRequest(corpus, id, value, options);
    output(parsed, result, `stored ${result.name} encrypted in ${result.file} (${result.headingID})`);
    return;
  }

  if (action === "decline") {
    const result = declineSecretRequest(corpus, required(parsed.positional[1], "secret request ID is required"), {
      note: flag(parsed, "note"),
      apply: enabled(parsed, "apply"),
    });
    output(parsed, result, `${result.applied ? "declined" : result.status === "preview" ? "would decline" : `already ${result.status}`} ${result.id}`);
    return;
  }

  throw new Error(`unknown secret action: ${action}. Run celorga secret --help`);
}
