import { createProjectNote, listProjectNotes, updateProjectNote } from "./project.js";
import { workspaceAgentState, workspaceRunList, workspaceWorkflowList, workspaceGoalList, workspaceProfileList } from "./workspaceAgentState.js";
import { continueWorkspaceOffer, coordinateWorkspace, renderWorkspaceCoordinationText } from "./workspaceCoordinator.js";
import { buildAttentionDigest, renderAttentionDigestText } from "./attentionDigest.js";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { automationHostRef, acquireWorkflowDispatchLock } from "./automationHost.js";
import {
  AGENT_RUN_APPROVAL_DECISIONS,
  AGENT_RUN_ARTIFACT_REVIEW_STATUSES,
  AGENT_RUN_ARTIFACT_ROLES,
  AGENT_RUN_RISK_CLASSES,
  AGENT_RUN_APPROVAL_PRIORITIES,
  AGENT_RUN_STEP_KINDS,
  AGENT_RUN_STEP_STATUSES,
  AGENT_RUN_VALIDATION_STATUSES,
  addAgentRunArtifact,
  addAgentRunComment,
  addAgentRunValidation,
  agentRunApprovalDecisionKeys,
  completeAgentRunExternally,
  createAgentRun,
  decideAgentRunApproval,
  forkAgentRun,
  listAgentRuns,
  listAgentRunSnapshots,
  listAgentRunsWithApprovals,
  loadAgentRun,
  loadAgentRunSnapshot,
  normalizeLegacyAgentRuns,
  reopenExternallyCompletedApprovalRun,
  requestAgentRunApproval,
  renderAgentRunOrg,
  saveAgentRun,
  summarizeAgentRunAttempts,
  supersedeAgentRunApproval,
  transitionAgentRun,
  updateAgentRunAssignment,
  updateAgentRunArtifactReview,
  updateAgentRunOutcome,
  updateAgentRunRuntime,
  updateAgentRunStep,
  validateAgentRun,
  type AgentRun,
  type AgentRunApproval,
  type AgentRunSnapshot,
  type AgentRunStatus,
} from "./agentRun.js";
import { updateArtifactReviewStatusInText } from "./artifactMetadata.js";
import {
  LEGACY_WORKFLOW_SCHEDULE_TRIGGER_IDS,
  WORKFLOW_EVENT_TRIGGER_TYPES,
  WORKFLOW_SCHEDULE_TRIGGER_ID,
  dueWorkflowTriggers,
  deleteWorkflow,
  instantiateWorkflow,
  installBuiltinWorkflow,
  listWorkflows,
  loadWorkflow,
  markWorkflowTriggerAttempt,
  migrateLegacyWorkflows,
  packagedWorkflowManifest,
  packagedCorpusTemplate,
  promptAutomation,
  recordWorkflowSignal,
  saveWorkflow,
  updateWorkflow,
  validateWorkflow,
  workflowTriggerEligibility,
  workflowFromRun,
  workflowExecutionPrompt,
  workflowAttemptHoldsScheduleSlot,
  workflowScheduleOccurrences,
  WORKFLOW_SCHEDULE_WHEN_BLOCKED,
  WORKFLOW_SCHEDULE_WHEN_RUNNING,
  WORKFLOW_PULL_REQUEST_EVENTS,
  WORKFLOW_SIGNAL_TRIGGER_TYPES,
  isSignalTrigger,
  workflowEventTriggerWindows,
  workflowSignalContext,
  workflowSignalsById,
  type WorkflowTrigger,
} from "./agentWorkflow.js";
import { observeTodoStateTransitions, pollGithubPullRequests } from "./workflowEventTriggers.js";
import { artifactRebuildPlan, buildArtifactGraph, loadArtifactDeclarations, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW, saveArtifactGraph } from "./artifactPipeline.js";
import { discoverMcpClient, loadMcpClients, saveMcpClients, serveMcp, writeMcpSnapshot } from "./mcpRuntime.js";
import {
  HANDOFF_RUNTIMES,
  buildDoctorHandoff,
  collectMachineEvidence,
  launchDoctorHandoff,
  parseHandoffRuntime,
  renderDoctorHandoff,
  renderMachineEvidence,
  runtimeForAgentProfile,
  writeDoctorHandoff,
} from "./doctorHandoff.js";
import { loadRuntimePolicy, runtimePolicyPath, saveRuntimePolicy, selectRuntime, validateRuntimePaths } from "./runtimePolicy.js";
import { evaluateRun, loadEvalExpectation, loadWorkflowReplayFixture, replayWorkflowFixture, sanitizeRunFixture, saveEvalResult } from "./workflowEval.js";
import { ORG2_CORPUS_KINDS, corpusIdentityStatus, initializeCorpusIdentity } from "./corpusIdentity.js";
import { federatedAgenda, federatedSearch } from "./federatedWorkspace.js";
import {
  autoSettleOpenClawThreads,
  configureOpenClawRoomAgentTurnLimit,
  configureOpenClawThreadSettlement,
  findOpenClawThread,
  isOpenClawThreadSettled,
  loadOpenClawThreadState,
  openClawDateMilliseconds,
  reopenOpenClawThread,
  settleOpenClawThread,
} from "./openClawThreadState.js";
import { queueAIChatInboxMessage } from "./aiChatInbox.js";
import { runAIChatRepair } from "./aiChatRepairCli.js";
import { auditAgenticWorkspace, renderAgenticDoctorReport } from "./agenticWorkspaceDoctor.js";
import { traceAgentRun } from "./runTrace.js";
import {
  WORK_LEDGER_ACCOUNT_STATES,
  acquireWorkLedgerMutationLock,
  appendWorkLedgerEvent,
  createWorkLedgerAccount,
  listWorkLedgerAccounts,
  loadWorkLedgerAccount,
  renderWorkLedgerAccount,
  saveWorkLedgerAccount,
  summarizeWorkLedgerAccount,
  updateWorkLedgerAccount,
  validateWorkLedgerAccount,
  workLedgerAccountPath,
  type WorkLedgerAccount,
} from "./workLedger.js";
import {
  AGENT_PROFILE_DEFAULT_RUNTIMES,
  AGENT_PROFILE_STATUSES,
  GOAL_STATUSES,
  agentProfilePath,
  createAgentProfile,
  createGoal,
  goalPath,
  loadAgentProfileSnapshot,
  loadGoalSnapshot,
  renderAgentProfileOrg,
  renderGoalOrg,
  resolveAgentProfile,
  saveAgentProfile,
  saveGoal,
  type AgentRuntimeBinding,
  type AgentProfileDefaultRuntime,
} from "./coordination.js";

interface ParsedArgs { positional: string[]; flags: Map<string, string[]>; }
function parseArgs(args: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let i = 0; i < args.length; i += 1) {
    const item = args[i]!;
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    const explicit = equal >= 0 ? item.slice(equal + 1) : undefined;
    if (name === "request-turn" && !(explicit ?? (args[i + 1]?.startsWith("--") ? "" : args[i + 1]))?.trim()) {
      throw new Error("--request-turn requires a shared-room agent destination ID or @mention");
    }
    const value = explicit ?? (args[i + 1] && !args[i + 1]!.startsWith("--") ? args[++i]! : "true");
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags };
}
function flag(parsed: ParsedArgs, name: string, fallback?: string): string | undefined { return parsed.flags.get(name)?.at(-1) ?? fallback; }
function flags(parsed: ParsedArgs, name: string): string[] { return parsed.flags.get(name) || []; }
function enabled(parsed: ParsedArgs, name: string): boolean { return parsed.flags.has(name); }
function root(parsed: ParsedArgs): string { return path.resolve(flag(parsed, "dir", ".")!); }
function output(parsed: ParsedArgs, value: unknown, text?: string): void {
  if (enabled(parsed, "json") || flag(parsed, "format") === "json") process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  else process.stdout.write(`${text ?? (typeof value === "string" ? value : JSON.stringify(value, null, 2))}\n`);
}
function required(value: string | undefined, message: string): string { if (!value) throw new Error(message); return value; }
function choice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] {
  const selected = required(value, `${label} is required`);
  if (!choices.includes(selected)) throw new Error(`invalid ${label}: ${selected}; expected one of: ${choices.join(", ")}`);
  return selected as Choices[number];
}
function optionalChoice<const Choices extends readonly string[]>(value: string | undefined, choices: Choices, label: string): Choices[number] | undefined {
  return value === undefined ? undefined : choice(value, choices, label);
}

