import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { includesMarker, markerValue, schemaMatches } from "./brand.js";

const execFileAsync = promisify(execFile);

const backgroundThreadDeliveryInstruction = "If this prompt includes CELORGA_AI_CHAT_THREAD_ID or ORG2_AI_CHAT_THREAD_ID and this execution is expected to report after its parent turn ends, post the durable outcome once with `celorga thread post THREAD_ID --message TEXT --author NAME --source run:RUN_ID --idempotency-key KEY --apply`. Do not duplicate a normal foreground reply, and do not post before the reported run state or artifact is durable.";

export function conciseGoal(prompt, fallback = "OpenClaw agent execution") {
  const clean = String(prompt || "").replace(/\s+/g, " ").trim();
  return (clean || fallback).slice(0, 240);
}

export function shouldTrackMainTurn(prompt, ctx = {}) {
  if (String(ctx.sessionKey || "").includes(":internal-session-effects:")
    || String(ctx.runId || "").startsWith("skill-workshop-review:")) return false;
  if (ctx.trigger === "heartbeat") return false;
  if (ctx.jobId || String(ctx.sessionKey || "").includes(":cron:")) return false;
  if (workflowMarker(prompt)) return true;
  const text = String(prompt || "").trim();
  if (!text) return false;
  if (/^(thanks|thank you|cool|ok(?:ay)?|got it|sounds good)[.!\s]*$/i.test(text)) return false;
  return /\b(build|implement|fix|update|change|create|ship|deploy|migrate|refactor|review|investigate|diagnos|audit|research|prepare|draft|submit|send|execute|run|reconcile|install|configure|set up|make sure)\b/i.test(text);
}

export function workflowMarker(prompt) {
  const text = String(prompt || "");
  const workflowId = markerValue(text, "WORKFLOW_ID", "([^\\s]+)", "\\s*");
  const workflowRunId = markerValue(text, "WORKFLOW_RUN_ID", "([^\\s]+)", "\\s*");
  const workflowRunStarted = /^true$/i.test(markerValue(text, "WORKFLOW_RUN_STARTED", "(true)", "\\s*") || "");
  const triggerId = markerValue(text, "WORKFLOW_TRIGGER_ID", "([^\\s]+)", "\\s*");
  const inputsRaw = markerValue(text, "WORKFLOW_INPUTS", "(\\{.*\\})", "\\s*");
  let inputs = {};
  if (inputsRaw) {
    try { inputs = JSON.parse(inputsRaw); } catch {}
  }
  return workflowId ? {
    workflowId,
    workflowRunId,
    ...(workflowRunStarted ? { workflowRunStarted: true } : {}),
    ...(triggerId ? { triggerId } : {}),
    inputs,
  } : null;
}

export function durableRunMarker(prompt) {
  const text = String(prompt || "");
  return markerValue(text, "RUN_ID", "([^\\s]+)", "\\s*");
}

export function workflowExecutionPrompt(workflow, inputs = {}, runId, triggerId) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    ...(runId ? [`ORG2_WORKFLOW_RUN_ID: ${runId}`] : []),
    ...(triggerId ? [`ORG2_WORKFLOW_TRIGGER_ID: ${triggerId}`] : []),
    ...(workflow.model ? [`ORG2_MODEL: ${workflow.model}`] : []),
    ...(workflow.reasoningEffort ? [`ORG2_REASONING_EFFORT: ${workflow.reasoningEffort}`] : []),
    `ORG2_WORKFLOW_INPUTS: ${JSON.stringify(inputs)}`,
    "",
    `Execute the Celorga workflow \"${workflow.title}\" from its canonical plain-text workflow file.`,
    ...(triggerId ? ["This is a scheduled attempt. The Celorga lifecycle adapter checks its declared event/fresh-work gate before creating the durable attempt; if no run was created, stop without executing workflow steps."] : []),
    "Read the workflow and durable run with the Celorga CLI (`celorga`, or `org2` on installs that predate the rename). Update run steps as they progress, record produced artifacts and validation results, and keep generated work in the declared reviewable locations.",
    "At an approval boundary, request the approval on this run and end the turn without performing the protected action. Celorga will explicitly continue the same run after every item in that boundary is decided.",
    "For a provider draft, keep the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line in the approval action. Reuse this run for revisions; never create a second review run for the same provider draft.",
    "Before requesting an external-action or high-impact approval, record the exact recipient, content, command, and attachments in an inspectable run artifact or approval note. An opaque ID or content fingerprint is not review material.",
    backgroundThreadDeliveryInstruction,
    "Do not bypass an approval, complete a run with a pending review boundary, or silently promote generated work into canonical notes. After a human review decision, record it with `celorga run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected` before completing the run.",
  ].join("\n");
}

export function workflowContinuationPrompt(workflow, runId) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `ORG2_WORKFLOW_RUN_ID: ${runId}`,
    "ORG2_WORKFLOW_RESUME: approval-decided",
    "",
    `Continue the Celorga workflow \"${workflow.title}\" using its existing durable run.`,
    "Re-read the workflow and run with the Celorga CLI (`celorga`, or `org2` on installs that predate the rename). Continue from the first incomplete step, perform only actions covered by recorded approvals, and preserve the run's artifacts, validation, and event history.",
    "Use this run for every replacement approval. Resolve provider authority, including decided approvals, through `celorga run approval-resolve --decision-key artifact:PROVIDER:TOOL:DRAFT_ID --json`; do not create a separate review run for a draft already represented here.",
    "Treat an approval as valid only for the exact review material recorded with it; do not substitute a new recipient, payload, command, or attachment after approval.",
    "When an approval resolves an artifact review boundary, record the artifact decision with `celorga run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected` before completing the run.",
    backgroundThreadDeliveryInstruction,
  ].join("\n");
}

