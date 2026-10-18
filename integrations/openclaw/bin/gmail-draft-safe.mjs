#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const recipientPreflightModule = process.env.CELORGA_GMAIL_PREFLIGHT_MODULE
  || resolve(homedir(), ".config/celorga/gmail-recipient-preflight.mjs");
const { validateRecipientSalutation } = await import(pathToFileURL(resolve(recipientPreflightModule)).href);

import {
  header,
  normalizePlainText,
  plainTextToHtml,
  suspiciousHardWraps,
  validateSafeDraft,
} from "../lib/gmail-draft-safety.js";

const SCARF_ACCOUNT = "avi@scarf.sh";
const SCARF_GOG = "/Users/avi/clawd/slack/scripts/gog-scarf-headless";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}

function parse(argv) {
  const operation = argv.shift();
  if (!operation || !["create", "update"].includes(operation)) fail("usage: gmail-draft-safe.mjs create|update [DRAFT_ID] --account EMAIL --to RECIPIENTS --subject SUBJECT --body-file PATH [options]");
  const result = { operation, attach: [] };
  if (operation === "update") result.draftId = argv.shift();
  while (argv.length) {
    const token = argv.shift();
    if (!token.startsWith("--")) fail(`unexpected argument: ${token}`);
    const [rawName, inline] = token.slice(2).split(/=(.*)/s, 2);
    if (["reply-all", "quote", "clear-attachments"].includes(rawName)) { result[rawName] = true; continue; }
    const value = inline ?? argv.shift();
    if (value === undefined) fail(`missing value for --${rawName}`);
    if (rawName === "attach") result.attach.push(value);
    else result[rawName] = value;
  }
  if (operation === "update" && !result.draftId) fail("update requires DRAFT_ID");
  for (const name of ["account", "to", "subject", "body-file"]) if (!result[name]) fail(`--${name} is required`);
  return result;
}

function gogBin(account) {
  return account.toLowerCase() === SCARF_ACCOUNT ? SCARF_GOG : "/usr/local/bin/gog";
}

function gogJson(bin, args) {
  return JSON.parse(execFileSync(bin, [...args, "--json", "--no-input", "--gmail-no-send"], { encoding: "utf8", maxBuffer: 10_000_000 }));
}

function draftPayload(result) {
  return result?.draft?.message?.payload || result?.message?.payload;
}

function latestSurvivingMessage(thread) {
  const messages = thread?.thread?.messages || thread?.messages || [];
  return messages
    .filter((message) => !(message.labelIds || []).includes("DRAFT"))
    .sort((left, right) => Number(right.internalDate || 0) - Number(left.internalDate || 0))[0];
}

function resolveAnchor(bin, args, existing) {
  const explicitMessageId = args["reply-to-message-id"];
  if (explicitMessageId) {
    const message = gogJson(bin, ["gmail", "get", explicitMessageId, "--account", args.account, ...(args.client ? ["--client", args.client] : [])]);
    const live = message?.message || message;
    if ((live?.labelIds || []).includes("DRAFT")) fail("--reply-to-message-id must identify a surviving non-draft message");
    return { gmailId: explicitMessageId, threadId: live?.threadId, rfcMessageId: header(live?.payload, "message-id") };
  }
  const threadId = args["thread-id"] || existing?.draft?.message?.threadId;
  if (!threadId) return null;
  const thread = gogJson(bin, ["gmail", "thread", "get", threadId, "--account", args.account, ...(args.client ? ["--client", args.client] : []), "--full"]);
  const anchor = latestSurvivingMessage(thread);
  if (!anchor) {
    if (args["thread-id"]) fail(`thread ${threadId} has no surviving non-draft message to reply to`);
    return null;
  }
  return { gmailId: anchor.id, threadId, rfcMessageId: header(anchor.payload, "message-id") };
}

export function run(argv = process.argv.slice(2)) {
  const args = parse([...argv]);
  const bin = gogBin(args.account);
  const body = normalizePlainText(args["body-file"] === "-" ? readFileSync(0, "utf8") : readFileSync(args["body-file"], "utf8"));
  if (!body) fail("body file is empty");
  if (args.account.toLowerCase() === SCARF_ACCOUNT) {
    const greetingProblems = validateRecipientSalutation(body, args.to, args["recipient-name"] || "", args["recipient-name-audit"] === "unknown-after-context-audit");
    if (greetingProblems.length) fail(`REFUSING DRAFT:\n- ${greetingProblems.join("\n- ")}`);
  }
  const wrapProblems = suspiciousHardWraps(body);
  if (wrapProblems.length) fail(`REFUSING DRAFT:\n- ${wrapProblems.join("\n- ")}`);
  const html = plainTextToHtml(body);
  const existing = args.operation === "update"
    ? gogJson(bin, ["gmail", "drafts", "get", args.draftId, "--account", args.account, ...(args.client ? ["--client", args.client] : [])])
    : null;
  const anchor = resolveAnchor(bin, args, existing);
  const command = ["gmail", "drafts", args.operation];
  if (args.operation === "update") command.push(args.draftId);
  command.push(
    "--account", args.account,
    "--to", args.to,
    "--subject", args.subject,
    "--body", body,
    "--body-html", html,
    "--from", args.account,
  );
  if (args.client) command.push("--client", args.client);
  for (const name of ["cc", "bcc", "reply-to"]) if (args[name]) command.push(`--${name}`, args[name]);
  if (anchor) command.push("--reply-to-message-id", anchor.gmailId);
  if (args["reply-all"]) command.push("--reply-all");
  if (args.quote) command.push("--quote");
  for (const attachment of args.attach) command.push("--attach", attachment);
  if (args["clear-attachments"]) command.push("--clear-attachments");
  const created = gogJson(bin, command);
  const draftId = created.draftId || created.draft?.id || args.draftId;
  if (!draftId) fail("Gmail did not return a draft ID");
  const readback = gogJson(bin, ["gmail", "drafts", "get", draftId, "--account", args.account, ...(args.client ? ["--client", args.client] : [])]);
  const payload = draftPayload(readback);
  const problems = validateSafeDraft(readback, {
    account: args.account,
    to: args.to,
    subject: args.subject,
    body,
    html,
    threadId: anchor?.threadId,
    anchorMessageId: anchor?.rfcMessageId,
  });
  if (problems.length) fail(`DRAFT CREATED BUT FAILED PROVIDER READBACK (${draftId}):\n- ${problems.join("\n- ")}\nDelete or repair this draft before requesting approval.`);
  process.stdout.write(`${JSON.stringify({
    ...created,
    draftId,
    verified: true,
    mimeType: payload?.mimeType,
    hasPlainTextFallback: true,
    hasHtmlBody: true,
    hardWrapCheck: "passed",
    threadAnchorMessageId: anchor?.gmailId,
  }, null, 2)}\n`);
}

if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) run();