function syncLinkedArtifactReviewStatus(corpus: string, artifactPath: string, reviewStatus: string): void {
  const file = path.resolve(corpus, artifactPath);
  const relative = path.relative(corpus, file);
  if (relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return;
  if (![".org", ".org2"].includes(path.extname(file).toLowerCase())) return;
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return;
  const raw = fs.readFileSync(file, "utf8");
  const updated = updateArtifactReviewStatusInText(raw, reviewStatus);
  if (updated !== raw) fs.writeFileSync(file, updated, "utf8");
}

const HELP = `Agentic workspace commands:
  celorga doctor [--dir CORPUS] [--json]
  celorga doctor --machine [--dir CORPUS] [--json]
  celorga doctor --handoff codex|claude|opencode|pi|openclaw [--agent-ref ID] [--apply] [--launch] [--dir CORPUS] [--json]
    Bounded troubleshooting handoff to the selected agent; works without the app. --apply writes views/diagnostics/handoffs/; --launch starts the runtime once in this terminal. Never schedules.
  celorga ledger list LEDGER [--eligible] [--state STATE] [--field KEY=VALUE] [--as-of ISO] [--cooldown-days N] [--json]
  celorga ledger resolve LEDGER --identity KEY [--identity KEY] [--json]
  celorga ledger show LEDGER ACCOUNT [--with-revision] [--json]
  celorga ledger create LEDGER ACCOUNT --title TEXT [--state STATE] [--identity KEY] [--alias NAME] [--field KEY=VALUE] [--context TEXT] [--apply]
  celorga ledger update LEDGER ACCOUNT [--state STATE] [--identity KEY] [--alias NAME] [--field KEY=VALUE] [--context TEXT] [--if-revision SHA256] [--apply]
  celorga ledger event LEDGER ACCOUNT --type TYPE --key IDEMPOTENCY_KEY [--run RUN --approval APPROVAL] [--decision-key KEY] [--external-id ID] [--source REF] [--data KEY=VALUE] [--actor NAME] [--note TEXT] [--if-revision SHA256] [--apply]
  celorga corpus show|validate|init [--dir CORPUS] [--id ID --name NAME --kind personal|shared|project] [--apply]
  celorga workspace agent-state --dir CORPUS --json
  celorga workspace agenda --mount CORPUS [--mount CORPUS ...] [--from DATE --to DATE]
  celorga workspace search QUERY --mount CORPUS [--mount CORPUS ...] [--limit N]
  celorga workspace coordinate [--mount CORPUS ...|--dir CORPUS] [--since DURATION] [--quiet-minutes N] [--json]
    Read-only: what needs you, what is stuck, what is working, and what shipped across mounted corpora and every
    host publishing presence into them, with evidence links and guarded continuation offers. Invents no execution state.
  celorga workspace continue OFFER_ID [--mount CORPUS ...|--dir CORPUS] [--actor NAME] [--apply] [--json]
    Re-derives the offer, refuses it if stale or any guard fails, then delegates to an idempotent thread send or a
    revision-guarded run retry. Preview by default. Queuing does not confirm that a turn started.
  celorga workspace attention [--mount CORPUS ...|--dir CORPUS] [--mode check|brief] [--since DURATION] [--now ISO] [--json]
                              [--mark-delivered [--fingerprint FP ...] [--if-revision SHA256|absent] [--apply]]
    Deterministic digest of what needs you now: pending approvals, blocked runs, artifact reviews, chats awaiting you,
    failed runs, overdue deadlines, and today's deadlines and scheduled items, filtered by celorga.json "attention".
    interrupt is true only for never-delivered fingerprints outside quiet hours (brief mode: any item). Delivery is
    recorded in the corpus state directory only with --mark-delivered --apply (one corpus).
  celorga thread list|show|post|send|wait|settle|reopen|configure|auto-settle|repair [--dir CORPUS] [--apply]
  celorga thread repair [--dir CORPUS] [--apply] [--if-revision SHA256] [--watch --interval SECONDS] [--executable PATH] [--json]
  celorga thread post THREAD --message TEXT --author NAME [--agent-ref ID] [--source REF] [--idempotency-key KEY] [--request-turn AGENT ...] [--dir CORPUS] [--apply]
    Message delivery only unless --request-turn names shared-room agents. Single-agent chats do not support this flag.
    Preview writes nothing; --apply queues delivery for Celorga to consume. Queuing a turn request does not confirm a started turn.
  celorga thread send THREAD --message TEXT [--author NAME] [--idempotency-key KEY] [--dir CORPUS] [--apply]
    Explicit single-agent send through the existing queue. An active turn receives a queued follow-up; this does not steer it.
    Requires a Celorga consumer supporting send-message:v1 with the configured destination available. Queue acceptance does not confirm runtime start.
  celorga thread configure --auto-settle never|SECONDS [--dir CORPUS] [--apply]
  celorga thread configure THREAD --agent-turn-limit N|default [--dir CORPUS] [--apply]
  celorga thread wait THREAD --until reply|needs-you|idle|working [--after MESSAGE_ID] [--since ISO|DURATION] [--timeout SECONDS] [--json]
  celorga project list|show|create|adopt|update [--dir CORPUS] [--json] [--apply]
  celorga project create --title TEXT [--description TEXT] [--color none|NAME|#RRGGBB] [--file PATH] [--id UUID] [--apply]
  celorga project adopt FILE --title TEXT [--color COLOR] [--id ID] [--if-revision SHA256] [--apply]
  celorga project update ID [--thread UUID [--remove]] [--color COLOR] [--if-revision SHA256] [--apply]
  celorga goal list|show|create|update [--dir CORPUS] [--apply]
  celorga goal create ID --title TEXT [--description TEXT] [--status planned|active|achieved|canceled] [--parent-goal-ref ID] [--owner-agent-ref ID] [--measure TEXT]
  celorga agent-profile list|show|create|update|resolve [--dir CORPUS] [--apply]
  celorga agent-profile create ID --name TEXT [--default-runtime openclaw|codex|claude] [--binding RUNTIME:AGENT_ID] [--goal-ref ID] [--primary-goal-ref ID] [--responsibility TEXT] [--capability ID] [--skill ID]
  celorga agent-profile update ID [--default-runtime openclaw|codex|claude|none]
  celorga agent-profile resolve --runtime openclaw|codex --runtime-agent-id ID [--json]
  celorga run create [--title TEXT] --goal TEXT [--goal-ref ID] [--agent-ref ID] [--accept TEXT] [--risk CLASS] [--owner NAME] [--capability ID] [--dir CORPUS]
  celorga run show ID --with-revision --json
  celorga run wait ID --until approval|blocked|needs-you|running|completed|failed|terminal|status:STATUS [--timeout SECONDS] [--json]
  celorga run list|show|wait|validate|start|resume|retry|cancel|complete|complete-external|reopen-external|fail|block|fork|normalize|reconcile-source|artifact-review
  celorga run retry ID [--actor NAME] [--force]
    Refuses when the run trace shows a live or unconfirmed executor, a queued request, or an unrecorded result; --force records why.
  celorga run block ID --reason "Specific clarification needed" [--separate-from-approval]
  celorga run complete ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  celorga run complete-external ID [--summary "Where or how it was completed"] --actor NAME
  celorga run reopen-external ID --summary "Corrected open-run outcome" --actor NAME
  celorga run outcome ID --summary "What happened" [--highlight TEXT] [--next-action TEXT]
  celorga run runtime ID [--provider ID] [--model ID] [--tokens-used N] [--cost-used-usd N] [--elapsed-seconds N]
  celorga run assign ID [--owner NAME] [--assignee NAME] [--agent-ref ID] [--goal-ref ID]
  celorga run comment ID --author NAME --body TEXT
  celorga run step ID STEP --status STATUS
  celorga run artifact ID --path FILE [--role ROLE] [--review-status STATUS]
  celorga run artifact-review ID ARTIFACT --status reviewed|promoted|rejected [--actor NAME]
  celorga run validation ID --name NAME --status passed|failed|warning|skipped
  celorga run approval-request ID --title TEXT --action TEXT [--risk CLASS] [--priority normal|urgent] [--role ROLE]
  celorga run approval-decide ID APPROVAL --decision approved|rejected|revised|canceled --actor NAME [--fingerprint SHA256] [--if-revision SHA256] [--note TEXT] [--receipt TEXT]
  celorga run approval-resolve --decision-key PROVIDER_KEY [--json]
  celorga run approval-reconcile [--apply] [--json]
  celorga review list [--status pending] | celorga review show RUN
  celorga workflow list|show|validate|create|save|run|due|observe|poll|triggers|trigger-set|trigger-remove|signal|gate|activate|pause|draft|schedule|delete|migrate|package|corpus-template|install-builtin
  celorga workflow create ID --title TEXT --prompt TEXT --destination-ref ID [--model ID] [--reasoning-effort LEVEL] [--agent-ref ID] [--schedule EXPR --timezone IANA]
  celorga workflow due [--host-ref HOST] [--now ISO_TIMESTAMP] [--dir CORPUS] [--json]
    Lists due schedule occurrences and todo-state/pull-request triggers whose recorded signals are ready (after any coalesce window).
  celorga workflow trigger-set ID --trigger TRIGGER_ID --type todo-state --state KEYWORD [--state ...] [--tag TAG] [--path GLOB] [--property NAME[=VALUE]] [--coalesce 5m] [--disable]
  celorga workflow trigger-set ID --trigger TRIGGER_ID --type pull-request --repo OWNER/NAME [--pr-event opened|commit|review|comment|merged|closed ...] [--number N] [--author LOGIN] [--coalesce 5m] [--disable]
  celorga workflow trigger-remove ID --trigger TRIGGER_ID
  celorga workflow observe [--changed FILE ...] [--host-ref HOST] [--now ISO] [--apply] [--dir CORPUS] [--json]
    Deterministically compares headings with the last observed snapshot and proposes todo-state signals. The first observation records a baseline. Preview by default.
  celorga workflow poll --source github [--workflow ID] [--host-ref HOST] [--now ISO] [--apply] [--dir CORPUS] [--json]
    Reads pull-request activity through your existing \`gh\` CLI login (no token is stored) and proposes pull-request signals. Preview by default; --apply records signals and advances cursors.
  celorga workflow schedule ID --cron EXPR [--timezone IANA] [--destination-ref ID] [--model ID|--clear-model] [--reasoning-effort LEVEL|--clear-reasoning-effort] [--when-blocked continue|wait] [--when-running continue|wait] | --disable
  celorga workflow delete ID [--apply]
  celorga artifact graph --manifest FILE | celorga artifact rebuild --manifest FILE
  celorga runtime init|show|select|verify-paths
  celorga mcp serve|clients|client-add|discover|snapshot
  celorga eval run RUN --expect FILE | celorga eval replay WORKFLOW --fixture FILE | celorga eval fixture RUN --output FILE

Writes are local, inspectable files under .org2/ or reviewable corpus zones. Consequential actions remain approval-gated.`;

function doctorCommand(parsed: ParsedArgs): void {
  if (parsed.positional.length > 0) throw new Error(`unknown doctor arguments: ${parsed.positional.join(" ")}`);
  const handoffRuntime = flag(parsed, "handoff");
  const agentRef = flag(parsed, "agent-ref");
  if (handoffRuntime !== undefined || agentRef !== undefined) {
    doctorHandoffCommand(parsed, handoffRuntime, agentRef);
    return;
  }
  if (enabled(parsed, "launch") || enabled(parsed, "apply")) throw new Error("--launch and --apply require --handoff RUNTIME or --agent-ref ID");
  if (enabled(parsed, "machine")) {
    const evidence = collectMachineEvidence(root(parsed));
    output(parsed, evidence, renderMachineEvidence(evidence));
    return;
  }
  const report = auditAgenticWorkspace(root(parsed));
  output(parsed, report, renderAgenticDoctorReport(report));
  if (!report.ok) process.exitCode = 1;
}

function doctorHandoffCommand(parsed: ParsedArgs, handoffRuntime: string | undefined, agentRef: string | undefined): void {
  const corpus = root(parsed);
  if (handoffRuntime === "true") throw new Error(`--handoff requires a runtime: ${HANDOFF_RUNTIMES.join(", ")}`);
  const runtime = handoffRuntime !== undefined
    ? parseHandoffRuntime(handoffRuntime)
    : runtimeForAgentProfile(corpus, required(agentRef, "--agent-ref is required"));
  let handoff = buildDoctorHandoff({ corpusRoot: corpus, runtime, ...(agentRef ? { agentRef } : {}), playbookId: flag(parsed, "playbook") });
  const applied = enabled(parsed, "apply");
  const launching = enabled(parsed, "launch");
  if (applied) handoff = writeDoctorHandoff(corpus, handoff);
  if (launching) {
    if (!handoff.launch || !handoff.runtime.found) throw new Error(handoff.unavailableReason ?? "launch unavailable");
    process.stderr.write(`${renderDoctorHandoff(handoff, { applied, launching })}\n\nStarting ${handoff.runtime.name} once in this terminal…\n`);
    process.exitCode = launchDoctorHandoff(handoff);
    return;
  }
  output(parsed, { applied, launched: false, handoff }, renderDoctorHandoff(handoff, { applied, launching }));
}

function keyValueFlags(parsed: ParsedArgs, name: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const raw of flags(parsed, name)) {
    const equal = raw.indexOf("=");
    if (equal <= 0) throw new Error(`--${name} must be KEY=VALUE`);
    const key = raw.slice(0, equal).trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9._-]*$/.test(key)) throw new Error(`--${name} key is invalid: ${key}`);
    result[key] = raw.slice(equal + 1);
  }
  return result;
}

function uniqueLowercase(values: readonly string[]): string[] {
  return [...new Set(values.map((value) => String(value || "").trim().toLowerCase()).filter(Boolean))];
}

function normalizedLedgerIdentityName(raw: string): string {
  return raw.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

function ledgerIdentityQueryKeys(values: readonly string[]): string[] {
  const keys: string[] = [];
  for (const original of values) {
    const raw = String(original || "").trim().toLowerCase();
    if (!raw) continue;
    keys.push(raw);
    const colon = raw.indexOf(":");
    if (colon >= 0) {
      const prefix = raw.slice(0, colon);
      const value = raw.slice(colon + 1).trim();
      if (prefix === "name") keys.push(`name:${normalizedLedgerIdentityName(value)}`);
      continue;
    }
    const normalizedName = normalizedLedgerIdentityName(raw);
    if (normalizedName) keys.push(`name:${normalizedName}`);
    if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(raw)) {
      keys.push(`email:${raw}`);
      keys.push(`domain:${raw.split("@")[1]}`);
    } else if (/^[a-z0-9.-]+\.[a-z]{2,}$/.test(raw)) {
      keys.push(`domain:${raw}`);
    } else if (/^\d+$/.test(raw)) {
      keys.push(`scarf-org:${raw}`);
    }
  }
  return uniqueLowercase(keys);
}

function assertLedgerIdentityUnique(
  account: WorkLedgerAccount,
  existing: ReturnType<typeof listWorkLedgerAccounts>,
): void {
  const claimed = new Set(account.identityKeys);
  for (const snapshot of existing) {
    if (snapshot.account.id === account.id) continue;
    const collision = snapshot.account.identityKeys.find((key) => claimed.has(key));
    if (collision) throw new Error(`identity key ${collision} is already claimed by ${snapshot.account.id}`);
  }
}

function linkedPendingApprovalCount(account: WorkLedgerAccount, runs: Map<string, AgentRun>): number {
  const identities = new Set<string>();
  for (const event of account.events) {
    if (!event.runId || !event.approvalId) continue;
    const approval = runs.get(event.runId)?.approvals.find((candidate) => candidate.id === event.approvalId);
    if (approval?.status === "pending") identities.add(`${event.runId}:${event.approvalId}`);
  }
  return identities.size;
}

function ledgerCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  const ledger = required(parsed.positional[1], "ledger id is required");

  if (action === "list") {
    const existing = listWorkLedgerAccounts(corpus, ledger);
    const referencedRunIds = new Set(existing.flatMap((snapshot) => snapshot.account.events.map((event) => event.runId).filter((id): id is string => Boolean(id))));
    const runsById = new Map<string, AgentRun>();
    for (const runId of referencedRunIds) {
      try { runsById.set(runId, loadAgentRun(corpus, runId)); } catch {}
    }
    const state = optionalChoice(flag(parsed, "state"), WORK_LEDGER_ACCOUNT_STATES, "account state");
    const fields = keyValueFlags(parsed, "field");
    const summaries = existing
      .map((snapshot) => summarizeWorkLedgerAccount(snapshot, {
        asOf: flag(parsed, "as-of"),
        cooldownDays: Number(flag(parsed, "cooldown-days", "90")),
        openApprovalCount: linkedPendingApprovalCount(snapshot.account, runsById),
      }))
      .filter((summary) => !state || summary.state === state)
      .filter((summary) => Object.entries(fields).every(([key, value]) => summary.fields[key] === value))
      .filter((summary) => !enabled(parsed, "eligible") || summary.eligible);
    output(
      parsed,
      { schema: "org2:work-ledger-list:v1", ledger, accounts: summaries },
      summaries.length
        ? summaries.map((summary) => `${summary.id}\t${summary.state}\t${summary.eligible ? "eligible" : summary.eligibilityReason}\t${summary.title}`).join("\n")
        : "No ledger accounts matched.",
    );
    return;
  }

  if (action === "resolve") {
    const identities = ledgerIdentityQueryKeys(flags(parsed, "identity"));
    if (!identities.length) throw new Error("ledger resolve requires at least one --identity KEY");
    const matches = listWorkLedgerAccounts(corpus, ledger)
      .filter((snapshot) => identities.some((identity) => snapshot.account.identityKeys.includes(identity)))
      .map((snapshot) => ({
        matchedIdentities: identities.filter((identity) => snapshot.account.identityKeys.includes(identity)),
        account: summarizeWorkLedgerAccount(snapshot, { cooldownDays: Number(flag(parsed, "cooldown-days", "36500")) }),
      }));
    const result = { schema: "org2:work-ledger-resolution:v1", ledger, identities, found: matches.length > 0, ambiguous: matches.length > 1, matches };
    output(parsed, result, matches.length ? matches.map((match) => `${match.account.id}\t${match.matchedIdentities.join(",")}\t${match.account.title}`).join("\n") : "No ledger account matched.");
    if (matches.length > 1) process.exitCode = 1;
    return;
  }

  const id = required(parsed.positional[2], `account id is required for ledger ${action}`);
  if (action === "show") {
    const snapshot = loadWorkLedgerAccount(corpus, ledger, id);
    output(
      parsed,
      enabled(parsed, "with-revision") ? {
        schema: "org2:work-ledger-snapshot:v1",
        revision: snapshot.revision,
        sourceIssues: snapshot.sourceIssues,
        account: snapshot.account,
      } : snapshot.account,
      snapshot.raw,
    );
    return;
  }

  if (!["create", "update", "event"].includes(action)) throw new Error(`unknown ledger action: ${action}`);
  const releaseLedgerLock = enabled(parsed, "apply")
    ? acquireWorkLedgerMutationLock(corpus, ledger)
    : () => {};
  try {

  if (action === "create") {
    const existing = listWorkLedgerAccounts(corpus, ledger);
    const account = createWorkLedgerAccount({
      ledger,
      id,
      title: required(flag(parsed, "title"), "--title is required"),
      state: optionalChoice(flag(parsed, "state"), WORK_LEDGER_ACCOUNT_STATES, "account state"),
      aliases: flags(parsed, "alias"),
      identityKeys: flags(parsed, "identity"),
      fields: keyValueFlags(parsed, "field"),
      context: flag(parsed, "context"),
      now: flag(parsed, "at"),
    });
    assertLedgerIdentityUnique(account, existing);
    const file = workLedgerAccountPath(corpus, ledger, id);
    if (fs.existsSync(file)) throw new Error(`work-ledger account already exists: ${id}`);
    const applied = enabled(parsed, "apply");
    const saved = applied ? saveWorkLedgerAccount(corpus, account, { expectedRevision: null }) : undefined;
    output(
      parsed,
      { schema: "org2:work-ledger-change:v1", applied, changed: true, file, account, ...(saved ? { revision: saved.revision } : {}), preview: renderWorkLedgerAccount(account) },
      `${applied ? "created" : "would create"} ${ledger}/${id}\n${file}`,
    );
    return;
  }

  const snapshot = loadWorkLedgerAccount(corpus, ledger, id);
  const existing = listWorkLedgerAccounts(corpus, ledger);
  const expected = flag(parsed, "if-revision");
  if (expected && expected !== snapshot.revision) throw new Error(`account revision changed; expected ${expected}, found ${snapshot.revision}: ${snapshot.file}`);

  if (action === "update") {
    const account = updateWorkLedgerAccount(snapshot.account, {
      title: flag(parsed, "title"),
      state: optionalChoice(flag(parsed, "state"), WORK_LEDGER_ACCOUNT_STATES, "account state"),
      aliases: flags(parsed, "alias").length ? [...snapshot.account.aliases, ...flags(parsed, "alias")] : undefined,
      identityKeys: flags(parsed, "identity").length ? [...snapshot.account.identityKeys, ...flags(parsed, "identity")] : undefined,
      fields: parsed.flags.has("field") ? keyValueFlags(parsed, "field") : undefined,
      context: flag(parsed, "context"),
      now: flag(parsed, "at"),
    });
    assertLedgerIdentityUnique(account, existing);
    const validation = validateWorkLedgerAccount(account);
    if (!validation.valid) throw new Error(validation.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n"));
    const applied = enabled(parsed, "apply");
    const saved = applied ? saveWorkLedgerAccount(corpus, account, { expectedRevision: snapshot.revision, rejectSourceDrift: true }) : undefined;
    output(
      parsed,
      { schema: "org2:work-ledger-change:v1", applied, changed: true, file: snapshot.file, account, ...(saved ? { revision: saved.revision } : {}), preview: renderWorkLedgerAccount(account) },
      `${applied ? "updated" : "would update"} ${ledger}/${id}`,
    );
    return;
  }

  if (action === "event") {
    const runId = flag(parsed, "run");
    const approvalId = flag(parsed, "approval");
    if (Boolean(runId) !== Boolean(approvalId)) throw new Error("--run and --approval must be supplied together");
    if (runId && approvalId) {
      let run: AgentRun;
      try { run = loadAgentRun(corpus, runId); } catch { throw new Error(`linked run not found: ${runId}`); }
      const approval = run.approvals.find((candidate) => candidate.id === approvalId);
      if (!approval) throw new Error(`linked approval not found: ${runId}:${approvalId}`);
      const decisionKey = flag(parsed, "decision-key")?.toLowerCase();
      if (decisionKey) {
        const normalized = decisionKey.startsWith("artifact:") ? decisionKey : `artifact:${decisionKey}`;
        if (!agentRunApprovalDecisionKeys(approval).includes(normalized)) throw new Error(`decision key does not belong to ${runId}:${approvalId}`);
      }
      if (flag(parsed, "type")?.toLowerCase() === "outreach-sent" && approval.status !== "approved") {
        throw new Error(`outreach-sent requires an approved linked decision; ${runId}:${approvalId} is ${approval.status}`);
      }
    }
    const idempotencyKey = required(flag(parsed, "key"), "--key is required").toLowerCase();
    for (const candidate of existing) {
      if (candidate.account.id === id) continue;
      if (candidate.account.events.some((event) => event.idempotencyKey === idempotencyKey)) {
        throw new Error(`event idempotency key is already recorded on ${candidate.account.id}: ${idempotencyKey}`);
      }
    }
    const result = appendWorkLedgerEvent(snapshot.account, {
      id: flag(parsed, "event-id"),
      idempotencyKey,
      type: required(flag(parsed, "type"), "--type is required"),
      at: flag(parsed, "at"),
      actor: flag(parsed, "actor"),
      note: flag(parsed, "note"),
      runId,
      approvalId,
      decisionKey: flag(parsed, "decision-key"),
      externalId: flag(parsed, "external-id"),
      sourceRefs: flags(parsed, "source"),
      data: keyValueFlags(parsed, "data"),
    });
    const applied = enabled(parsed, "apply");
    const saved = applied && result.changed
      ? saveWorkLedgerAccount(corpus, result.account, { expectedRevision: snapshot.revision, rejectSourceDrift: true })
      : undefined;
    output(
      parsed,
      { schema: "org2:work-ledger-event-result:v1", applied, changed: result.changed, file: snapshot.file, event: result.event, account: result.account, ...(saved ? { revision: saved.revision } : {}), preview: renderWorkLedgerAccount(result.account) },
      `${result.changed ? (applied ? "recorded" : "would record") : "already recorded"} ${result.event.type} for ${ledger}/${id}`,
    );
    return;
  }
  } finally {
    releaseLedgerLock();
  }
}

function durationSeconds(raw: string): number {
  const match = /^(\d+)([smhdw])$/u.exec(raw.trim());
  if (!match) throw new Error(`invalid duration ${raw}; use forms like 90m, 24h, or 7d`);
  const unit = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 }[match[2] as "s" | "m" | "h" | "d" | "w"];
  return Number(match[1]) * unit;
}

function forwardedArgs(parsed: ParsedArgs, excluded: Set<string>): string[] {
  const result: string[] = [];
  for (const [name, values] of parsed.flags) {
    if (excluded.has(name)) continue;
    for (const value of values) {
      result.push(`--${name}`);
      if (value !== "true") result.push(value);
    }
  }
  return result;
}

async function workspaceCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "agenda";
  if (action === "agent-state") {
    if (flags(parsed, "mount").length) throw new Error("workspace agent-state reads one --dir corpus; --mount is not supported");
    output(parsed, workspaceAgentState(root(parsed)));
    return;
  }
  if (action === "attention") {
    const mountRoots = flags(parsed, "mount");
    if (mountRoots.length && parsed.flags.has("dir")) throw new Error("workspace attention reads either --mount CORPUS ... or one --dir CORPUS, not both");
    const rawNow = flag(parsed, "now");
    const now = rawNow ? new Date(rawNow) : new Date();
    if (!Number.isFinite(now.getTime())) throw new Error("--now must be an ISO date");
    const rawSince = flag(parsed, "since");
    const result = await buildAttentionDigest({
      mounts: mountRoots,
      root: root(parsed),
      now,
      ...(rawSince !== undefined ? { sinceSeconds: durationSeconds(rawSince) } : {}),
      mode: choice(flag(parsed, "mode", "check"), ["check", "brief"] as const, "attention mode"),
      markDelivered: enabled(parsed, "mark-delivered"),
      fingerprints: flags(parsed, "fingerprint"),
      apply: enabled(parsed, "apply"),
      ifRevision: flag(parsed, "if-revision"),
    });
    output(parsed, result, renderAttentionDigestText(result));
    return;
  }
  if (action === "coordinate" || action === "continue") {
    const mountRoots = flags(parsed, "mount");
    if (mountRoots.length && parsed.flags.has("dir")) throw new Error(`workspace ${action} reads either --mount CORPUS ... or one --dir CORPUS, not both`);
    const shippedWindowSeconds = durationSeconds(flag(parsed, "since", "24h")!);
    const rawQuiet = flag(parsed, "quiet-minutes");
    if (rawQuiet !== undefined && !/^\d+$/u.test(rawQuiet)) throw new Error("--quiet-minutes must be a non-negative integer");
    const options = {
      mounts: mountRoots,
      root: root(parsed),
      shippedWindowSeconds,
      ...(rawQuiet !== undefined ? { quietSeconds: Number(rawQuiet) * 60 } : {}),
    };
    if (action === "coordinate") {
      const result = coordinateWorkspace(options);
      output(parsed, result, renderWorkspaceCoordinationText(result));
      return;
    }
    const offerId = required(parsed.positional[1], "continuation offer id is required; run celorga workspace coordinate first");
    const result = continueWorkspaceOffer(offerId, { ...options, apply: enabled(parsed, "apply"), actor: flag(parsed, "actor") });
    const verb = result.offer.kind === "thread-send"
      ? `${result.applied ? "queued" : result.delivery?.status === "preview" ? "would queue" : `already ${result.delivery?.status}`} continuation for run ${result.offer.runId} to thread ${result.offer.threadId} via ${result.offer.route?.hostName ?? "?"}`
      : `${result.applied ? "requeued" : "would requeue"} run ${result.offer.runId}`;
    output(parsed, result, `${verb}\n${result.unconfirmed}\nCheck: ${result.verify}`);
    return;
  }
  const mounts = flags(parsed, "mount");
  if (mounts.length === 0) throw new Error("workspace reads require at least one --mount CORPUS");
  const args = forwardedArgs(parsed, new Set(["mount", "dir", "json", "format"]));
  if (action === "agenda") {
    output(parsed, await federatedAgenda({ mounts, forwardedArgs: args }));
    return;
  }
  if (action === "search") {
    const query = required(parsed.positional[1], "search query is required");
    const rawLimit = flag(parsed, "limit", "50")!;
    if (!/^\d+$/.test(rawLimit) || Number(rawLimit) < 1) throw new Error("--limit must be a positive integer");
    output(parsed, await federatedSearch(query, { mounts, forwardedArgs: args, limit: Number(rawLimit) }));
    return;
  }
  throw new Error(`unknown workspace action: ${action}`);
}

function corpusCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show";
  const corpus = root(parsed);
  if (action === "show" || action === "validate") {
    const status = corpusIdentityStatus(corpus);
    output(parsed, status, status.valid
      ? `${status.identity!.name}\n${status.identity!.id}\t${status.identity!.kind}\n${status.root}`
      : status.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n"));
    if (action === "validate" && !status.valid) process.exitCode = 1;
    return;
  }
  if (action === "init") {
    const result = initializeCorpusIdentity(corpus, {
      id: required(flag(parsed, "id"), "--id is required"),
      name: required(flag(parsed, "name"), "--name is required"),
      kind: choice(flag(parsed, "kind", "personal"), ORG2_CORPUS_KINDS, "corpus kind"),
    }, { apply: enabled(parsed, "apply"), force: enabled(parsed, "force") });
    output(parsed, result, `${result.applied ? "initialized" : "would initialize"} ${result.status.identity!.id}\n${result.status.configFile}`);
    return;
  }
  throw new Error(`unknown corpus action: ${action}`);
}

async function threadCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  if (action === "repair") {
    await runAIChatRepair({ corpusRoot: corpus, apply: enabled(parsed, "apply"),
      watch: enabled(parsed, "watch"), interval: flag(parsed, "interval"),
      expectedRevision: flag(parsed, "if-revision"), executable: flag(parsed, "executable") });
    return;
  }
  if (action === "wait") {
    const { runThreadWaitCommand } = await import("./activityCli.js");
    await runThreadWaitCommand(corpus, parsed.positional[1], parsed.flags);
    return;
  }
  if (action === "list") {
    const state = loadOpenClawThreadState(corpus);
    const filter = flag(parsed, "state", "all");
    if (!["all", "active", "settled"].includes(filter!)) {
      throw new Error("--state must be all, active, or settled");
    }
    const threads = state.threads
      .filter((thread) => filter === "all" || (filter === "settled") === isOpenClawThreadSettled(thread))
      .sort((left, right) => {
        const settledOrder = Number(isOpenClawThreadSettled(left)) - Number(isOpenClawThreadSettled(right));
        if (settledOrder !== 0) return settledOrder;
        const leftTime = openClawDateMilliseconds(left.updatedAt);
        const rightTime = openClawDateMilliseconds(right.updatedAt);
        if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) {
          return rightTime - leftTime;
        }
        return String(left.title || left.id).localeCompare(String(right.title || right.id));
      });
    output(parsed, { ...state, threads }, threads.length
      ? threads.map((thread) => `${thread.id}\t${isOpenClawThreadSettled(thread) ? "settled" : "active"}\t${thread.title || "Untitled"}`).join("\n")
      : "No chat threads.");
    return;
  }
  if (action === "show") {
    const id = required(parsed.positional[1], "thread id is required");
    const state = loadOpenClawThreadState(corpus, { hydrateThreadID: id });
    const thread = findOpenClawThread(state, id);
    if (!thread) throw new Error(`unknown OpenClaw thread: ${id}`);
    output(parsed, {
      schema: "org2:openclaw-thread:v1",
      state: isOpenClawThreadSettled(thread) ? "settled" : "active",
      thread,
      settlementSettings: state.settlementSettings,
    }, `${id}\t${isOpenClawThreadSettled(thread) ? "settled" : "active"}\t${thread.title || "Untitled"}`);
    return;
  }
  const apply = enabled(parsed, "apply");
  if (action === "post" || action === "send") {
    const id = required(parsed.positional[1], "thread id is required");
    const result = queueAIChatInboxMessage(
      corpus,
      id,
      required(flag(parsed, "message"), "--message is required"),
      {
        send: action === "send",
        authorLabel: flag(parsed, "author"),
        authorAgentRef: flag(parsed, "agent-ref"),
        source: flag(parsed, "source"),
        idempotencyKey: flag(parsed, "idempotency-key"),
        requestedResponders: flags(parsed, "request-turn"),
        apply,
      },
    );
    const responders = result.message.requestedResponders?.map((token) => `@${token}`).join(", ");
    const delivery = result.deliveryStatus === "delivered" ? "already delivered"
      : result.applied ? "queued" : result.changed ? "would queue" : "already queued";
    output(
      parsed,
      result,
      `${delivery} ${action === "send" ? "single-agent send request" : "message"} for ${id}\n${action === "send"
        ? `Turn start unconfirmed. Celorga must consume the request with destination ${result.message.destinationID} available.\nUse celorga thread wait ${id} --after ${result.message.id} --until reply --dir CORPUS --timeout 60 to check for a reply.`
        : responders
        ? `Turn request for ${responders}; turn start unconfirmed. Celorga resolves requests when it consumes the inbox; room limits and agent availability apply.\nUse celorga thread wait ${id} --after ${result.message.id} --until reply --dir CORPUS --timeout 60 to check for a reply.`
        : "No agent turn requested; message delivery only."}\n${result.file}`,
    );
    return;
  }
  if (action === "settle") {
    const id = required(parsed.positional[1], "thread id is required");
    const result = settleOpenClawThread(corpus, id, { apply });
    output(parsed, result, `${result.queued ? "queued settlement for" : result.changed ? "would queue settlement for" : "already settled"} ${id}`);
    return;
  }
  if (action === "reopen") {
    const id = required(parsed.positional[1], "thread id is required");
    const result = reopenOpenClawThread(corpus, id, { apply });
    output(parsed, result, `${result.queued ? "queued reopening for" : result.changed ? "would queue reopening for" : "already active"} ${id}`);
    return;
  }
  if (action === "configure" && enabled(parsed, "agent-turn-limit")) {
    if (enabled(parsed, "auto-settle")) throw new Error("configure --auto-settle and --agent-turn-limit separately");
    const id = required(parsed.positional[1], "thread id is required for --agent-turn-limit");
    const raw = required(flag(parsed, "agent-turn-limit"), "--agent-turn-limit needs a number or default").trim();
    const limit = raw === "default" ? null : /^\d+$/u.test(raw) ? Number(raw) : Number.NaN;
    if (limit !== null && !Number.isInteger(limit)) {
      throw new Error("--agent-turn-limit must be a whole number (0 turns hand-offs off) or default");
    }
    const result = configureOpenClawRoomAgentTurnLimit(corpus, id, limit, { apply });
    output(parsed, result, `${result.queued ? "queued" : result.changed ? "would queue" : "unchanged"} agent turn limit ${limit ?? "default"} for ${id}`);
    return;
  }
  if (action === "configure") {
    const raw = required(flag(parsed, "auto-settle"), "--auto-settle is required");
    const seconds = raw === "never" || raw === "disabled" ? null : Number(raw);
    if (seconds !== null && (!Number.isFinite(seconds) || seconds <= 0)) {
      throw new Error("--auto-settle must be never or a positive number of seconds");
    }
    const result = configureOpenClawThreadSettlement(corpus, seconds, { apply });
    output(parsed, result, `${result.queued ? "queued" : result.changed ? "would queue" : "unchanged"} auto-settle ${seconds ?? "never"}`);
    return;
  }
  if (action === "auto-settle") {
    const rawNow = flag(parsed, "now");
    const now = rawNow ? new Date(rawNow) : new Date();
    if (!Number.isFinite(now.getTime())) throw new Error("--now must be an ISO date");
    const result = autoSettleOpenClawThreads(corpus, { apply, now });
    output(parsed, result, `${result.queued ? "queued auto-settlement for" : "eligible"} ${result.affectedThreadIds.length} thread(s)`);
    return;
  }
  throw new Error(`unknown thread action: ${action}`);
}