export function draftContinuationPrompt(runId) {
  return [
    `ORG2_RUN_ID: ${runId}`,
    "ORG2_DRAFT_RESUME: approval-decided",
    "",
    "Continue the decided external-draft action using its existing durable run.",
    "Re-read the run with the Celorga CLI (`celorga`, or `org2` on installs that predate the rename) and resolve the exact provider-draft authority through `celorga run approval-resolve --decision-key artifact:PROVIDER:TOOL:DRAFT_ID --json`.",
    "If the draft approval was rejected or canceled, do not send it; record that exclusion and close the existing run without performing the protected action.",
    "If it was approved, send only the exact provider draft covered by the approved review material. Do not substitute a new recipient, subject, body, command, or attachment.",
    "Record either the provider send evidence or the declined-action outcome on the existing draft run.",
    backgroundThreadDeliveryInstruction,
  ].join("\n");
}

export function approvedRunContinuationPrompt(run) {
  return [
    `ORG2_RUN_ID: ${run.id}`,
    "ORG2_RUN_RESUME: approval-decided",
    "",
    `Continue the existing Celorga run \"${run.goal}\" after every item in its approval boundary was decided.`,
    "Re-read the durable run with the Celorga CLI (`celorga`, or `org2` on installs that predate the rename) and continue from the first incomplete step. Do not create a replacement run or request the same approval again.",
    "Perform only exact actions whose review material is approved. Skip every rejected or canceled action, and do not substitute a new recipient, payload, command, or attachment.",
    "For provider drafts, resolve the exact authority through `celorga run approval-resolve --decision-key artifact:PROVIDER:TOOL:DRAFT_ID --json` and verify provider state before any retry.",
    "Record external receipts and the final outcome on this durable run, or record the next specific blocker if the work cannot continue.",
    backgroundThreadDeliveryInstruction,
  ].join("\n");
}

export function workflowRevisionPrompt(workflow, runId, approval) {
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `ORG2_WORKFLOW_RUN_ID: ${runId}`,
    `ORG2_WORKFLOW_REVISION_APPROVAL_ID: ${approval.id}`,
    "ORG2_WORKFLOW_RESUME: revision-requested",
    "",
    `Revise the review material for the Celorga workflow "${workflow.title}" using its existing durable run.`,
    "Re-read the workflow and run with the Celorga CLI (`celorga`, or `org2` on installs that predate the rename). The reviewer requested changes in the approval decision note.",
    `Requested changes: ${approval.decisionNote}`,
    "Apply that feedback to new review material, preserve the prior artifact and decision as history, and request a replacement approval for the revised action.",
    "Request the replacement on ORG2_WORKFLOW_RUN_ID. Preserve the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line so the CLI can supersede the prior version and reconcile both Review and Runs.",
    "Do not perform the protected action. A revision request is not approval, and only a later approval of the replacement material may authorize it.",
    backgroundThreadDeliveryInstruction,
  ].join("\n");
}

function currentApprovalBoundary(run) {
  let boundaryStart = -1;
  for (let index = (run.events || []).length - 1; index >= 0; index -= 1) {
    const candidate = run.events[index];
    if (candidate?.type === "status-changed" && candidate.data?.to === "waiting-approval") {
      boundaryStart = index;
      break;
    }
  }
  if (boundaryStart < 0) return run.approvals || [];
  const boundaryIds = new Set(
    (run.events || []).slice(boundaryStart + 1)
      .filter((candidate) => candidate?.type === "approval-requested")
      .map((candidate) => String(candidate.data?.approvalId || "").trim())
      .filter(Boolean),
  );
  if (boundaryIds.size === 0) return run.approvals || [];
  return (run.approvals || []).filter((approval) => boundaryIds.has(approval.id));
}

function runCorrelation(run, field) {
  const prefix = `${String(field || "").trim().toUpperCase()}:`;
  for (const comment of [...(run.comments || [])].reverse()) {
    for (const line of String(comment?.body || "").split(/\r?\n/).reverse()) {
      const trimmed = line.trim();
      if (!trimmed.toUpperCase().startsWith(prefix)) continue;
      const value = trimmed.slice(prefix.length).trim();
      if (value && value.toLowerCase() !== "unknown") return value;
    }
  }
  return undefined;
}

function approvedBoundaryKey(run, boundary) {
  const material = [...boundary]
    .map((approval) => ({
      id: String(approval.id || ""),
      fingerprint: String(approval.fingerprint || ""),
      status: String(approval.status || ""),
      decidedAt: String(approval.decidedAt || ""),
    }))
    .sort((a, b) => a.id.localeCompare(b.id));
  const digest = createHash("sha256").update(JSON.stringify(material)).digest("hex");
  return `${run.id}:${digest}`;
}

function messageText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((part) => messageText(part)).filter(Boolean).join("\n");
  if (content && typeof content === "object") {
    if (typeof content.text === "string") return content.text;
    if (typeof content.content === "string" || Array.isArray(content.content)) return messageText(content.content);
  }
  return "";
}

export function executionSummary(messages, fallback = "OpenClaw execution completed successfully.") {
  const entries = Array.isArray(messages) ? [...messages].reverse() : [];
  const assistant = entries.find((message) => message?.role === "assistant" && messageText(message.content).trim());
  const text = messageText(assistant?.content).replace(/\s+/g, " ").trim();
  return (text || fallback).slice(0, 1200);
}

export function outcomeCommand(outcome, success = true) {
  if (outcome === "killed" || outcome === "reset" || outcome === "deleted") return "cancel";
  if (outcome === "error" || outcome === "timeout" || outcome === "interrupted" || success === false) return "fail";
  return "complete";
}

export function cronKey(event) {
  // runId/sessionId may appear only on `finished`; runAtMs is shared by both.
  return `cron:${event.jobId}:${String(event.runAtMs || event.runId || event.sessionId || "unknown")}`;
}

export function cronSessionKey(event, runtimeAgentId) {
  const explicit = String(event?.sessionKey || "").trim();
  if (explicit) return explicit;
  const agentId = String(runtimeAgentId || "").trim();
  const jobId = String(event?.jobId || "").trim();
  return agentId && jobId ? `agent:${agentId}:cron:${jobId}` : undefined;
}