type AgentRunApprovalReference = {
  run: AgentRun;
  approval: AgentRunApproval;
};

function assertRequestedRunRevision(parsed: ParsedArgs, snapshot: AgentRunSnapshot): void {
  const expected = flag(parsed, "if-revision");
  if (expected && expected !== snapshot.revision) {
    throw new Error(`run revision changed; expected ${expected}, found ${snapshot.revision}: ${snapshot.file}`);
  }
  if (snapshot.sourceIssues.length > 0) {
    throw new Error(
      `run source has out-of-band readable-state changes (${snapshot.sourceIssues.map((issue) => issue.field).join(", ")}); run celorga doctor and reconcile the source before writing: ${snapshot.file}`,
    );
  }
}

function runSnapshotMap(corpus: string, preferred?: AgentRunSnapshot): Map<string, AgentRunSnapshot> {
  const snapshots = new Map(listAgentRunSnapshots(corpus).map((snapshot) => [snapshot.run.id, snapshot]));
  if (preferred) snapshots.set(preferred.run.id, preferred);
  return snapshots;
}

/**
 * Loads only the runs whose approvals share a provider decision key.
 *
 * Correlating a single approval decision or request used to reread and hash
 * every durable run record, which took tens of seconds on a large run history
 * and left the desktop Request Changes / Approve actions spinning. The
 * machine-local approval index already fingerprints every run file and
 * retains parsed runs that carry approvals, so it can pick the few candidates
 * cheaply. Candidates are then reread as guarded snapshots, so any write still
 * fails closed if a record changed underneath us.
 */
function correlatedRunSnapshotMap(
  corpus: string,
  keys: string[],
  preferred: AgentRunSnapshot,
): Map<string, AgentRunSnapshot> {
  const snapshots = new Map<string, AgentRunSnapshot>();
  for (const run of listAgentRunsWithApprovals(corpus)) {
    if (run.id === preferred.run.id) continue;
    const overlaps = run.approvals.some((approval) =>
      approvalKeysOverlap(agentRunApprovalDecisionKeys(approval), keys));
    if (!overlaps) continue;
    try {
      snapshots.set(run.id, loadAgentRunSnapshot(corpus, run.id));
    } catch {
      // A run removed since the index was read cannot carry a competing decision.
    }
  }
  snapshots.set(preferred.run.id, preferred);
  return snapshots;
}

function saveRunFromSnapshot(
  corpus: string,
  run: AgentRun,
  snapshots: Map<string, AgentRunSnapshot>,
): string {
  const snapshot = snapshots.get(run.id);
  const file = saveAgentRun(corpus, run, {
    expectedRevision: snapshot?.revision ?? null,
    rejectSourceDrift: true,
  });
  snapshots.delete(run.id);
  return file;
}

function approvalKeysOverlap(lhs: string[], rhs: string[]): boolean {
  const right = new Set(rhs);
  return lhs.some((key) => right.has(key));
}

function approvalMaterialVersion(approval: Pick<AgentRunApproval, "action" | "riskClass">): string {
  const reviewMaterial = String(approval.action || "").replace(/\r\n?/g, "\n").trim();
  const contentFingerprint = reviewMaterial.match(/^\s*Content fingerprint:\s*(\S+)\s*$/im)?.[1];
  return contentFingerprint
    ? `${approval.riskClass}:content:${contentFingerprint.toLowerCase()}`
    : `${approval.riskClass}:action:${reviewMaterial}`;
}

function compareApprovalReferences(lhs: AgentRunApprovalReference, rhs: AgentRunApprovalReference): number {
  return lhs.approval.requestedAt.localeCompare(rhs.approval.requestedAt)
    || lhs.run.id.localeCompare(rhs.run.id)
    || lhs.approval.id.localeCompare(rhs.approval.id);
}

function approvalReferences(runs: AgentRun[], keys: string[]): AgentRunApprovalReference[] {
  if (keys.length === 0) return [];
  return runs.flatMap((run) => run.approvals
    .filter((approval) => approvalKeysOverlap(agentRunApprovalDecisionKeys(approval), keys))
    .map((approval) => ({ run, approval })));
}

function isOpenClawExternalDraftRun(run: AgentRun): boolean {
  return run.comments.some((comment) =>
    /(?:^|\n)OPENCLAW_KIND:\s*external-draft\s*(?:\n|$)/i.test(comment.body));
}

function canCloseSupersededApprovalProjection(run: AgentRun, keys: string[]): boolean {
  if (["completed", "failed", "canceled"].includes(run.status)) return false;
  if (isOpenClawExternalDraftRun(run)) return true;
  if (run.plan.length > 0 || run.artifacts.length > 0 || run.approvals.length === 0) return false;
  return run.approvals.every((approval) => {
    const approvalKeys = agentRunApprovalDecisionKeys(approval);
    return approvalKeys.length > 0 && approvalKeysOverlap(approvalKeys, keys);
  });
}

function closeSupersededApprovalProjection(
  run: AgentRun,
  keys: string[],
  replacementRunId: string,
  replacementApprovalId: string,
  actor?: string,
): AgentRun {
  if (!canCloseSupersededApprovalProjection(run, keys)) return run;
  return transitionAgentRun(run, "canceled", {
    actor: actor || "org2-approval-reconciler",
    reason: `Superseded by approval ${replacementApprovalId} on run ${replacementRunId}.`,
  });
}

function correlatedApprovalRequest(
  parsed: ParsedArgs,
  corpus: string,
  targetSnapshot: AgentRunSnapshot,
): AgentRun | null {
  const target = targetSnapshot.run;
  const input = {
    title: required(flag(parsed, "title"), "--title is required"),
    action: required(flag(parsed, "action"), "--action is required"),
    riskClass: choice(flag(parsed, "risk", target.riskClass), AGENT_RUN_RISK_CLASSES, "approval risk class"),
    requestedRole: flag(parsed, "role"),
    requestedFrom: flag(parsed, "from"),
    note: flag(parsed, "note"),
  };
  const keys = agentRunApprovalDecisionKeys(input);
  if (keys.length === 0) return null;

  const snapshots = correlatedRunSnapshotMap(corpus, keys, targetSnapshot);
  const runs = [...snapshots.values()].map((snapshot) => snapshot.run);
  const references = approvalReferences(runs, keys);
  const targetOwnsDecision = target.approvals.some((approval) =>
    approvalKeysOverlap(agentRunApprovalDecisionKeys(approval), keys));
  const targetIsDraftProjection = isOpenClawExternalDraftRun(target);
  const exactPending = references
    .filter((reference) =>
      reference.approval.status === "pending"
      && approvalMaterialVersion(reference.approval) === approvalMaterialVersion(input))
    .sort(compareApprovalReferences)
    .at(-1);

  if (exactPending && (
    exactPending.run.id === target.id
    || targetIsDraftProjection
    || targetOwnsDecision
  )) {
    if (exactPending.run.id !== target.id && canCloseSupersededApprovalProjection(target, keys)) {
      saveRunFromSnapshot(corpus, transitionAgentRun(target, "canceled", {
        actor: flag(parsed, "actor") || "org2-approval-reconciler",
        reason: `Duplicate approval request reused ${exactPending.run.id}:${exactPending.approval.id}.`,
      }), snapshots);
    }
    return exactPending.run;
  }

  const canonicalReference = [...references].sort(compareApprovalReferences).at(-1);
  const canonicalRun = targetOwnsDecision || !targetIsDraftProjection || !canonicalReference
    ? target
    : canonicalReference.run;
  const replacementApprovalId = crypto.randomUUID();
  const actor = flag(parsed, "actor") || "org2-approval-reconciler";
  const updatedRuns = new Map<string, AgentRun>();
  updatedRuns.set(canonicalRun.id, canonicalRun);

  for (const reference of references) {
    if (reference.approval.status !== "pending") continue;
    const current = updatedRuns.get(reference.run.id) || reference.run;
    updatedRuns.set(reference.run.id, supersedeAgentRunApproval(current, reference.approval.id, {
      actor,
      replacementRunId: canonicalRun.id,
      replacementApprovalId,
    }));
  }

  let updatedCanonical = updatedRuns.get(canonicalRun.id) || canonicalRun;
  updatedCanonical = requestAgentRunApproval(updatedCanonical, {
    ...input,
    id: replacementApprovalId,
  }, flag(parsed, "actor"));
  updatedRuns.set(updatedCanonical.id, updatedCanonical);

  if (target.id !== updatedCanonical.id && canCloseSupersededApprovalProjection(target, keys)) {
    const currentTarget = updatedRuns.get(target.id) || target;
    updatedRuns.set(target.id, transitionAgentRun(currentTarget, "canceled", {
      actor,
      reason: `Approval request was attached to existing run ${updatedCanonical.id}.`,
    }));
  }
  for (const [runId, candidate] of updatedRuns) {
    if (runId === updatedCanonical.id) continue;
    saveRunFromSnapshot(
      corpus,
      closeSupersededApprovalProjection(
        candidate,
        keys,
        updatedCanonical.id,
        replacementApprovalId,
        actor,
      ),
      snapshots,
    );
  }
  saveRunFromSnapshot(corpus, updatedCanonical, snapshots);
  return updatedCanonical;
}

function correlatedApprovalDecision(
  parsed: ParsedArgs,
  corpus: string,
  targetSnapshot: AgentRunSnapshot,
): AgentRun | null {
  const target = targetSnapshot.run;
  const approvalId = required(parsed.positional[2], "approval id is required");
  const approval = target.approvals.find((candidate) => candidate.id === approvalId);
  if (!approval) throw new Error(`approval not found: ${approvalId}`);
  const keys = agentRunApprovalDecisionKeys(approval);
  if (keys.length === 0) return null;

  const snapshots = correlatedRunSnapshotMap(corpus, keys, targetSnapshot);
  const references = approvalReferences([...snapshots.values()].map((snapshot) => snapshot.run), keys);
  for (const key of keys) {
    const latest = references
      .filter((reference) => agentRunApprovalDecisionKeys(reference.approval).includes(key))
      .sort(compareApprovalReferences)
      .at(-1);
    if (latest && (latest.run.id !== target.id || latest.approval.id !== approval.id)) {
      throw new Error(
        `approval ${approval.id} is superseded by ${latest.run.id}:${latest.approval.id}; decide the latest review material`,
      );
    }
  }

  const actor = required(flag(parsed, "actor"), "--actor is required");
  const updated = decideAgentRunApproval(
    target,
    approvalId,
    choice(flag(parsed, "decision"), AGENT_RUN_APPROVAL_DECISIONS, "approval decision"),
    {
      actor,
      actorRole: flag(parsed, "role"),
      fingerprint: flag(parsed, "fingerprint"),
      note: flag(parsed, "note"),
      receipt: flag(parsed, "receipt"),
    },
  );
  const updatedRuns = new Map<string, AgentRun>();

  for (const reference of references) {
    if (reference.run.id === target.id || reference.approval.status !== "pending") continue;
    const current = updatedRuns.get(reference.run.id) || reference.run;
    updatedRuns.set(reference.run.id, supersedeAgentRunApproval(current, reference.approval.id, {
      actor: "org2-approval-reconciler",
      replacementRunId: target.id,
      replacementApprovalId: approval.id,
    }));
  }
  for (const candidate of updatedRuns.values()) {
    saveRunFromSnapshot(
      corpus,
      closeSupersededApprovalProjection(
        candidate,
        keys,
        target.id,
        approval.id,
      ),
      snapshots,
    );
  }
  saveRunFromSnapshot(corpus, updated, snapshots);
  return updated;
}

function reconcileCorrelatedApprovals(corpus: string, apply: boolean): {
  schema: "org2:approval-reconciliation:v1";
  applied: boolean;
  changed: boolean;
  updates: Array<{
    decisionKey: string;
    runId: string;
    approvalId: string;
    replacementRunId: string;
    replacementApprovalId: string;
    runClosed: boolean;
  }>;
} {
  const snapshots = runSnapshotMap(corpus);
  const runs = [...snapshots.values()].map((snapshot) => snapshot.run);
  const referencesByKey = new Map<string, AgentRunApprovalReference[]>();
  for (const run of runs) {
    for (const approval of run.approvals) {
      for (const key of agentRunApprovalDecisionKeys(approval)) {
        referencesByKey.set(key, [
          ...(referencesByKey.get(key) || []),
          { run, approval },
        ]);
      }
    }
  }

  const updatedRuns = new Map<string, AgentRun>();
  const processed = new Set<string>();
  const updates: Array<{
    decisionKey: string;
    runId: string;
    approvalId: string;
    replacementRunId: string;
    replacementApprovalId: string;
    runClosed: boolean;
  }> = [];
  for (const [decisionKey, references] of referencesByKey) {
    const canonical = [...references].sort(compareApprovalReferences).at(-1);
    if (!canonical) continue;
    for (const reference of references) {
      const identity = `${reference.run.id}:${reference.approval.id}`;
      if (identity === `${canonical.run.id}:${canonical.approval.id}`
        || reference.approval.status !== "pending"
        || processed.has(identity)) {
        continue;
      }
      processed.add(identity);
      const current = updatedRuns.get(reference.run.id) || reference.run;
      let reconciled = supersedeAgentRunApproval(current, reference.approval.id, {
        actor: "org2-approval-reconciler",
        replacementRunId: canonical.run.id,
        replacementApprovalId: canonical.approval.id,
      });
      const runClosed = canCloseSupersededApprovalProjection(reconciled, [decisionKey]);
      if (runClosed) {
        reconciled = closeSupersededApprovalProjection(
          reconciled,
          [decisionKey],
          canonical.run.id,
          canonical.approval.id,
        );
      }
      updatedRuns.set(reconciled.id, reconciled);
      updates.push({
        decisionKey,
        runId: reference.run.id,
        approvalId: reference.approval.id,
        replacementRunId: canonical.run.id,
        replacementApprovalId: canonical.approval.id,
        runClosed,
      });
    }
  }
  if (apply) {
    for (const run of updatedRuns.values()) saveRunFromSnapshot(corpus, run, snapshots);
  }
  return {
    schema: "org2:approval-reconciliation:v1",
    applied: apply,
    changed: updates.length > 0,
    updates,
  };
}

function resolveCorrelatedApproval(corpus: string, rawDecisionKey: string): {
  schema: "org2:approval-resolution:v1";
  found: boolean;
  decisionKey: string;
  canonical?: {
    runId: string;
    runStatus: AgentRunStatus;
    approval: AgentRunApproval;
  };
  projections: Array<{
    runId: string;
    runStatus: AgentRunStatus;
    approvalId: string;
    approvalStatus: AgentRunApproval["status"];
    requestedAt: string;
  }>;
} {
  const normalized = rawDecisionKey.trim().toLowerCase();
  const decisionKey = normalized.startsWith("artifact:") ? normalized : `artifact:${normalized}`;
  const references = approvalReferences(listAgentRuns(corpus), [decisionKey])
    .filter((reference) => agentRunApprovalDecisionKeys(reference.approval).includes(decisionKey))
    .sort(compareApprovalReferences);
  const canonical = references.at(-1);
  return {
    schema: "org2:approval-resolution:v1",
    found: Boolean(canonical),
    decisionKey,
    ...(canonical ? {
      canonical: {
        runId: canonical.run.id,
        runStatus: canonical.run.status,
        approval: canonical.approval,
      },
    } : {}),
    projections: references.map((reference) => ({
      runId: reference.run.id,
      runStatus: reference.run.status,
      approvalId: reference.approval.id,
      approvalStatus: reference.approval.status,
      requestedAt: reference.approval.requestedAt,
    })),
  };
}

function runtimeBindings(parsed: ParsedArgs): AgentRuntimeBinding[] {
  return flags(parsed, "binding").map((raw) => {
    const colon = raw.indexOf(":");
    if (colon < 1 || colon === raw.length - 1) throw new Error("--binding must be RUNTIME:AGENT_ID");
    return { runtime: raw.slice(0, colon).trim().toLowerCase(), runtimeAgentId: raw.slice(colon + 1).trim() };
  });
}

function agentProfileDefaultRuntime(raw: string | undefined): AgentProfileDefaultRuntime | undefined {
  if (raw === undefined || raw === "none") return undefined;
  return choice(raw, AGENT_PROFILE_DEFAULT_RUNTIMES, "agent default runtime");
}

function goalCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  if (action === "list") {
    const payload = workspaceGoalList(corpus, flag(parsed, "status"));
    output(parsed, payload, payload.goals.length ? payload.goals.map((goal) => `${goal.id}\t${goal.status}\t${goal.title}`).join("\n") : "No goals.");
    return;
  }
  const id = required(parsed.positional[1], `goal id is required for ${action}`);
  if (action === "show") {
    const snapshot = loadGoalSnapshot(corpus, id);
    output(parsed, snapshot.value, snapshot.raw);
    return;
  }
  if (action === "create") {
    const goal = createGoal({
      id,
      title: required(flag(parsed, "title"), "--title is required"),
      description: flag(parsed, "description"),
      status: optionalChoice(flag(parsed, "status"), GOAL_STATUSES, "goal status"),
      parentGoalRef: flag(parsed, "parent-goal-ref"),
      ownerAgentRef: flag(parsed, "owner-agent-ref"),
      measures: flags(parsed, "measure"),
    });
    const file = goalPath(corpus, goal.id);
    if (enabled(parsed, "apply")) saveGoal(corpus, goal, { expectedRevision: null });
    output(parsed, { schema: "org2:goal-mutation:v1", applied: enabled(parsed, "apply"), file, goal, preview: renderGoalOrg(goal) }, `${enabled(parsed, "apply") ? "created" : "would create"} ${goal.id}\n${file}`);
    return;
  }
  if (action === "update") {
    const snapshot = loadGoalSnapshot(corpus, id);
    const goal = {
      ...snapshot.value,
      ...(flag(parsed, "title") !== undefined ? { title: flag(parsed, "title")! } : {}),
      ...(flag(parsed, "description") !== undefined ? { description: flag(parsed, "description")! } : {}),
      ...(flag(parsed, "status") !== undefined ? { status: choice(flag(parsed, "status"), GOAL_STATUSES, "goal status") } : {}),
      ...(flag(parsed, "parent-goal-ref") !== undefined ? { parentGoalRef: flag(parsed, "parent-goal-ref") } : {}),
      ...(flag(parsed, "owner-agent-ref") !== undefined ? { ownerAgentRef: flag(parsed, "owner-agent-ref") } : {}),
      ...(parsed.flags.has("measure") ? { measures: flags(parsed, "measure") } : {}),
      updatedAt: new Date().toISOString(),
    };
    if (enabled(parsed, "apply")) saveGoal(corpus, goal, { expectedRevision: snapshot.revision });
    output(parsed, { schema: "org2:goal-mutation:v1", applied: enabled(parsed, "apply"), file: snapshot.file, goal, preview: renderGoalOrg(goal) }, `${enabled(parsed, "apply") ? "updated" : "would update"} ${goal.id}\n${snapshot.file}`);
    return;
  }
  throw new Error(`unknown goal action: ${action}`);
}

function agentProfileCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  if (action === "list") {
    const payload = workspaceProfileList(corpus, flag(parsed, "status"));
    output(parsed, payload, payload.profiles.length ? payload.profiles.map((profile) => `${profile.id}\t${profile.status}\t${profile.name}`).join("\n") : "No agent profiles.");
    return;
  }
  if (action === "resolve") {
    const resolved = resolveAgentProfile(corpus, required(flag(parsed, "runtime"), "--runtime is required"), required(flag(parsed, "runtime-agent-id"), "--runtime-agent-id is required"));
    output(parsed, resolved, resolved.found ? `${resolved.runtime}:${resolved.runtimeAgentId}\t${resolved.agentRef}${resolved.goalRef ? `\tgoal ${resolved.goalRef}` : ""}` : `${resolved.runtime}:${resolved.runtimeAgentId}\tnot bound`);
    return;
  }
  const id = required(parsed.positional[1], `agent profile id is required for ${action}`);
  if (action === "show") {
    const snapshot = loadAgentProfileSnapshot(corpus, id);
    output(parsed, snapshot.value, snapshot.raw);
    return;
  }
  if (action === "create") {
    const profile = createAgentProfile({
      id,
      name: required(flag(parsed, "name"), "--name is required"),
      description: flag(parsed, "description"),
      status: optionalChoice(flag(parsed, "status"), AGENT_PROFILE_STATUSES, "agent profile status"),
      responsibilities: flags(parsed, "responsibility"),
      capabilities: flags(parsed, "capability"),
      skills: flags(parsed, "skill"),
      defaultRuntime: agentProfileDefaultRuntime(flag(parsed, "default-runtime")),
      runtimeBindings: runtimeBindings(parsed),
      goalRefs: flags(parsed, "goal-ref"),
      primaryGoalRef: flag(parsed, "primary-goal-ref"),
      reportsToAgentRef: flag(parsed, "reports-to-agent-ref"),
    });
    const file = agentProfilePath(corpus, profile.id);
    if (enabled(parsed, "apply")) saveAgentProfile(corpus, profile, { expectedRevision: null });
    output(parsed, { schema: "org2:agent-profile-mutation:v1", applied: enabled(parsed, "apply"), file, profile, preview: renderAgentProfileOrg(profile) }, `${enabled(parsed, "apply") ? "created" : "would create"} ${profile.id}\n${file}`);
    return;
  }
  if (action === "update") {
    const snapshot = loadAgentProfileSnapshot(corpus, id);
    const primaryGoalRef = flag(parsed, "primary-goal-ref");
    const goalRefs = parsed.flags.has("goal-ref") ? flags(parsed, "goal-ref") : snapshot.value.goalRefs;
    const profile = {
      ...snapshot.value,
      ...(flag(parsed, "name") !== undefined ? { name: flag(parsed, "name")! } : {}),
      ...(flag(parsed, "description") !== undefined ? { description: flag(parsed, "description")! } : {}),
      ...(flag(parsed, "status") !== undefined ? { status: choice(flag(parsed, "status"), AGENT_PROFILE_STATUSES, "agent profile status") } : {}),
      ...(parsed.flags.has("responsibility") ? { responsibilities: flags(parsed, "responsibility") } : {}),
      ...(parsed.flags.has("capability") ? { capabilities: flags(parsed, "capability") } : {}),
      ...(parsed.flags.has("skill") ? { skills: flags(parsed, "skill") } : {}),
      ...(parsed.flags.has("default-runtime") ? { defaultRuntime: agentProfileDefaultRuntime(flag(parsed, "default-runtime")) } : {}),
      ...(parsed.flags.has("binding") ? { runtimeBindings: runtimeBindings(parsed) } : {}),
      goalRefs: [...new Set([...goalRefs, ...(primaryGoalRef ? [primaryGoalRef] : [])])],
      ...(primaryGoalRef !== undefined ? { primaryGoalRef } : {}),
      ...(flag(parsed, "reports-to-agent-ref") !== undefined ? { reportsToAgentRef: flag(parsed, "reports-to-agent-ref") } : {}),
      updatedAt: new Date().toISOString(),
    };
    if (enabled(parsed, "apply")) saveAgentProfile(corpus, profile, { expectedRevision: snapshot.revision });
    output(parsed, { schema: "org2:agent-profile-mutation:v1", applied: enabled(parsed, "apply"), file: snapshot.file, profile, preview: renderAgentProfileOrg(profile) }, `${enabled(parsed, "apply") ? "updated" : "would update"} ${profile.id}\n${snapshot.file}`);
    return;
  }
  throw new Error(`unknown agent-profile action: ${action}`);
}