export function cronPayloadText(payload) {
  return String(payload?.message || payload?.text || "");
}

export function clarificationContinuationPrompt(run, response) {
  return [
    `ORG2_RUN_ID: ${run.id}`,
    "ORG2_RUN_RESUME: clarification-answered",
    "",
    `Continue the existing Celorga run \"${run.goal}\" after the user's clarification.`,
    `Clarification: ${String(run.blockedReason || "Clarification requested").trim()}`,
    "User response:",
    String(response || "").trim(),
    "",
    "Re-read the durable run before acting. The response is already recorded on that run and the run is now running; do not create a replacement run.",
    "If this lifecycle run coordinates a more specific child run carrying the same clarification, record the answer on that child and resume it rather than leaving the underlying work blocked.",
    "Continue from the blocked step, preserve existing context and review boundaries, and update this durable run with the outcome or the next actionable blocker.",
    backgroundThreadDeliveryInstruction,
  ].join("\n");
}

export function shouldEnsureCronRun(event, triggered = Boolean(event.job?.trigger)) {
  // OpenClaw intentionally omits `finished` when a trigger returns fire:false,
  // so defer triggered jobs until a real execution reaches `finished`.
  // The public plugin job shape currently strips `trigger`; heartbeat names
  // remain a fail-safe if the full scheduler inventory also omits it.
  const deferred = triggered || /^Agent heartbeat:/i.test(String(event.job?.name || "").trim());
  if (event.action === "started") return !deferred;
  if (event.action === "finished") return deferred;
  return false;
}

export class Org2Lifecycle {
  constructor(options = {}) {
    this.corpusDir = options.corpusDir;
    this.stateFile = options.stateFile || join(homedir(), ".openclaw", "org2-lifecycle", "state.json");
    this.log = options.log || console;
    this.owner = options.owner || "user";
    this.exec = options.exec || this.#exec.bind(this);
    this.state = { version: 4, mappings: {}, workflowJobs: {}, drafts: {}, approvalContinuations: {} };
    this.cron = options.cron;
    this.queue = Promise.resolve();
    const syncWaitSeconds = Number(options.syncWaitSeconds);
    this.syncWaitMs = Number.isFinite(syncWaitSeconds) && syncWaitSeconds >= 0 ? syncWaitSeconds * 1000 : 180_000;
    this.syncPollMs = Number.isFinite(options.syncPollMs) && options.syncPollMs > 0 ? options.syncPollMs : 1000;
    this.sleep = options.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  /**
   * Wait until this host's copy of a run reflects the workspace's latest write.
   *
   * The Celorga app can run on a different machine than the Gateway, with the
   * corpus replicated by a file-sync tool. The app records a decision locally
   * and then asks the Gateway to continue, so the Gateway's copy can briefly
   * predate that decision. Callers pass the run's `updatedAt` as the app saw
   * it; we poll until the local copy is at least that new. Without an
   * expectation (older apps) this is a single read. Run outside `serialize`
   * so a slow sync does not stall unrelated lifecycle work.
   */
  async awaitRunSync(runId, details = {}) {
    const expected = Date.parse(String(details.expectedUpdatedAt || ""));
    if (!Number.isFinite(expected)) return undefined;
    const deadline = Date.now() + this.syncWaitMs;
    for (;;) {
      const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
      const local = Date.parse(String(run.updatedAt || ""));
      if (Number.isFinite(local) && local >= expected) return run;
      if (Date.now() >= deadline) {
        throw new Error(
          `${runId} has not synced to the OpenClaw host yet: its copy here is ${run.status}`
          + ` (updated ${run.updatedAt || "unknown"}), but Celorga recorded a change at`
          + ` ${details.expectedUpdatedAt}. Wait for corpus sync to finish, then try again.`,
        );
      }
      await this.sleep(this.syncPollMs);
    }
  }

  async init() {
    try { this.state = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.version = 4;
    this.state.mappings ||= {};
    this.state.workflowJobs ||= {};
    this.state.drafts ||= {};
    this.state.approvalContinuations ||= {};
  }

  setCron(cron) { this.cron = cron; }

  async cronHasTrigger(jobId, fallback = false) {
    if (!this.cron?.list) return fallback;
    try {
      const listed = await this.cron.list({ includeDisabled: true });
      const jobs = Array.isArray(listed) ? listed : listed?.jobs || [];
      const job = jobs.find((candidate) => candidate?.id === jobId);
      return job ? Boolean(job.trigger) : fallback;
    } catch (error) {
      this.log.warn?.(`[org2-lifecycle] could not inspect cron ${jobId}: ${error.message}`);
      return fallback;
    }
  }

  serialize(fn) {
    const next = this.queue.then(fn, fn);
    this.queue = next.catch((error) => this.log.error?.(`[org2-lifecycle] ${error.message}`));
    return next;
  }

  async #exec(args) {
    if (!this.corpusDir) throw new Error("org2-lifecycle requires plugin config corpusDir");
    const run = (executable) => execFileAsync(executable, [...args, "--dir", this.corpusDir], { maxBuffer: 2_000_000 });
    if (this.cliExecutable) return (await run(this.cliExecutable)).stdout;
    // Prefer `celorga`; hosts still on 0.8.x only have the `org2` executable.
    try {
      const { stdout } = await run("celorga");
      this.cliExecutable = "celorga";
      return stdout;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    const { stdout } = await run("org2");
    this.cliExecutable = "org2";
    return stdout;
  }

  async #save() {
    let disk = { mappings: {} };
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    this.state.mappings = { ...(disk.mappings || {}), ...(this.state.mappings || {}) };
    this.state.workflowJobs = { ...(disk.workflowJobs || {}), ...(this.state.workflowJobs || {}) };
    this.state.drafts = { ...(disk.drafts || {}), ...(this.state.drafts || {}) };
    this.state.approvalContinuations = {
      ...(disk.approvalContinuations || {}),
      ...(this.state.approvalContinuations || {}),
    };
    await mkdir(dirname(this.stateFile), { recursive: true });
    const tmp = `${this.stateFile}.${process.pid}.tmp`;
    await writeFile(tmp, `${JSON.stringify(this.state, null, 2)}\n`);
    await rename(tmp, this.stateFile);
  }

  async #sharedDraftRecord(effect) {
    let disk = {};
    try { disk = JSON.parse(await readFile(this.stateFile, "utf8")); } catch {}
    const drafts = { ...(this.state.drafts || {}), ...(disk.drafts || {}) };
    const record = drafts[effect.key]
      || Object.values(drafts).find((candidate) =>
        candidate?.provider === effect.provider && candidate?.draftId === effect.draftId);
    if (record) this.state.drafts[effect.key] = record;
    return record;
  }