async function runCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "help";
  const corpus = root(parsed);
  if (action === "help") { output(parsed, HELP); return; }
  if (action === "create") {
    const risk = choice(flag(parsed, "risk", "local-draft"), AGENT_RUN_RISK_CLASSES, "risk class");
    const tokenLimit = flag(parsed, "token-limit"); const costLimit = flag(parsed, "cost-limit-usd"); const timeLimit = flag(parsed, "time-limit-seconds");
    const plan = flags(parsed, "step").map((raw, index) => { const colon = raw.indexOf(":"); const kind = colon > 0 ? raw.slice(0, colon) : "agent"; const title = colon > 0 ? raw.slice(colon + 1) : raw; if (!title.trim()) throw new Error(`--step ${index + 1} must be [${AGENT_RUN_STEP_KINDS.join("|")}]:TITLE`); return { id: `step-${index + 1}`, kind: choice(kind, AGENT_RUN_STEP_KINDS, `--step ${index + 1} kind`), title: title.trim() }; });
    const run = createAgentRun({ id: flag(parsed, "id"), title: flag(parsed, "title"), goal: required(flag(parsed, "goal"), "--goal is required"), goalRef: flag(parsed, "goal-ref"), agentRef: flag(parsed, "agent-ref"), acceptanceCriteria: flags(parsed, "accept"), riskClass: risk, owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), providerPolicy: flag(parsed, "policy"), provider: flag(parsed, "provider"), model: flag(parsed, "model"), capabilities: flags(parsed, "capability"), context: flags(parsed, "context").map((ref) => ({ ref })), plan, logicalWorkId: flag(parsed, "logical-work-id"), ...((tokenLimit || costLimit || timeLimit) ? { budget: { ...(tokenLimit ? { tokenLimit: Number(tokenLimit) } : {}), ...(costLimit ? { costLimitUsd: Number(costLimit) } : {}), ...(timeLimit ? { timeLimitSeconds: Number(timeLimit) } : {}) } } : {}) });
    const file = saveAgentRun(corpus, run, { expectedRevision: null }); output(parsed, { run, file }, `created ${run.id}\n${file}`); return;
  }
  if (action === "list") {
    const status = flag(parsed, "status");
    const payload = workspaceRunList(corpus, status);
    const runs = payload.runs;
    output(parsed, payload, runs.length ? runs.map((run) => `${run.id}\t${run.status}\t${run.attempt ? `${run.logicalWorkId}#${run.attempt.number}\t` : ""}${run.goal}`).join("\n") : "No runs."); return;
  }
  if (action === "normalize") { const result = normalizeLegacyAgentRuns(corpus); output(parsed, result, `created ${result.created.length}; skipped ${result.skippedExisting.length}`); return; }
  if (action === "approval-reconcile") {
    const result = reconcileCorrelatedApprovals(corpus, enabled(parsed, "apply"));
    output(
      parsed,
      result,
      `${result.applied ? "reconciled" : "would reconcile"} ${result.updates.length} duplicate approval projection(s)`,
    );
    return;
  }
  if (action === "approval-resolve") {
    const result = resolveCorrelatedApproval(
      corpus,
      required(flag(parsed, "decision-key"), "--decision-key is required"),
    );
    output(
      parsed,
      result,
      result.canonical
        ? `${result.decisionKey}\t${result.canonical.approval.status}\t${result.canonical.runId}:${result.canonical.approval.id}`
        : `${result.decisionKey}\tnot found`,
    );
    return;
  }
  if (action === "wait") {
    const { runRunWaitCommand } = await import("./activityCli.js");
    await runRunWaitCommand(corpus, parsed.positional[1], parsed.flags);
    return;
  }
  const id = required(parsed.positional[1], `run id is required for ${action}`);
  const existingSnapshot = loadAgentRunSnapshot(corpus, id);
  if (action === "show") {
    output(
      parsed,
      enabled(parsed, "with-revision") ? {
        schema: "org2:run-snapshot:v1",
        revision: existingSnapshot.revision,
        sourceIssues: existingSnapshot.sourceIssues,
        run: existingSnapshot.run,
      } : existingSnapshot.run,
      existingSnapshot.raw,
    );
    return;
  }
  if (action === "validate") { const result = validateAgentRun(existingSnapshot.run); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  if (action === "reconcile-source") {
    const expectedRevision = flag(parsed, "if-revision");
    if (expectedRevision && expectedRevision !== existingSnapshot.revision) {
      throw new Error(`run revision changed; expected ${expectedRevision}, found ${existingSnapshot.revision}: ${existingSnapshot.file}`);
    }
    const apply = enabled(parsed, "apply");
    const changed = renderAgentRunOrg(existingSnapshot.run) !== existingSnapshot.raw;
    if (apply && changed) {
      saveAgentRun(corpus, existingSnapshot.run, { expectedRevision: existingSnapshot.revision });
    }
    const reconciled = apply && changed ? loadAgentRunSnapshot(corpus, id) : existingSnapshot;
    const result = {
      schema: "org2:run-source-reconciliation:v1",
      applied: apply,
      changed,
      file: existingSnapshot.file,
      previousRevision: existingSnapshot.revision,
      revision: reconciled.revision,
      sourceIssues: existingSnapshot.sourceIssues,
      remainingSourceIssues: reconciled.sourceIssues,
      run: reconciled.run,
    };
    output(
      parsed,
      result,
      `${apply ? "reconciled" : changed ? "would reconcile" : "already reconciled"} ${id}`,
    );
    return;
  }
  assertRequestedRunRevision(parsed, existingSnapshot);
  const existing = existingSnapshot.run;
  let run = existing;
  const transitions: Record<string, AgentRunStatus> = { start: "running", resume: "running", retry: "queued", cancel: "canceled", complete: "completed", fail: "failed", block: "blocked" };
  if (action === "complete-external") run = completeAgentRunExternally(existing, {
    summary: flag(parsed, "summary"),
    actor: required(flag(parsed, "actor"), "--actor is required"),
  });
  else if (action === "reopen-external") run = reopenExternallyCompletedApprovalRun(existing, {
    summary: required(flag(parsed, "summary"), "--summary is required"),
    actor: required(flag(parsed, "actor"), "--actor is required"),
  });
  else if (action === "retry") {
    // Re-queuing work that an executor is still running, or whose result already
    // exists, would execute it twice. Refuse unless the caller forces it.
    const trace = traceAgentRun(corpus, existing);
    if (!trace.retry.safe && !enabled(parsed, "force")) {
      throw new Error(`refusing to retry ${id}: ${trace.retry.reason} (verdict ${trace.verdict}: ${trace.reason.summary}). Inspect with \`celorga activity trace --run ${id}\`; pass --force to retry anyway.`);
    }
    const base = trace.retry.safe ? existing : addAgentRunComment(existing, flag(parsed, "actor") ?? "celorga", `Retry forced despite trace verdict ${trace.verdict} (${trace.reason.code}): ${trace.retry.reason}`);
    const retried = transitionAgentRun(base, "queued", { actor: flag(parsed, "actor") });
    run = existing.approvals.some((approval) => approval.status === "pending")
      ? transitionAgentRun(retried, "waiting-approval", { actor: flag(parsed, "actor") })
      : retried;
  }
  else if (transitions[action]) run = transitionAgentRun(existing, transitions[action]!, {
    actor: flag(parsed, "actor"), reason: flag(parsed, "reason"), summary: flag(parsed, "summary"),
    highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"),
    separateFromApproval: enabled(parsed, "separate-from-approval"),
  });
  else if (action === "assign") run = updateAgentRunAssignment(existing, { owner: flag(parsed, "owner"), assignee: flag(parsed, "assignee"), agentRef: flag(parsed, "agent-ref"), goalRef: flag(parsed, "goal-ref"), actor: flag(parsed, "actor") });
  else if (action === "outcome") run = updateAgentRunOutcome(existing, { summary: required(flag(parsed, "summary"), "--summary is required"), highlights: flags(parsed, "highlight"), nextActions: flags(parsed, "next-action"), actor: flag(parsed, "actor") });
  else if (action === "runtime") {
    const numberFlag = (name: string): number | undefined => {
      const raw = flag(parsed, name);
      if (raw === undefined) return undefined;
      const value = Number(raw);
      if (!Number.isFinite(value) || value < 0) throw new Error(`--${name} must be a non-negative number`);
      return value;
    };
    run = updateAgentRunRuntime(existing, {
      provider: flag(parsed, "provider"),
      model: flag(parsed, "model"),
      tokensUsed: numberFlag("tokens-used"),
      costUsedUsd: numberFlag("cost-used-usd"),
      elapsedSeconds: numberFlag("elapsed-seconds"),
      actor: flag(parsed, "actor"),
    });
  }
  else if (action === "comment") run = addAgentRunComment(existing, required(flag(parsed, "author"), "--author is required"), required(flag(parsed, "body"), "--body is required"));
  else if (action === "step") run = updateAgentRunStep(existing, required(parsed.positional[2], "step id is required"), choice(flag(parsed, "status"), AGENT_RUN_STEP_STATUSES, "step status"), { actor: flag(parsed, "actor"), detail: flag(parsed, "detail") });
  else if (action === "artifact") run = addAgentRunArtifact(existing, { path: required(flag(parsed, "path"), "--path is required"), role: choice(flag(parsed, "role", "draft"), AGENT_RUN_ARTIFACT_ROLES, "artifact role"), title: flag(parsed, "title"), mediaType: flag(parsed, "media-type"), sha256: flag(parsed, "sha256"), reviewStatus: optionalChoice(flag(parsed, "review-status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status") }, flag(parsed, "actor"));
  else if (action === "artifact-review") {
    const artifactId = required(parsed.positional[2], "artifact id is required");
    const reviewStatus = choice(flag(parsed, "status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status");
    const artifact = existing.artifacts.find((item) => item.id === artifactId);
    if (!artifact) throw new Error(`unknown artifact id: ${artifactId}`);
    run = updateAgentRunArtifactReview(existing, artifactId, reviewStatus, { actor: flag(parsed, "actor") });
  }
  else if (action === "validation") run = addAgentRunValidation(existing, { name: required(flag(parsed, "name"), "--name is required"), status: choice(flag(parsed, "status"), AGENT_RUN_VALIDATION_STATUSES, "validation status"), detail: flag(parsed, "detail") }, flag(parsed, "actor"));
  else if (action === "approval-request") {
    const correlated = correlatedApprovalRequest(parsed, corpus, existingSnapshot);
    if (correlated) {
      output(parsed, correlated, `${correlated.id}: ${correlated.status}`);
      return;
    }
    run = requestAgentRunApproval(existing, { title: required(flag(parsed, "title"), "--title is required"), action: required(flag(parsed, "action"), "--action is required"), riskClass: choice(flag(parsed, "risk", existing.riskClass), AGENT_RUN_RISK_CLASSES, "approval risk class"), requestedRole: flag(parsed, "role"), requestedFrom: flag(parsed, "from"), note: flag(parsed, "note"), priority: choice(flag(parsed, "priority", "normal"), AGENT_RUN_APPROVAL_PRIORITIES, "approval priority") }, flag(parsed, "actor"));
  }
  else if (action === "approval-decide") {
    const correlated = correlatedApprovalDecision(parsed, corpus, existingSnapshot);
    if (correlated) {
      output(parsed, correlated, `${correlated.id}: ${correlated.status}`);
      return;
    }
    run = decideAgentRunApproval(existing, required(parsed.positional[2], "approval id is required"), choice(flag(parsed, "decision"), AGENT_RUN_APPROVAL_DECISIONS, "approval decision"), { actor: required(flag(parsed, "actor"), "--actor is required"), actorRole: flag(parsed, "role"), fingerprint: flag(parsed, "fingerprint"), note: flag(parsed, "note"), receipt: flag(parsed, "receipt") });
  }
  else if (action === "fork") { run = forkAgentRun(existing, { id: flag(parsed, "id"), actor: flag(parsed, "actor"), fromEventId: flag(parsed, "event") }); const file = saveAgentRun(corpus, run, { expectedRevision: null }); output(parsed, { run, file }, `forked ${existing.id} -> ${run.id}`); return; }
  else throw new Error(`unknown run action: ${action}`);
  saveAgentRun(corpus, run, { expectedRevision: existingSnapshot.revision, rejectSourceDrift: true });
  if (action === "artifact-review") {
    const artifactId = required(parsed.positional[2], "artifact id is required");
    const artifact = existing.artifacts.find((item) => item.id === artifactId)!;
    const reviewStatus = choice(flag(parsed, "status"), AGENT_RUN_ARTIFACT_REVIEW_STATUSES, "artifact review status");
    syncLinkedArtifactReviewStatus(root(parsed), artifact.path, reviewStatus);
  }
  output(parsed, run, `${run.id}: ${run.status}`);
}

function reviewCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list";
  const corpus = root(parsed);
  const runs = listAgentRuns(corpus);
  if (action === "list") {
    const items = runs.flatMap((run) => [
      ...run.approvals.filter((approval) => !flag(parsed, "status") || approval.status === flag(parsed, "status")).map((approval) => ({ kind: "approval", runId: run.id, runGoal: run.goal, ...approval })),
      ...run.artifacts.filter((artifact) => artifact.reviewStatus === "review-required").map((artifact) => ({ kind: "artifact", runId: run.id, runGoal: run.goal, ...artifact })),
      ...(run.status === "blocked" ? [{ kind: "clarification", runId: run.id, runGoal: run.goal, reason: run.blockedReason }] : []),
      ...run.validations.filter((validation) => validation.status === "failed" || validation.status === "warning").map((validation) => ({ kind: "validation", runId: run.id, runGoal: run.goal, ...validation })),
    ]);
    output(parsed, { schema: "org2:review-queue:v1", items }, items.length ? items.map((item: any) => `${item.kind}\t${item.runId}\t${item.title || item.name || item.path || item.reason}`).join("\n") : "Review queue is empty."); return;
  }
  if (action === "show") { const run = loadAgentRun(corpus, required(parsed.positional[1], "run id is required")); output(parsed, { run, approvals: run.approvals, artifacts: run.artifacts, validations: run.validations, comments: run.comments }); return; }
  throw new Error(`unknown review action: ${action}`);
}

function workflowCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "list"; const corpus = root(parsed);
  if (action === "list") {
    const payload = workspaceWorkflowList(corpus);
    const workflows = payload.workflows;
    output(parsed, payload, workflows.length ? workflows.map((item) => `${item.id}@${item.version}\t${item.state}\t${item.title}`).join("\n") : "No workflows.");
    return;
  }
  if (action === "migrate") {
    const migrated = migrateLegacyWorkflows(corpus);
    output(parsed, { schema: "org2:workflow-migration:v1", migrated }, migrated.length ? migrated.map((item) => `${item.skipped ? "kept" : "moved"}\t${item.id}\t${item.to}`).join("\n") : "No legacy workflows.");
    return;
  }
  if (action === "install-builtin") { const name = parsed.positional[1] || "meeting-to-controlled-execution"; if (name !== "meeting-to-controlled-execution") throw new Error(`unknown built-in workflow: ${name}`); const file = installBuiltinWorkflow(corpus, MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW); output(parsed, { id: name, file }, `installed ${name}\n${file}`); return; }
  if (action === "create") {
    const id = required(parsed.positional[1], "workflow id is required for create");
    const schedule = flag(parsed, "schedule")?.trim() || flag(parsed, "cron")?.trim();
    const workflow = promptAutomation({
      id,
      title: required(flag(parsed, "title"), "--title is required"),
      instructions: required(flag(parsed, "prompt"), "--prompt is required"),
      description: flag(parsed, "description"),
      destinationRef: flag(parsed, "destination-ref") || flag(parsed, "destination"),
      model: flag(parsed, "model"),
      reasoningEffort: flag(parsed, "reasoning-effort") || flag(parsed, "reasoning"),
      agentRef: flag(parsed, "agent-ref"),
      goalRef: flag(parsed, "goal-ref"),
      schedule,
      timezone: flag(parsed, "timezone") || flag(parsed, "tz"),
      state: optionalChoice(flag(parsed, "state"), ["draft", "active", "paused"] as const, "workflow state"),
      now: flag(parsed, "now"),
    });
    const file = saveWorkflow(corpus, workflow, { expectedRevision: null });
    output(parsed, { schema: "org2:automation-created:v1", workflow, file }, `created ${workflow.id}\n${file}`);
    return;
  }
  if (action === "due") {
    const now = flag(parsed, "now") || new Date().toISOString();
    const owner = automationHostRef(corpus);
    const requestingHost = flag(parsed, "host-ref") || "desktop";
    if (owner !== requestingHost) {
      output(parsed, { schema: "org2:automation-due-list:v1", now, due: [], skipped: [], failures: [], hostRef: owner, reason: `Automations are owned by ${owner}` }, `Automations are owned by ${owner}.`);
      return;
    }
    const runs = listAgentRuns(corpus);
    const due: Array<Record<string, unknown>> = [];
    const skipped: Array<Record<string, unknown>> = [];
    const pending: Array<Record<string, unknown>> = [];
    // Tells schedulers which deterministic detectors (`workflow observe`, `workflow poll`) to run.
    const eventSources = { todoState: false, pullRequest: false };
    const failures: Array<Record<string, unknown>> = [];
    const runsById = new Map(runs.map((run) => [run.id, run]));
    const latestScheduledAttempts = new Map(summarizeAgentRunAttempts(
      runs.filter((run) => run.attempt?.triggerType === "schedule"),
    ).map((attempt) => [attempt.logicalWorkId, runsById.get(attempt.latestRunId)!]));
    for (const item of listWorkflows(corpus).filter((candidate) => candidate.state === "active")) {
      const latestAttempt = latestScheduledAttempts.get(`workflow:${item.id}`);
      if (item.triggers.some((trigger) => trigger.type === "schedule" && trigger.enabled)
          && latestAttempt?.status === "failed") {
        failures.push({
          workflowId: item.id,
          title: item.title,
          runId: latestAttempt.id,
          destinationRef: latestAttempt.destinationRef,
          scheduledFor: latestAttempt.attempt?.scheduledFor,
          failure: latestAttempt.failure || "The latest scheduled attempt failed.",
        });
      }
      for (const occurrence of workflowScheduleOccurrences(item, { now })) {
        const logicalWorkId = `workflow:${item.id}`;
        const activeRun = runs.find((run) => run.logicalWorkId === logicalWorkId && workflowAttemptHoldsScheduleSlot(run, occurrence.trigger));
        const summary = {
          workflowId: item.id,
          title: item.title,
          destinationRef: item.destinationRef,
          model: item.model,
          reasoningEffort: item.reasoningEffort,
          agentRef: item.agentRef,
          goalRef: item.goalRef,
          triggerId: occurrence.trigger.id,
          schedule: occurrence.trigger.schedule,
          timezone: occurrence.trigger.timezone,
          scheduledFor: occurrence.scheduledFor,
        };
        if (activeRun) skipped.push({ ...summary, reason: `active attempt ${activeRun.id} is ${activeRun.status}`, activeRunId: activeRun.id });
        else due.push(summary);
      }
      for (const trigger of item.triggers.filter((candidate) => isSignalTrigger(candidate))) {
        if (trigger.enabled) eventSources[trigger.type === "todo-state" ? "todoState" : "pullRequest"] = true;
        for (const window of workflowEventTriggerWindows(item, trigger, { now })) {
          const summary = {
            workflowId: item.id,
            title: item.title,
            destinationRef: item.destinationRef,
            model: item.model,
            reasoningEffort: item.reasoningEffort,
            agentRef: item.agentRef,
            goalRef: item.goalRef,
            triggerId: trigger.id,
            triggerType: trigger.type,
            ...(trigger.coalesce ? { coalesce: trigger.coalesce } : {}),
            scheduledFor: window.scheduledFor,
            signalIds: window.signals.map((signal) => signal.id),
          };
          if (window.ready) due.push(summary);
          else pending.push({ ...summary, reason: `coalescing until ${window.scheduledFor}` });
        }
      }
    }
    output(parsed, { schema: "org2:automation-due-list:v1", now, due, skipped, pending, eventSources, failures, hostRef: owner }, due.length ? due.map((item) => `${item.workflowId}\t${item.scheduledFor}${item.triggerType ? `\t${item.triggerType}` : ""}`).join("\n") : "No automations due.");
    return;
  }
  if (action === "observe" || action === "poll") {
    const owner = automationHostRef(corpus);
    const requestingHost = flag(parsed, "host-ref") || "desktop";
    if (owner !== requestingHost) {
      const schema = action === "observe" ? "org2:workflow-observe:v1" : "org2:workflow-poll:v1";
      output(parsed, { schema, applied: false, status: "not-owner", hostRef: owner, message: `Automations are owned by ${owner}`, signals: [], recorded: 0 }, `Automations are owned by ${owner}.`);
      return;
    }
    if (action === "observe") {
      const result = observeTodoStateTransitions(corpus, { changed: flags(parsed, "changed"), apply: enabled(parsed, "apply"), now: flag(parsed, "now") });
      output(parsed, result, [
        `${result.applied ? "" : "preview: "}${result.message}`,
        ...result.signals.map((item) => `${item.workflowId}/${item.triggerId}\t${item.signal.todoState?.file}:${item.signal.todoState?.line}\t${item.signal.todoState?.from ?? "(new)"} -> ${item.signal.todoState?.to}\t${item.signal.todoState?.title}`),
        ...(!result.applied && result.status === "ok" ? ["Run again with --apply to record signals and advance the snapshot."] : []),
      ].join("\n"));
      return;
    }
    const source = required(flag(parsed, "source"), "--source github is required");
    if (source !== "github") throw new Error(`unsupported workflow poll source: ${source}; use github`);
    const result = pollGithubPullRequests(corpus, { apply: enabled(parsed, "apply"), now: flag(parsed, "now"), workflowId: flag(parsed, "workflow") });
    output(parsed, result, [
      `${result.applied ? "" : "preview: "}${result.message}`,
      ...result.triggers.map((item) => `${item.workflowId}/${item.triggerId}\t${item.repo}\t${item.status}${item.message ? `\t${item.message}` : ""}`),
      ...result.signals.map((item) => `${item.workflowId}/${item.triggerId}\t${item.signal.pullRequest?.repo}#${item.signal.pullRequest?.number}\t${item.signal.pullRequest?.event}`),
      ...(!result.applied && (result.status === "ok" || result.status === "partial") ? ["Run again with --apply to record signals and advance cursors."] : []),
    ].join("\n"));
    return;
  }
  const id = required(parsed.positional[1], `workflow id is required for ${action}`);
  if (action === "save") { const run = loadAgentRun(corpus, id); const workflow = workflowFromRun(run, { id: flag(parsed, "id"), title: flag(parsed, "title"), version: flag(parsed, "version") }); const file = saveWorkflow(corpus, workflow, { expectedRevision: null }); output(parsed, { workflow, file }, `saved ${workflow.id}@${workflow.version}`); return; }
  if (action === "delete") {
    const result = deleteWorkflow(corpus, id, { apply: enabled(parsed, "apply") });
    output(
      parsed,
      { schema: "org2:workflow-deletion:v1", ...result },
      `${result.applied ? "deleted" : "would delete"} ${id}\n${result.files.join("\n")}`,
    );
    return;
  }
  const workflow = loadWorkflow(corpus, id);
  if (action === "show") { output(parsed, workflow); return; }
  if (action === "validate") { const result = validateWorkflow(workflow); output(parsed, result, result.valid ? `${id}: valid` : result.issues.map((issue) => `${issue.path}: ${issue.message}`).join("\n")); if (!result.valid) process.exitCode = 1; return; }
  if (action === "activate" || action === "pause" || action === "draft") {
    const state = action === "activate" ? "active" : action === "pause" ? "paused" : "draft";
    const updated = updateWorkflow(corpus, id, (item) => ({ ...item, state }));
    output(parsed, updated, `${id}: ${state}`);
    return;
  }
  if (action === "schedule") {
    const cron = flag(parsed, "cron")?.trim();
    const timezone = flag(parsed, "timezone")?.trim() || flag(parsed, "tz")?.trim();
    const disabled = parsed.flags.has("disable");
    const destinationRef = flag(parsed, "destination-ref") || flag(parsed, "destination");
    const model = flag(parsed, "model");
    const reasoningEffort = flag(parsed, "reasoning-effort") || flag(parsed, "reasoning");
    const clearModel = parsed.flags.has("clear-model");
    const clearReasoningEffort = parsed.flags.has("clear-reasoning-effort");
    const gateEvents = flags(parsed, "gate-event").map((event) =>
      choice(event, [...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"] as const, "workflow gate event")
    );
    const gatePaths = flags(parsed, "gate-path");
    const whenBlockedFlag = optionalChoice(flag(parsed, "when-blocked"), WORKFLOW_SCHEDULE_WHEN_BLOCKED, "workflow schedule --when-blocked");
    const whenRunningFlag = optionalChoice(flag(parsed, "when-running"), WORKFLOW_SCHEDULE_WHEN_RUNNING, "workflow schedule --when-running");
    if (!disabled && !cron) throw new Error("workflow schedule requires --cron EXPR or --disable");
    if (model && clearModel) throw new Error("workflow schedule accepts either --model or --clear-model, not both");
    if (reasoningEffort && clearReasoningEffort) throw new Error("workflow schedule accepts either --reasoning-effort or --clear-reasoning-effort, not both");
    const updated = updateWorkflow(corpus, id, (item) => {
      const scheduleIds = new Set<string>([WORKFLOW_SCHEDULE_TRIGGER_ID, ...LEGACY_WORKFLOW_SCHEDULE_TRIGGER_IDS]);
      const triggers = item.triggers.filter((trigger) => !scheduleIds.has(trigger.id));
      // Keep explicit overlap policies when the app re-saves only the cron.
      const previous = item.triggers.find((trigger) => scheduleIds.has(trigger.id));
      const whenBlocked = whenBlockedFlag ?? previous?.whenBlocked;
      const whenRunning = whenRunningFlag ?? previous?.whenRunning;
      if (!disabled) {
        triggers.push({
          id: WORKFLOW_SCHEDULE_TRIGGER_ID,
          type: "schedule",
          enabled: true,
          schedule: cron!,
          ...(timezone ? { timezone } : {}),
          ...(whenBlocked === "wait" ? { whenBlocked } : {}),
          ...(whenRunning === "wait" ? { whenRunning } : {}),
          ...((gateEvents.length || gatePaths.length) ? {
            gate: {
              ...(gateEvents.length ? { events: gateEvents } : {}),
              ...(gatePaths.length ? { paths: gatePaths } : {}),
            },
          } : {}),
        });
      }
      return {
        ...item,
        triggers,
        ...(destinationRef ? { destinationRef: destinationRef.trim() } : {}),
        ...(model ? { model: model.trim() } : {}),
        ...(clearModel ? { model: undefined } : {}),
        ...(reasoningEffort ? { reasoningEffort: reasoningEffort.trim() } : {}),
        ...(clearReasoningEffort ? { reasoningEffort: undefined } : {}),
      };
    });
    output(parsed, updated, disabled ? `${id}: schedule disabled` : `${id}: scheduled ${cron}`);
    return;
  }
  if (action === "package") { output(parsed, packagedWorkflowManifest(workflow)); return; }
  if (action === "corpus-template") { const template = packagedCorpusTemplate(workflow); const out = flag(parsed, "out"); if (out) { const file = path.resolve(out); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(template, null, 2)}\n`, "utf8"); output(parsed, { template, file }, file); } else output(parsed, template); return; }
  if (action === "triggers") {
    const event = optionalChoice(flag(parsed, "event"), WORKFLOW_EVENT_TRIGGER_TYPES, "workflow event");
    const due = dueWorkflowTriggers(workflow, {
      now: flag(parsed, "now"),
      changedPaths: flags(parsed, "changed"),
      event,
    });
    const events = workflow.triggers.filter((trigger) => isSignalTrigger(trigger)).map((trigger) => ({
      triggerId: trigger.id,
      type: trigger.type,
      ...(trigger.coalesce ? { coalesce: trigger.coalesce } : {}),
      windows: workflowEventTriggerWindows(workflow, trigger, { now: flag(parsed, "now") }).map((window) => ({
        scheduledFor: window.scheduledFor,
        ready: window.ready,
        signalIds: window.signals.map((signal) => signal.id),
      })),
    }));
    output(parsed, { workflow: id, due, events }, due.length ? due.map((trigger) => `${trigger.id}\t${trigger.type}`).join("\n") : "No triggers due.");
    return;
  }
  if (action === "trigger-set") {
    const triggerId = required(flag(parsed, "trigger"), "--trigger is required");
    const type = choice(flag(parsed, "type"), WORKFLOW_SIGNAL_TRIGGER_TYPES, "workflow trigger-set --type");
    const list = (name: string) => flags(parsed, name).flatMap((value) => value.split(",")).map((value) => value.trim()).filter(Boolean);
    const coalesce = flag(parsed, "coalesce")?.trim();
    const numberFlag = flag(parsed, "number");
    const trigger: WorkflowTrigger = type === "todo-state"
      ? {
        id: triggerId,
        type,
        enabled: !parsed.flags.has("disable"),
        states: list("state"),
        ...(list("tag").length ? { tags: list("tag") } : {}),
        ...(list("path").length ? { paths: list("path") } : {}),
        ...(flag(parsed, "property")?.trim() ? { property: flag(parsed, "property")!.trim() } : {}),
        ...(coalesce ? { coalesce } : {}),
      }
      : {
        id: triggerId,
        type,
        enabled: !parsed.flags.has("disable"),
        repo: required(flag(parsed, "repo"), "--repo OWNER/NAME is required for pull-request triggers").trim(),
        ...(list("pr-event").length ? { events: list("pr-event").map((event) => choice(event, WORKFLOW_PULL_REQUEST_EVENTS, "workflow trigger-set --pr-event")) } : {}),
        ...(numberFlag !== undefined ? { number: Number(numberFlag) } : {}),
        ...(flag(parsed, "author")?.trim() ? { author: flag(parsed, "author")!.trim() } : {}),
        ...(coalesce ? { coalesce } : {}),
      };
    const updated = updateWorkflow(corpus, id, (item) => {
      const previous = item.triggers.find((candidate) => candidate.id === triggerId);
      if (previous && previous.type !== type) throw new Error(`trigger ${triggerId} is a ${previous.type} trigger; remove it first or choose another --trigger id`);
      // Keep the attempt boundary so editing filters does not replay consumed signals.
      const boundary = previous ? { ...(previous.lastAttemptAt ? { lastAttemptAt: previous.lastAttemptAt } : {}), ...(previous.lastRunAt ? { lastRunAt: previous.lastRunAt } : {}) } : {};
      return { ...item, triggers: [...item.triggers.filter((candidate) => candidate.id !== triggerId), { ...trigger, ...boundary }] };
    });
    output(parsed, updated, `${id}: ${type} trigger ${triggerId} saved`);
    return;
  }
  if (action === "trigger-remove") {
    const triggerId = required(flag(parsed, "trigger"), "--trigger is required");
    if (!workflow.triggers.some((trigger) => trigger.id === triggerId)) throw new Error(`workflow trigger not found: ${triggerId}`);
    const updated = updateWorkflow(corpus, id, (item) => ({
      ...item,
      triggers: item.triggers.filter((trigger) => trigger.id !== triggerId),
      ...(item.signals ? { signals: item.signals.filter((signal) => signal.triggerId !== triggerId) } : {}),
    }));
    output(parsed, updated, `${id}: trigger ${triggerId} removed`);
    return;
  }
  if (action === "signal") {
    const event = choice(flag(parsed, "event"), [...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"] as const, "workflow signal");
    const updated = updateWorkflow(corpus, id, (item) => recordWorkflowSignal(item, {
      id: flag(parsed, "signal-id"),
      type: event,
      at: flag(parsed, "at"),
      paths: flags(parsed, "changed"),
    }));
    output(parsed, updated, `${id}: recorded ${event} signal`);
    return;
  }
  if (action === "gate") {
    const triggerId = required(flag(parsed, "trigger"), "--trigger is required");
    const eligibility = workflowTriggerEligibility(workflow, triggerId);
    output(parsed, { schema: "org2:workflow-gate:v1", workflowId: id, triggerId, ...eligibility }, eligibility.eligible ? `${id}/${triggerId}: eligible` : `${id}/${triggerId}: skipped — ${eligibility.reason}`);
    return;
  }
  if (action === "run") {
    const release = acquireWorkflowDispatchLock(corpus, id);
    try {
      const workflow = loadWorkflow(corpus, id);
      const owner = automationHostRef(corpus);
      if (flag(parsed, "trigger") && owner !== (flag(parsed, "host-ref") || "desktop")) {
        output(parsed, { schema: "org2:workflow-run-skipped:v1", workflowId: id, eligible: false, reason: `Automations are owned by ${owner}` }, `Automations are owned by ${owner}.`);
        return;
      }
      const inputs = Object.fromEntries(flags(parsed, "input").map((item) => { const at = item.indexOf("="); if (at < 1) throw new Error("--input must be NAME=VALUE"); return [item.slice(0, at), item.slice(at + 1)]; }));
      const triggerId = flag(parsed, "trigger");
      const eventTrigger = triggerId ? workflow.triggers.find((item) => item.id === triggerId && isSignalTrigger(item)) : undefined;
      const eligibility: ReturnType<typeof workflowTriggerEligibility> = triggerId
        ? workflowTriggerEligibility(workflow, triggerId, eventTrigger ? { now: flag(parsed, "now"), until: flag(parsed, "scheduled-for") } : {})
        : { eligible: true, reason: "manual run", signalIds: [] };
      if (!eligibility.eligible) {
        output(parsed, { schema: "org2:workflow-run-skipped:v1", workflowId: id, triggerId, ...eligibility }, `skipped ${id}: ${eligibility.reason}`);
        return;
      }
      const logicalWorkId = flag(parsed, "logical-work-id") || `workflow:${id}`;
      const existingAttempts = listAgentRuns(corpus).filter((item) => item.logicalWorkId === logicalWorkId && item.attempt);
      const trigger = triggerId ? workflow.triggers.find((item) => item.id === triggerId) : undefined;
      // Event-triggered attempts are planned at the close of their signal window.
      const scheduledFor = eventTrigger ? eligibility.scheduledFor : flag(parsed, "scheduled-for");
      const priorOccurrence = triggerId && scheduledFor
        ? existingAttempts.find((item) => item.attempt?.triggerId === triggerId && (item.attempt?.scheduledFor === scheduledFor
          || (eventTrigger && item.attempt?.scheduledFor && new Date(item.attempt.scheduledFor).getTime() === new Date(scheduledFor).getTime())))
        : undefined;
      if (priorOccurrence) {
        output(parsed, { schema: "org2:workflow-run-skipped:v1", workflowId: id, triggerId, eligible: false,
          reason: `occurrence already has attempt ${priorOccurrence.id}`, activeRunId: priorOccurrence.id }, `Occurrence already dispatched: ${priorOccurrence.id}`);
        return;
      }
      const activeAttempt = trigger?.type === "schedule"
        ? existingAttempts.find((item) => workflowAttemptHoldsScheduleSlot(item, trigger))
        : undefined;
      if (activeAttempt) {
        output(parsed, {
          schema: "org2:workflow-run-skipped:v1",
          workflowId: id,
          triggerId,
          eligible: false,
          reason: `active attempt ${activeAttempt.id} is ${activeAttempt.status}`,
          activeRunId: activeAttempt.id,
        }, `skipped ${id}: active attempt ${activeAttempt.id} is ${activeAttempt.status}`);
        return;
      }
      const attemptNumber = existingAttempts.reduce((maximum, item) => Math.max(maximum, item.attempt?.number || 0), 0) + 1;
      const attemptAt = scheduledFor || new Date().toISOString();
      const triggerSignals = eventTrigger ? workflowSignalsById(workflow, eligibility.signalIds) : [];
      const run = instantiateWorkflow(workflow, inputs, {
        owner: flag(parsed, "owner"),
        assignee: flag(parsed, "assignee"),
        agentRef: flag(parsed, "agent-ref"),
        goalRef: flag(parsed, "goal-ref"),
        logicalWorkId: triggerId ? logicalWorkId : flag(parsed, "logical-work-id"),
        attempt: triggerId ? {
          id: flag(parsed, "attempt-id") || crypto.randomUUID(),
          number: attemptNumber,
          triggerId,
          triggerType: workflow.triggers.find((item) => item.id === triggerId)?.type,
          scheduledFor: attemptAt,
          signalIds: eligibility.signalIds,
          ...(triggerSignals.length ? { signals: triggerSignals.map((signal) => ({ ...signal })) } : {}),
        } : undefined,
        ...(triggerSignals.length ? { context: workflowSignalContext(triggerSignals) } : {}),
      });
      const file = saveAgentRun(corpus, run, { expectedRevision: null });
      if (triggerId) updateWorkflow(corpus, id, (item) => markWorkflowTriggerAttempt(item, triggerId, attemptAt));
      output(parsed, {
        run,
        file,
        eligibility,
        model: workflow.model,
        reasoningEffort: workflow.reasoningEffort,
        prompt: workflowExecutionPrompt(workflow, run, inputs),
      }, `created run ${run.id} from ${id}@${workflow.version}${run.attempt ? ` attempt ${run.attempt.number}` : ""}`);
      return;
    } finally { release(); }
  }
  throw new Error(`unknown workflow action: ${action}`);
}

function artifactCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "graph"; const corpus = root(parsed); const manifest = path.resolve(required(flag(parsed, "manifest"), "--manifest is required")); const graph = buildArtifactGraph(corpus, loadArtifactDeclarations(manifest));
  if (action === "graph") { const file = enabled(parsed, "apply") ? saveArtifactGraph(corpus, graph) : undefined; output(parsed, { graph, ...(file ? { file } : {}) }, graph.artifacts.map((item) => `${item.status}\t${item.path}${item.reason ? `\t${item.reason}` : ""}`).join("\n")); return; }
  if (action === "rebuild") { const plan = artifactRebuildPlan(graph); output(parsed, { schema: "org2:artifact-rebuild-plan:v1", plan }, plan.length ? plan.map((item) => `${item.path}\t${item.command || "manual"}\t${item.reason}`).join("\n") : "All artifacts are fresh."); return; }
  throw new Error(`unknown artifact action: ${action}`);
}

function runtimeCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "show"; const corpus = root(parsed);
  if (action === "init") { const config = loadRuntimePolicy(corpus); const file = saveRuntimePolicy(corpus, config); output(parsed, { config, file }, file); return; }
  const config = loadRuntimePolicy(corpus);
  if (action === "show") { output(parsed, { file: runtimePolicyPath(corpus), config }); return; }
  if (action === "select") { const policy = required(parsed.positional[1], "policy name is required"); const runtime = selectRuntime(config, policy, flags(parsed, "capability")); output(parsed, { policy, runtime }, `${runtime.id}\t${runtime.provider}/${runtime.model}\t${runtime.transport}`); return; }
  if (action === "verify-paths") { const result = validateRuntimePaths(config, flags(parsed, "capability")); output(parsed, result, result.valid ? `local: ${result.local!.id}\nhosted: ${result.hosted!.id}` : result.issues.join("\n")); if (!result.valid) process.exitCode = 1; return; }
  throw new Error(`unknown runtime action: ${action}`);
}

async function mcpCommand(parsed: ParsedArgs): Promise<void> {
  const action = parsed.positional[0] || "clients"; const corpus = root(parsed);
  if (action === "serve") { await serveMcp(corpus); return; }
  if (action === "clients") { const clients = loadMcpClients(corpus); output(parsed, { schema: "org2:mcp-clients:v1", clients }); return; }
  if (action === "client-add") { const id = required(parsed.positional[1], "client id is required"); const command = required(flag(parsed, "command"), "--command is required"); const clients = loadMcpClients(corpus).filter((item) => item.id !== id); clients.push({ id, command, args: flags(parsed, "arg"), capabilities: flags(parsed, "capability"), environmentVariables: flags(parsed, "env") }); const file = saveMcpClients(corpus, clients); output(parsed, { clients, file }, `saved ${id}`); return; }
  if (action === "discover") { const id = required(parsed.positional[1], "client id is required"); const discovery = discoverMcpClient(corpus, id, { timeoutMs: Number(flag(parsed, "timeout-ms", "10000")), snapshotId: flag(parsed, "snapshot") }); output(parsed, discovery, `${id}: ${Object.values(discovery.capabilities).flatMap((value) => Array.isArray(value) ? value : []).length} discovered item(s)${discovery.snapshot ? `\n${discovery.snapshot}` : ""}`); return; }
  if (action === "snapshot") { const id = required(parsed.positional[1], "snapshot id is required"); const source = required(flag(parsed, "source"), "--source is required"); const input = flag(parsed, "input"); const payload = input ? JSON.parse(fs.readFileSync(path.resolve(input), "utf8")) : JSON.parse(await new Promise<string>((resolve, reject) => { let raw = ""; process.stdin.setEncoding("utf8"); process.stdin.on("data", (chunk) => raw += chunk); process.stdin.on("end", () => resolve(raw)); process.stdin.on("error", reject); })); const snapshot = { schema: "org2:mcp-snapshot:v1" as const, id, source, retrievedAt: new Date().toISOString(), identity: flag(parsed, "identity"), freshUntil: flag(parsed, "fresh-until"), payload }; const file = writeMcpSnapshot(corpus, snapshot); output(parsed, { snapshot, file }, file); return; }
  throw new Error(`unknown mcp action: ${action}`);
}

function evalCommand(parsed: ParsedArgs): void {
  const action = parsed.positional[0] || "run"; const corpus = root(parsed); const id = required(parsed.positional[1], `${action === "replay" ? "workflow" : "run"} id is required`);
  if (action === "replay") { const result = replayWorkflowFixture(loadWorkflow(corpus, id), loadWorkflowReplayFixture(path.resolve(required(flag(parsed, "fixture"), "--fixture is required")))); output(parsed, result, `${result.passed ? "PASS" : "FAIL"} replay ${id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  const run = loadAgentRun(corpus, id);
  if (action === "run") { const result = evaluateRun(run, loadEvalExpectation(path.resolve(required(flag(parsed, "expect"), "--expect is required")))); const file = saveEvalResult(corpus, result); output(parsed, { result, file }, `${result.passed ? "PASS" : "FAIL"} ${run.id}\n${result.checks.map((item) => `${item.passed ? "PASS" : "FAIL"}\t${item.name}\t${item.detail}`).join("\n")}`); if (!result.passed) process.exitCode = 1; return; }
  if (action === "fixture") { const file = path.resolve(required(flag(parsed, "output"), "--output is required")); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(sanitizeRunFixture(run), null, 2)}\n`, "utf8"); output(parsed, { file }, file); return; }
  throw new Error(`unknown eval action: ${action}`);
}

function projectCommand(parsed: ParsedArgs): void {
  const [action = "list", id] = parsed.positional;
  const corpus = root(parsed);
  if (action === "list") { output(parsed, listProjectNotes(corpus)); return; }
  if (action === "show") {
    const project = listProjectNotes(corpus).projects.find(p => p.id === id);
    if (!project) throw new Error("Project not found or its ID is ambiguous");
    output(parsed, project); return;
  }
  if (action === "create" || action === "adopt") {
    output(parsed, createProjectNote(corpus, { title: required(flag(parsed, "title"), "--title is required"),
      description: flag(parsed, "description"), id: flag(parsed, "id"), color: flag(parsed, "color"), file: action === "adopt" ? required(id, "note path is required") : flag(parsed, "file"),
      adopt: action === "adopt", apply: enabled(parsed, "apply"), expectedRevision: flag(parsed, "if-revision") })); return;
  }
  if (action === "update") {
    output(parsed, updateProjectNote(corpus, required(id, "project ID is required"), { threadID: flag(parsed, "thread"),
      remove: enabled(parsed, "remove"), color: flag(parsed, "color"), apply: enabled(parsed, "apply"), expectedRevision: flag(parsed, "if-revision") })); return;
  }
  throw new Error(`Unknown project action: ${action}`);
}

export async function runAgenticWorkspaceCommand(args: string[]): Promise<boolean> {
  const family = args[0];
  if (!family || !["doctor", "ledger", "corpus", "workspace", "thread", "project", "goal", "agent-profile", "run", "review", "workflow", "artifact", "runtime", "mcp", "eval"].includes(family)) return false;
  const parsed = parseArgs(args.slice(1));
  if (enabled(parsed, "help") || parsed.positional[0] === "help") { output(parsed, HELP); return true; }
  if (family === "doctor") doctorCommand(parsed);
  else if (family === "ledger") ledgerCommand(parsed);
  else if (family === "corpus") corpusCommand(parsed);
  else if (family === "workspace") await workspaceCommand(parsed);
  else if (family === "thread") await threadCommand(parsed);
  else if (family === "project") projectCommand(parsed);
  else if (family === "goal") goalCommand(parsed);
  else if (family === "agent-profile") agentProfileCommand(parsed);
  else if (family === "run") await runCommand(parsed);
  else if (family === "review") reviewCommand(parsed);
  else if (family === "workflow") workflowCommand(parsed);
  else if (family === "artifact") artifactCommand(parsed);
  else if (family === "runtime") runtimeCommand(parsed);
  else if (family === "mcp") await mcpCommand(parsed);
  else if (family === "eval") evalCommand(parsed);
  return true;
}