  #approvalMatchesDraft(approval, effect) {
    if (!approval || approval.status !== "approved" || !effect.action) return false;
    const normalize = (value) => String(value || "")
      .replace(/\r\n/g, "\n")
      .replace(/\nContent fingerprint: [^\n]+\s*$/i, "")
      .trim();
    return normalize(approval.action || approval.note) === normalize(effect.action);
  }

  async #reconcileDraftApproval(effect, record) {
    if (record?.org2RunId) {
      const run = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
      const approval = [...(run.approvals || [])].reverse()
        .find((candidate) => this.#approvalMatchesDraft(candidate, effect));
      if (approval) return { runId: record.org2RunId, approval };
    }

    const payload = JSON.parse(await this.exec(["review", "list", "--json"]));
    const reviews = payload.reviews || payload.items || (Array.isArray(payload) ? payload : []);
    const approval = [...reviews].reverse()
      .find((candidate) => candidate.kind === "approval" && this.#approvalMatchesDraft(candidate, effect));
    if (!approval?.runId) return undefined;
    return { runId: approval.runId, approval };
  }

  async corpus() {
    return JSON.parse(await this.exec(["corpus", "show", "--json"]));
  }

  async assertCorpus(expectedCorpusId) {
    const status = await this.corpus();
    if (expectedCorpusId && status.identity?.id !== expectedCorpusId) {
      throw new Error(`Celorga corpus mismatch: Mac app selected ${expectedCorpusId}, but OpenClaw is configured for ${status.identity?.id || "an unidentified corpus"}`);
    }
    return status;
  }

  async #updateRuntime(runId, details = {}) {
    const args = ["run", "runtime", runId, "--actor", "org2-lifecycle"];
    if (details.provider) args.push("--provider", String(details.provider));
    if (details.model) args.push("--model", String(details.model));
    if (Number.isFinite(details.tokensUsed)) args.push("--tokens-used", String(details.tokensUsed));
    if (Number.isFinite(details.elapsedSeconds)) args.push("--elapsed-seconds", String(details.elapsedSeconds));
    if (args.length > 5) await this.exec(args);
  }

  async #coordination(details = {}) {
    const runtimeAgentId = String(details.runtimeAgentId || "").trim();
    const selectedAgentRef = String(details.selectedAgentRef || "").trim() || undefined;
    const selectedGoalRef = String(details.selectedGoalRef || "").trim() || undefined;
    if (!runtimeAgentId) return {
      ...(selectedAgentRef ? { agentRef: selectedAgentRef } : {}),
      ...(selectedGoalRef ? { goalRef: selectedGoalRef } : {}),
    };
    const resolved = JSON.parse(await this.exec(["agent-profile", "resolve", "--runtime", "openclaw", "--runtime-agent-id", runtimeAgentId, "--json"]));
    if (selectedAgentRef && resolved.agentRef && selectedAgentRef !== resolved.agentRef) {
      throw new Error(`selected work is assigned to ${selectedAgentRef}, but OpenClaw agent ${runtimeAgentId} resolves to ${resolved.agentRef}`);
    }
    return {
      runtimeAgentId,
      ...((selectedAgentRef || resolved.agentRef) ? { agentRef: selectedAgentRef || resolved.agentRef } : {}),
      ...((selectedGoalRef || resolved.goalRef) ? { goalRef: selectedGoalRef || resolved.goalRef } : {}),
    };
  }

  #correlationComment(key, details = {}) {
    return [
      `OPENCLAW_KEY: ${key}`,
      `OPENCLAW_KIND: ${details.kind}`,
      `OPENCLAW_SESSION: ${details.sessionKey || "unknown"}`,
      `OPENCLAW_RUN: ${details.openclawRunId || "unknown"}`,
      ...(details.runtimeAgentId ? [`OPENCLAW_AGENT_ID: ${details.runtimeAgentId}`] : []),
      ...(details.agentRef ? [`ORG2_AGENT_REF: ${details.agentRef}`] : []),
      ...(details.goalRef ? [`ORG2_GOAL_REF: ${details.goalRef}`] : []),
    ].join("\n");
  }

  async ensure(key, details) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const coordination = await this.#coordination(details);
    details = { ...details, ...coordination };
    const created = JSON.parse(await this.exec([
      "run", "create",
      "--goal", conciseGoal(details.goal),
      "--accept", details.accept || "The OpenClaw execution reaches a terminal state with its outcome recorded.",
      "--risk", details.risk || "local-draft",
      "--owner", this.owner,
      ...(details.agentRef ? ["--agent-ref", String(details.agentRef)] : []),
      ...(details.goalRef ? ["--goal-ref", String(details.goalRef)] : []),
      "--capability", "agent-context",
      "--capability", "validation",
      ...(details.context || []).flatMap((ref) => ["--context", String(ref)]),
      ...(details.provider ? ["--provider", String(details.provider)] : []),
      ...(details.model ? ["--model", String(details.model)] : []),
      "--json",
    ]));
    const id = created.run.id;
    await this.exec(["run", "comment", id, "--author", "org2-lifecycle", "--body", this.#correlationComment(key, details)]);
    await this.exec(["run", "start", id]);
    this.state.mappings[key] = {
      org2RunId: id,
      kind: details.kind,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
      provider: details.provider,
      model: details.model,
      runtimeAgentId: details.runtimeAgentId,
      agentRef: details.agentRef,
      goalRef: details.goalRef,
      createdAt: new Date().toISOString(),
    };
    await this.#save();
    return id;
  }

  async attach(key, runId, details = {}) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const coordination = await this.#coordination(details);
    let agentRef = coordination.agentRef;
    let goalRef = coordination.goalRef;
    if (agentRef || goalRef) {
      const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
      if (run.agentRef && agentRef && run.agentRef !== agentRef) {
        throw new Error(`OpenClaw agent ${coordination.runtimeAgentId} resolves to ${agentRef}, but run ${runId} is assigned to ${run.agentRef}`);
      }
      agentRef = run.agentRef || agentRef;
      goalRef = run.goalRef || goalRef;
    }
    details = { ...details, ...coordination, agentRef, goalRef, kind: details.kind || "workflow" };
    if ((agentRef || goalRef)) {
      await this.exec([
        "run", "assign", runId,
        ...(agentRef ? ["--agent-ref", String(agentRef)] : []),
        ...(goalRef ? ["--goal-ref", String(goalRef)] : []),
        "--actor", "org2-lifecycle",
      ]);
    }
    await this.exec(["run", "comment", runId, "--author", "org2-lifecycle", "--body", this.#correlationComment(key, details)]);
    if (!details.runAlreadyStarted) await this.exec(["run", "start", runId]);
    await this.#updateRuntime(runId, details);
    this.state.mappings[key] = {
      org2RunId: runId,
      kind: details.kind || "workflow",
      workflowId: details.workflowId,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
      provider: details.provider,
      model: details.model,
      runtimeAgentId: details.runtimeAgentId,
      agentRef: details.agentRef,
      goalRef: details.goalRef,
      createdAt: new Date().toISOString(),
    };
    await this.#save();
    return runId;
  }

  async prepareWorkflowRun(workflowId, inputs = {}, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const coordination = await this.#coordination(details);
    const workflow = await this.workflow(workflowId);
    if (workflow.agentRef && coordination.agentRef && workflow.agentRef !== coordination.agentRef) {
      throw new Error(`OpenClaw agent ${coordination.runtimeAgentId} resolves to ${coordination.agentRef}, but workflow ${workflowId} is assigned to ${workflow.agentRef}`);
    }
    details = {
      ...details,
      ...coordination,
      agentRef: workflow.agentRef || coordination.agentRef,
      goalRef: workflow.goalRef || coordination.goalRef,
    };
    const args = ["workflow", "run", workflowId, "--owner", this.owner, "--json"];
    if (details.agentRef) args.push("--agent-ref", String(details.agentRef));
    if (details.goalRef) args.push("--goal-ref", String(details.goalRef));
    if (details.triggerId) args.push("--trigger", String(details.triggerId));
    if (details.attemptId) args.push("--attempt-id", String(details.attemptId));
    if (details.scheduledFor) args.push("--scheduled-for", String(details.scheduledFor));
    if (details.logicalWorkId) args.push("--logical-work-id", String(details.logicalWorkId));
    for (const [name, value] of Object.entries(inputs)) args.push("--input", `${name}=${value}`);
    const created = JSON.parse(await this.exec(args));
    return {
      run: created.run,
      skipped: schemaMatches(created.schema, "org2:workflow-run-skipped:v1"),
      eligibility: created.eligibility || (created.reason ? { eligible: false, reason: created.reason } : undefined),
      workflow,
      prompt: created.run ? workflowExecutionPrompt(workflow, inputs, created.run.id, details.triggerId) : undefined,
      corpus: corpus.identity,
    };
  }

  async ensureWorkflow(key, workflowId, inputs = {}, details = {}) {
    const existing = this.state.mappings[key];
    if (existing?.org2RunId) return existing.org2RunId;
    const prepared = await this.prepareWorkflowRun(workflowId, inputs, details);
    if (!prepared.run) {
      const now = new Date().toISOString();
      this.state.mappings[key] = {
        kind: "workflow-attempt",
        workflowId,
        logicalWorkId: details.logicalWorkId || `workflow:${workflowId}`,
        attemptId: details.attemptId,
        skippedAt: now,
        skippedReason: prepared.eligibility?.reason || "workflow event gate was not eligible",
        finishedAt: now,
        outcome: "skipped",
      };
      await this.#save();
      return null;
    }
    return this.attach(key, prepared.run.id, { ...details, kind: "workflow", workflowId });
  }

  async workflow(id) {
    return JSON.parse(await this.exec(["workflow", "show", id, "--json"]));
  }

  async workflows() {
    const payload = JSON.parse(await this.exec(["workflow", "list", "--json"]));
    return payload.workflows || [];
  }

  async recordUsage(openclawRunId, usage = {}) {
    if (!openclawRunId) return;
    const mapping = Object.values(this.state.mappings).find((item) => item.openclawRunId === openclawRunId && !item.finishedAt);
    if (!mapping) return;
    const total = Number.isFinite(usage.total)
      ? usage.total
      : [usage.input, usage.output, usage.cacheRead, usage.cacheWrite]
        .reduce((sum, value) => sum + (Number.isFinite(value) ? value : 0), 0);
    if (total > 0) mapping.tokensUsed = (mapping.tokensUsed || 0) + total;
  }

  #mappingForOpenClawRun(openclawRunId, sessionKey) {
    const values = Object.values(this.state.mappings);
    return values.find((item) => openclawRunId && item.openclawRunId === openclawRunId && !item.finishedAt)
      || values.filter((item) => sessionKey && item.sessionKey === sessionKey && !item.finishedAt)
        .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
  }

  async requestDraftApproval(effect, details = {}) {
    const existing = this.state.drafts[effect.key];
    if (existing?.fingerprint === effect.fingerprint && existing?.approvalId) return existing;
    const runId = existing?.org2RunId || await this.ensure(`draft:${effect.key}`, {
      kind: "external-draft",
      goal: `Review ${effect.subject} draft to ${effect.destination}`,
      risk: "external-action",
      context: effect.context,
      sessionKey: details.sessionKey,
      openclawRunId: details.openclawRunId,
    });
    if (existing?.approvalId) {
      const previousRun = JSON.parse(await this.exec(["run", "show", existing.org2RunId, "--json"]));
      const previous = (previousRun.approvals || []).find((item) => item.id === existing.approvalId);
      if (previous?.status === "pending") {
        await this.exec(["run", "approval-decide", existing.org2RunId, existing.approvalId,
          "--decision", "revised", "--actor", "org2-lifecycle", "--note", "The external draft changed and requires renewed approval."]);
      }
    }
    const updated = JSON.parse(await this.exec([
      "run", "approval-request", runId,
      "--title", effect.title,
      "--action", effect.action,
      "--note", effect.action,
      "--risk", "external-action",
      "--role", "owner",
      "--actor", "org2-lifecycle",
      "--json",
    ]));
    const approval = [...(updated.approvals || [])].reverse().find((item) => item.status === "pending");
    if (!approval?.id) throw new Error(`Celorga did not return an approval id for draft ${effect.draftId}`);
    const record = {
      ...effect,
      org2RunId: runId,
      approvalId: approval.id,
      status: "pending",
      updatedAt: new Date().toISOString(),
    };
    this.state.drafts[effect.key] = record;
    await this.#save();
    return record;
  }

  async draftSendDecision(effect) {
    let record = await this.#sharedDraftRecord(effect);
    let approval;
    if (record?.approvalId && record?.org2RunId) {
      const run = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
      approval = (run.approvals || []).find((item) => item.id === record.approvalId);
      if (approval?.status === "approved" && this.#approvalMatchesDraft(approval, effect)) {
        return { allowed: true, record };
      }
    }

    const reconciled = await this.#reconcileDraftApproval(effect, record);
    if (!reconciled) {
      const status = approval?.status || "untracked";
      return {
        allowed: false,
        reason: record?.approvalId
          ? `External draft ${effect.draftId} is ${status} or does not match the approved Celorga content and cannot be sent.`
          : `No matching Celorga approval exists for external draft ${effect.draftId}.`,
      };
    }

    record = {
      ...(record || {}),
      ...effect,
      org2RunId: reconciled.runId,
      approvalId: reconciled.approval.id,
      status: "approved",
      updatedAt: new Date().toISOString(),
    };
    this.state.drafts[effect.key] = record;
    await this.#save();
    return { allowed: true, record };
  }

  async recordDraftSent(effect) {
    const record = await this.#sharedDraftRecord(effect);
    if (!record) return;
    await this.exec(["run", "comment", record.org2RunId, "--author", "org2-lifecycle", "--body",
      `External draft sent after approval. Provider: ${record.provider}; draft: ${record.draftId}; destination: ${record.destination}.`]);
    const run = JSON.parse(await this.exec(["run", "show", record.org2RunId, "--json"]));
    if (run.status === "running") {
      await this.exec(["run", "complete", record.org2RunId, "--actor", "org2-lifecycle", "--summary",
        `Approved external draft sent to ${record.destination}.`]);
    }
    record.status = "sent";
    record.sentAt = new Date().toISOString();
    record.updatedAt = record.sentAt;
    await this.#save();
  }

  async resumeWorkflowRun(runId, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (!run.workflowId) throw new Error(`${runId} is not a workflow run`);
    if (run.status !== "running") throw new Error(`${runId} cannot continue while ${run.status}`);
    if ((run.approvals || []).some((approval) => approval.status === "pending")) {
      throw new Error(`${runId} still has pending approvals`);
    }
    const mapping = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId && item.sessionKey)
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
    if (!mapping?.sessionKey) throw new Error(`OpenClaw session correlation is missing for ${runId}`);
    const workflow = await this.workflow(run.workflowId);
    mapping.resumedAt = new Date().toISOString();
    await this.#save();
    return {
      run,
      workflow,
      sessionKey: mapping.sessionKey,
      prompt: workflowContinuationPrompt(workflow, runId),
      corpus: corpus.identity,
    };
  }

  async resumeDraftRun(runId, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (run.workflowId) throw new Error(`${runId} is a workflow run`);
    if (run.status !== "running") throw new Error(`${runId} cannot continue while ${run.status}`);
    if ((run.approvals || []).some((approval) => approval.status === "pending")) {
      throw new Error(`${runId} still has pending approvals`);
    }
    const mapping = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId && item.sessionKey && item.kind === "external-draft")
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
    if (!mapping?.sessionKey) throw new Error(`OpenClaw external-draft session correlation is missing for ${runId}`);
    mapping.resumedAt = new Date().toISOString();
    await this.#save();
    return {
      run,
      sessionKey: mapping.sessionKey,
      prompt: draftContinuationPrompt(runId),
      corpus: corpus.identity,
    };
  }

  async resumeApprovedRun(runId, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (run.status !== "running") throw new Error(`${runId} cannot continue while ${run.status}`);
    const boundary = currentApprovalBoundary(run);
    if (boundary.length === 0) throw new Error(`${runId} has no approval boundary to continue`);
    if (boundary.some((approval) => approval.status === "pending" || approval.status === "revised")) {
      throw new Error(`${runId} current approval boundary is not fully decided`);
    }

    const mappings = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId)
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")));
    const mapping = mappings.find((item) => item.sessionKey) || mappings[0];
    const sessionKey = mapping?.sessionKey || runCorrelation(run, "OPENCLAW_SESSION");
    const recordedKind = mapping?.kind || runCorrelation(run, "OPENCLAW_KIND");
    const kind = run.workflowId
      ? "workflow"
      : recordedKind === "external-draft" ? "external-draft" : "run";
    const workflow = run.workflowId ? await this.workflow(run.workflowId) : undefined;
    const continuationKey = approvedBoundaryKey(run, boundary);
    const basePrompt = workflow
      ? workflowContinuationPrompt(workflow, runId)
      : kind === "external-draft" ? draftContinuationPrompt(runId) : approvedRunContinuationPrompt(run);
    const prompt = `${basePrompt}\nORG2_APPROVAL_CONTINUATION_KEY: ${continuationKey}`;
    const prior = this.state.approvalContinuations[continuationKey];
    if (prior) {
      return {
        run,
        ...(workflow ? { workflow } : {}),
        ...(prior.sessionKey ? { sessionKey: prior.sessionKey } : {}),
        prompt,
        kind: prior.kind || kind,
        continuationKey,
        alreadyResumed: true,
        corpus: corpus.identity,
      };
    }

    const resumedAt = new Date().toISOString();
    if (mapping) {
      mapping.resumedAt = resumedAt;
      delete mapping.pausedAt;
      delete mapping.pausedStatus;
    }
    this.state.approvalContinuations[continuationKey] = {
      runId,
      kind,
      ...(sessionKey ? { sessionKey } : {}),
      createdAt: resumedAt,
    };
    await this.#save();
    return {
      run,
      ...(workflow ? { workflow } : {}),
      ...(sessionKey ? { sessionKey } : {}),
      prompt,
      kind,
      continuationKey,
      alreadyResumed: false,
      corpus: corpus.identity,
    };
  }

  async replyAndResumeRun(runId, responseRaw, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const response = String(responseRaw || "").trim();
    if (!response) throw new Error("a clarification response is required");
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (run.status !== "blocked") throw new Error(`${runId} cannot accept a clarification while ${run.status}`);

    const mappings = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId)
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")));
    const mapping = mappings.find((item) => item.sessionKey) || mappings[0];
    const commented = JSON.parse(await this.exec([
      "run", "comment", runId,
      "--author", "Workspace user",
      "--body", response,
      "--json",
    ]));
    const resumed = JSON.parse(await this.exec([
      "run", "resume", runId,
      "--actor", "Org2Workspace",
      "--json",
    ]));
    if (mapping) {
      mapping.resumedAt = new Date().toISOString();
      delete mapping.pausedAt;
      delete mapping.pausedStatus;
      await this.#save();
    }
    return {
      run: resumed,
      ...(mapping?.sessionKey ? { sessionKey: mapping.sessionKey } : {}),
      prompt: clarificationContinuationPrompt(commented, response),
      correlated: Boolean(mapping?.sessionKey),
      corpus: corpus.identity,
    };
  }

  async resumeWorkflowRevision(runId, approvalId, details = {}) {
    const corpus = await this.assertCorpus(details.expectedCorpusId);
    const run = JSON.parse(await this.exec(["run", "show", runId, "--json"]));
    if (!run.workflowId) throw new Error(`${runId} is not a workflow run`);
    if (run.status !== "blocked") throw new Error(`${runId} cannot resume a revision while ${run.status}`);
    if ((run.approvals || []).some((approval) => approval.status === "pending")) {
      throw new Error(`${runId} still has pending approvals`);
    }
    const boundary = currentApprovalBoundary(run);
    if (boundary.some((approval) => approval.status === "rejected" || approval.status === "canceled")) {
      throw new Error(`${runId} has a rejected or canceled decision in its current approval boundary`);
    }
    const approval = boundary.find((candidate) => candidate.id === approvalId);
    if (!approval || approval.status !== "revised") {
      throw new Error(`${approvalId} is not a revision request in the current approval boundary`);
    }
    if (!String(approval.decisionNote || "").trim()) {
      throw new Error(`${approvalId} is missing requested changes`);
    }
    const mapping = Object.values(this.state.mappings)
      .filter((item) => item.org2RunId === runId && item.sessionKey)
      .sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")))[0];
    if (!mapping?.sessionKey) throw new Error(`OpenClaw session correlation is missing for ${runId}`);
    const resumed = JSON.parse(await this.exec(["run", "resume", runId, "--actor", "org2-lifecycle", "--json"]));
    const workflow = await this.workflow(run.workflowId);
    mapping.resumedAt = new Date().toISOString();
    await this.#save();
    return {
      run: resumed,
      workflow,
      sessionKey: mapping.sessionKey,
      prompt: workflowRevisionPrompt(workflow, runId, approval),
      corpus: corpus.identity,
    };
  }

  async finish(key, outcome, details = {}) {
    // Start and finish may be observed by overlapping Gateway generations
    // during a hot restart. Refresh the durable map so terminal events do not
    // depend on one process's in-memory view.
    if (!this.state.mappings[key]) {
      try {
        const disk = JSON.parse(await readFile(this.stateFile, "utf8"));
        this.state.mappings = { ...(disk.mappings || {}), ...(this.state.mappings || {}) };
      } catch {}
    }
    const mapping = this.state.mappings[key];
    if (!mapping || mapping.finishedAt) return;
    if (details.sessionKey && !mapping.sessionKey) mapping.sessionKey = details.sessionKey;
    if (details.openclawRunId && !mapping.openclawRunId) mapping.openclawRunId = details.openclawRunId;
    if (details.runtimeAgentId && !mapping.runtimeAgentId) mapping.runtimeAgentId = details.runtimeAgentId;
    await this.#updateRuntime(mapping.org2RunId, {
      provider: details.provider || mapping.provider,
      model: details.model || mapping.model,
      tokensUsed: mapping.tokensUsed,
      elapsedSeconds: Number.isFinite(details.durationMs) ? details.durationMs / 1000 : undefined,
    });
    if (details.error) {
      await this.exec(["run", "comment", mapping.org2RunId, "--author", "org2-lifecycle", "--body",
        `OpenClaw terminal error: ${String(details.error).slice(0, 1000)}`]);
    }
    const run = JSON.parse(await this.exec(["run", "show", mapping.org2RunId, "--json"]));
    const command = outcomeCommand(outcome);
    if (command === "complete"
      && !["completed", "failed", "canceled"].includes(run.status)
      && (run.artifacts || []).some((artifact) => artifact.reviewStatus === "review-required")) {
      mapping.pausedAt = new Date().toISOString();
      mapping.pausedStatus = "review-required";
      await this.#save();
      return { terminal: false, status: "review-required" };
    }
    if (command === "complete" && (run.status === "waiting-approval" || run.status === "blocked")) {
      mapping.pausedAt = new Date().toISOString();
      mapping.pausedStatus = run.status;
      await this.#save();
      return { terminal: false, status: run.status };
    }
    if (["completed", "failed", "canceled"].includes(run.status)) {
      mapping.finishedAt = new Date().toISOString();
      mapping.outcome = outcome;
      await this.#save();
      return { terminal: true, status: run.status };
    }
    const args = ["run", command, mapping.org2RunId, "--actor", "org2-lifecycle"];
    if (command === "complete") args.push("--summary", details.summary || "OpenClaw execution completed successfully.");
    if (command === "fail") args.push("--reason", String(details.error || "OpenClaw execution failed").slice(0, 1000));
    await this.exec(args);
    const finishedAt = new Date().toISOString();
    for (const item of Object.values(this.state.mappings)) {
      if (item.org2RunId !== mapping.org2RunId) continue;
      item.finishedAt = finishedAt;
      item.outcome = outcome;
    }
    await this.#save();
    return { terminal: true, status: command === "complete" ? "completed" : command === "fail" ? "failed" : "canceled" };
  }

  async interruptSession(sessionKey, reason = "unknown", details = {}) {
    if (!sessionKey) return [];
    const interrupted = [];
    for (const [key, mapping] of Object.entries(this.state.mappings)) {
      if (mapping.sessionKey !== sessionKey || mapping.finishedAt || mapping.pausedAt) continue;
      const error = `OpenClaw session ended before its durable run reached a terminal state (reason: ${reason}).`;
      const result = await this.finish(key, "interrupted", {
        ...details,
        error,
        summary: error,
      });
      if (result) interrupted.push({ key, org2RunId: mapping.org2RunId, ...result });
    }
    return interrupted;
  }

  async reconcile(expectedCorpusId) {
    await this.assertCorpus(expectedCorpusId);
    if (this.cron) await this.#reconcileWorkflowJobs();
    await this.#save();
    return this.workflowStatus();
  }

  async workflowStatus(expectedCorpusId) {
    const corpus = await this.assertCorpus(expectedCorpusId);
    const workflows = await this.workflows();
    const jobs = this.cron ? await this.cron.list({ includeDisabled: true }) : [];
    const jobsById = new Map(jobs.map((job) => [job.id, job]));
    return {
      schema: "org2:openclaw-workflow-status:v1",
      corpus: corpus.identity,
      workflows: workflows.map((workflow) => {
        const binding = this.state.workflowJobs[workflow.id];
        return { ...workflow, openclaw: binding ? { ...binding, job: jobsById.get(binding.jobId) } : undefined };
      }),
    };
  }

  async #reconcileWorkflowJobs() {
    const workflows = await this.workflows();
    const jobs = await this.cron.list({ includeDisabled: true });
    const jobsById = new Map(jobs.map((job) => [job.id, job]));
    for (const workflow of workflows) {
      const scheduleTriggers = (workflow.triggers || []).filter((item) => item.type === "schedule");
      const trigger = scheduleTriggers.find((item) => item.id === "schedule")
        || scheduleTriggers.find((item) => item.id === "openorg-schedule")
        || scheduleTriggers.find((item) => item.id === "openclaw-schedule")
        || scheduleTriggers[0];
      const desiredEnabled = workflow.state === "active" && trigger?.enabled === true && Boolean(trigger.schedule);
      let binding = this.state.workflowJobs[workflow.id];
      let job = binding?.jobId ? jobsById.get(binding.jobId) : undefined;
      if (!job) {
        job = jobs.find((item) => includesMarker(item.description, "WORKFLOW_ID", workflow.id));
        if (job) binding = this.state.workflowJobs[workflow.id] = { jobId: job.id };
      }
      if (!desiredEnabled) {
        if (job?.enabled) await this.cron.update(job.id, { enabled: false });
        continue;
      }
      const desired = {
        name: `Celorga: ${workflow.title}`,
        description: `Managed by Celorga.\nORG2_WORKFLOW_ID: ${workflow.id}\nORG2_WORKFLOW_VERSION: ${workflow.version}`,
        enabled: true,
        schedule: { kind: "cron", expr: trigger.schedule, ...(trigger.timezone ? { tz: trigger.timezone } : {}) },
        sessionTarget: "isolated",
        wakeMode: "now",
        payload: {
          kind: "agentTurn",
          message: workflowExecutionPrompt(workflow, {}, undefined, trigger.id),
          ...(workflow.model ? { model: workflow.model } : {}),
          ...(workflow.reasoningEffort ? { thinking: workflow.reasoningEffort } : {}),
        },
      };
      const fingerprint = JSON.stringify(desired);
      if (!job) {
        const created = await this.cron.add(desired);
        const jobId = created?.id || created?.job?.id;
        if (!jobId) throw new Error(`OpenClaw did not return a job id for workflow ${workflow.id}`);
        this.state.workflowJobs[workflow.id] = { jobId, fingerprint, syncedAt: new Date().toISOString() };
      } else if (binding?.fingerprint !== fingerprint || job.enabled !== true) {
        await this.cron.update(job.id, desired);
        this.state.workflowJobs[workflow.id] = { jobId: job.id, fingerprint, syncedAt: new Date().toISOString() };
      }
    }
  }
}
