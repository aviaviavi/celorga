import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { guardedDeleteFile, guardedWriteFile, readGuardedFile, type GuardedFileWriteOptions } from "./guardedFile.js";
import { safeIdentifier } from "./safeIdentifier.js";
import {
  AGENT_RUN_SCHEDULE_SLOT_STATUSES,
  createAgentRun,
  type AgentRun,
  type AgentRunApproval,
  type AgentRunPlanStep,
  type AgentRunRiskClass,
} from "./agentRun.js";
import { isOrgRecordFileName, orgRecordPath, schemaMatches, stateDir } from "./brandNames.js";

export const ORG2_WORKFLOW_SCHEMA = "org2:workflow:v1" as const;
export const WORKFLOW_SCHEDULE_TRIGGER_ID = "schedule" as const;
export const LEGACY_WORKFLOW_SCHEDULE_TRIGGER_IDS = ["openorg-schedule", "openclaw-schedule"] as const;
export const WORKFLOW_EVENT_TRIGGER_TYPES = ["capture", "meeting-import", "todo-state", "pull-request"] as const;
export const WORKFLOW_TRIGGER_TYPES = ["manual", "schedule", "file-change", ...WORKFLOW_EVENT_TRIGGER_TYPES] as const;
/**
 * Event triggers that `workflow due` dispatches from recorded signals. Their
 * signals come from deterministic detectors (`workflow observe`, `workflow
 * poll`), never from a model deciding whether work should run.
 */
export const WORKFLOW_SIGNAL_TRIGGER_TYPES = ["todo-state", "pull-request"] as const;
export type WorkflowSignalTriggerType = typeof WORKFLOW_SIGNAL_TRIGGER_TYPES[number];
export const WORKFLOW_PULL_REQUEST_EVENTS = ["opened", "commit", "review", "comment", "merged", "closed"] as const;
export type WorkflowPullRequestEvent = typeof WORKFLOW_PULL_REQUEST_EVENTS[number];
/** Longest accepted coalescing window. */
export const WORKFLOW_COALESCE_MAX_MS = 24 * 60 * 60 * 1_000;
/** How a schedule treats an earlier attempt that is blocked on a person. */
export const WORKFLOW_SCHEDULE_WHEN_BLOCKED = ["continue", "wait"] as const;
export type WorkflowScheduleWhenBlocked = typeof WORKFLOW_SCHEDULE_WHEN_BLOCKED[number];
/** How a schedule treats an earlier attempt that is still queued, running, or awaiting approval. */
export const WORKFLOW_SCHEDULE_WHEN_RUNNING = ["continue", "wait"] as const;
export type WorkflowScheduleWhenRunning = typeof WORKFLOW_SCHEDULE_WHEN_RUNNING[number];

export type AgentWorkflowState = "draft" | "active" | "paused";
export type WorkflowEventTriggerType = typeof WORKFLOW_EVENT_TRIGGER_TYPES[number];
export type WorkflowSignalType = WorkflowEventTriggerType | "file-change";
export type WorkflowTriggerType = typeof WORKFLOW_TRIGGER_TYPES[number];

/** The heading that entered a configured TODO state. */
export interface WorkflowTodoStateSignalDetail {
  file: string;
  line: number;
  headingId?: string;
  title: string;
  from: string | null;
  to: string;
  tags: string[];
}

/** One GitHub pull-request activity item observed by `workflow poll`. */
export interface WorkflowPullRequestSignalDetail {
  repo: string;
  number: number;
  event: WorkflowPullRequestEvent;
  key: string;
  title?: string;
  url?: string;
  author?: string;
  actor?: string;
  occurredAt?: string;
}

export interface WorkflowSignal {
  id: string;
  type: WorkflowSignalType;
  /** When Celorga recorded the signal; provider event times live in the detail. */
  at: string;
  paths: string[];
  /** Set when a detector matched one specific trigger's filters. */
  triggerId?: string;
  source?: string;
  todoState?: WorkflowTodoStateSignalDetail;
  pullRequest?: WorkflowPullRequestSignalDetail;
}

export interface WorkflowTriggerGate {
  events?: WorkflowSignalType[];
  paths?: string[];
}

export interface WorkflowInput {
  id: string;
  description: string;
  required: boolean;
  default?: string;
}

export interface WorkflowOutput {
  id: string;
  path: string;
  role: string;
  mediaType?: string;
}

export interface WorkflowTrigger {
  id: string;
  type: WorkflowTriggerType;
  enabled: boolean;
  schedule?: string;
  timezone?: string;
  path?: string;
  lastRunAt?: string;
  lastAttemptAt?: string;
  gate?: WorkflowTriggerGate;
  /**
   * Schedule triggers only. `continue` (the default when absent) lets the next
   * occurrence start while an earlier attempt is blocked; `wait` holds the
   * schedule until the blocked attempt is resumed, completed, or canceled.
   */
  whenBlocked?: WorkflowScheduleWhenBlocked;
  /**
   * Schedule triggers only. `continue` (the default when absent) starts each
   * occurrence even while earlier attempts are still queued, running, or
   * awaiting approval, so a hung attempt can never stall the schedule. `wait`
   * skips occurrences until the earlier attempt settles.
   */
  whenRunning?: WorkflowScheduleWhenRunning;
  /** todo-state: fire when a heading enters one of these TODO keywords. */
  states?: string[];
  /** todo-state: the heading (or an ancestor) must carry at least one of these tags. */
  tags?: string[];
  /** todo-state: corpus-relative path globs (`*`, `**`, `?`; a plain path also matches its directory). */
  paths?: string[];
  /** todo-state: a property that must be present on the heading, as NAME or NAME=VALUE. */
  property?: string;
  /** pull-request: GitHub repository as owner/name. */
  repo?: string;
  /** pull-request: activity kinds to accept; absent means all. */
  events?: WorkflowPullRequestEvent[];
  /** pull-request: limit to one pull request number. */
  number?: number;
  /** pull-request: limit to pull requests opened by this GitHub login. */
  author?: string;
  /** todo-state and pull-request: combine signals that arrive within this window (for example 5m) into one attempt. */
  coalesce?: string;
}

/**
 * Whether an existing attempt prevents a schedule trigger from starting a new
 * one. By default nothing does: overlapping attempts are allowed. Queued,
 * running, and approval-waiting attempts hold the slot only when the trigger
 * declares `whenRunning: "wait"`; a blocked attempt only when it declares
 * `whenBlocked: "wait"`.
 */
export function workflowAttemptHoldsScheduleSlot(
  run: Pick<AgentRun, "status">,
  trigger?: Pick<WorkflowTrigger, "whenBlocked" | "whenRunning">,
): boolean {
  if (AGENT_RUN_SCHEDULE_SLOT_STATUSES.has(run.status)) return trigger?.whenRunning === "wait";
  return run.status === "blocked" && trigger?.whenBlocked === "wait";
}

export interface AgentWorkflow {
  schema: typeof ORG2_WORKFLOW_SCHEMA;
  id: string;
  version: string;
  title: string;
  description: string;
  state: AgentWorkflowState;
  instructions: string;
  capabilities: string[];
  riskClass: AgentRunRiskClass;
  inputs: WorkflowInput[];
  contextRules: string[];
  steps: Array<Omit<AgentRunPlanStep, "status" | "startedAt" | "completedAt">>;
  outputs: WorkflowOutput[];
  validations: string[];
  approvals: Array<Pick<AgentRunApproval, "title" | "action" | "riskClass" | "requestedRole">>;
  triggers: WorkflowTrigger[];
  signals?: WorkflowSignal[];
  compatibility: { org2: string; schema: string };
  sourceRunId?: string;
  destinationRef?: string;
  model?: string;
  reasoningEffort?: string;
  agentRef?: string;
  goalRef?: string;
  createdAt: string;
  updatedAt: string;
}

export interface WorkflowScheduleOccurrence {
  trigger: WorkflowTrigger;
  scheduledFor: string;
}

export interface PromptAutomationInput {
  id: string;
  title: string;
  instructions: string;
  description?: string;
  destinationRef?: string;
  model?: string;
  reasoningEffort?: string;
  agentRef?: string;
  goalRef?: string;
  schedule?: string;
  timezone?: string;
  state?: AgentWorkflowState;
  now?: string;
}

export interface AgentWorkflowSnapshot {
  file: string;
  revision: string;
  raw: string;
  workflow: AgentWorkflow;
}

export type AgentWorkflowTemplate = Omit<
  AgentWorkflow,
  "schema" | "state" | "compatibility" | "createdAt" | "updatedAt"
> & {
  schema: "org2:workflow-template:v1";
};

export interface WorkflowValidationResult {
  valid: boolean;
  issues: Array<{ path: string; message: string }>;
}

function nowIso(now?: string): string {
  const value = now ? new Date(now) : new Date();
  if (Number.isNaN(value.getTime())) throw new Error(`invalid timestamp: ${now}`);
  return value.toISOString();
}

export function workflowFromRun(run: AgentRun, options: { id?: string; title?: string; version?: string; now?: string } = {}): AgentWorkflow {
  if (run.status !== "completed") throw new Error("only a completed run can be saved as a workflow");
  const now = nowIso(options.now);
  const outputs = run.artifacts.map((artifact) => ({
    id: artifact.id,
    path: artifact.path,
    role: artifact.role,
    ...(artifact.mediaType ? { mediaType: artifact.mediaType } : {}),
  }));
  const approvalKeys = new Set<string>();
  const approvals = run.approvals.flatMap((approval) => {
    const key = `${approval.action}\0${approval.riskClass}\0${approval.requestedRole || ""}`;
    if (approvalKeys.has(key)) return [];
    approvalKeys.add(key);
    return [{
      title: approval.title,
      action: approval.action,
      riskClass: approval.riskClass,
      ...(approval.requestedRole ? { requestedRole: approval.requestedRole } : {}),
    }];
  });
  return {
    schema: ORG2_WORKFLOW_SCHEMA,
    id: safeIdentifier(options.id || `workflow-${run.id}`, { invalidMessage: (raw) => `invalid workflow id: ${raw}` }),
    version: options.version || "1.0.0",
    title: options.title || run.title || run.goal,
    description: `Reusable workflow captured from run ${run.id}.`,
    state: "draft",
    instructions: run.goal,
    capabilities: [...run.capabilities],
    riskClass: run.riskClass,
    inputs: run.context.map((item, index) => ({ id: `context-${index + 1}`, description: item.title || item.ref, required: true, default: item.ref })),
    contextRules: run.context.map((item) => item.ref),
    steps: run.plan.map(({ status: _status, startedAt: _startedAt, completedAt: _completedAt, ...step }) => step),
    outputs,
    validations: run.validations.map((validation) => validation.name),
    approvals,
    triggers: [{ id: "manual", type: "manual", enabled: true }],
    compatibility: { org2: ">=0.3.0 <1", schema: ORG2_WORKFLOW_SCHEMA },
    sourceRunId: run.id,
    ...(run.destinationRef ? { destinationRef: run.destinationRef } : {}),
    ...(run.agentRef ? { agentRef: run.agentRef } : {}),
    ...(run.goalRef ? { goalRef: run.goalRef } : {}),
    createdAt: now,
    updatedAt: now,
  };
}

export function promptAutomation(input: PromptAutomationInput): AgentWorkflow {
  const now = nowIso(input.now);
  const id = safeIdentifier(input.id, { invalidMessage: (raw) => `invalid workflow id: ${raw}` });
  const title = String(input.title || "").trim();
  const instructions = String(input.instructions || "").trim();
  if (!title) throw new Error("automation title is required");
  if (!instructions) throw new Error("automation prompt is required");
  const schedule = String(input.schedule || "").trim();
  const timezone = String(input.timezone || "").trim();
  const state = input.state || (schedule ? "active" : "draft");
  const workflow: AgentWorkflow = {
    schema: ORG2_WORKFLOW_SCHEMA,
    id,
    version: "1.0.0",
    title,
    description: String(input.description || `Scheduled prompt automation for ${title}.`).trim(),
    state,
    instructions,
    capabilities: [],
    riskClass: "local-draft",
    inputs: [],
    contextRules: [],
    steps: [{ id: "execute", kind: "agent", title: "Execute the automation prompt" }],
    outputs: [],
    validations: [],
    approvals: [],
    triggers: [
      { id: "manual", type: "manual", enabled: true },
      ...(schedule ? [{
        id: WORKFLOW_SCHEDULE_TRIGGER_ID,
        type: "schedule" as const,
        enabled: true,
        schedule,
        ...(timezone ? { timezone } : {}),
      }] : []),
    ],
    compatibility: { org2: ">=0.3.0 <1", schema: ORG2_WORKFLOW_SCHEMA },
    ...(String(input.destinationRef || "").trim() ? { destinationRef: String(input.destinationRef).trim() } : {}),
    ...(String(input.model || "").trim() ? { model: String(input.model).trim() } : {}),
    ...(String(input.reasoningEffort || "").trim() ? { reasoningEffort: String(input.reasoningEffort).trim() } : {}),
    ...(String(input.agentRef || "").trim() ? { agentRef: String(input.agentRef).trim() } : {}),
    ...(String(input.goalRef || "").trim() ? { goalRef: String(input.goalRef).trim() } : {}),
    createdAt: now,
    updatedAt: now,
  };
  const validation = validateWorkflow(workflow);
  if (!validation.valid) {
    throw new Error(`invalid automation: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  }
  return workflow;
}

export function validateWorkflow(workflow: AgentWorkflow): WorkflowValidationResult {
  const issues: WorkflowValidationResult["issues"] = [];
  if (!schemaMatches(workflow.schema, ORG2_WORKFLOW_SCHEMA)) issues.push({ path: "schema", message: `must equal ${ORG2_WORKFLOW_SCHEMA}` });
  try { safeIdentifier(workflow.id, { invalidMessage: (raw) => `invalid workflow id: ${raw}` }); } catch (error) { issues.push({ path: "id", message: (error as Error).message }); }
  if (!workflow.title?.trim()) issues.push({ path: "title", message: "is required" });
  if (workflow.destinationRef !== undefined && !String(workflow.destinationRef).trim()) issues.push({ path: "destinationRef", message: "must not be empty when present" });
  if (workflow.model !== undefined && (!String(workflow.model).trim() || /[\r\n]/.test(String(workflow.model)))) {
    issues.push({ path: "model", message: "must be a non-empty single-line model identifier when present" });
  }
  if (workflow.reasoningEffort !== undefined && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(String(workflow.reasoningEffort).trim())) {
    issues.push({ path: "reasoningEffort", message: "must be a non-empty reasoning identifier when present" });
  }
  if (!["draft", "active", "paused"].includes(workflow.state || "draft")) issues.push({ path: "state", message: "must be draft, active, or paused" });
  if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(workflow.version || "")) issues.push({ path: "version", message: "must be semantic version syntax" });
  const ids = new Set<string>();
  for (const [index, step] of (workflow.steps || []).entries()) {
    if (!step.id || ids.has(step.id)) issues.push({ path: `steps[${index}].id`, message: "must be present and unique" });
    ids.add(step.id);
  }
  const triggerIds = new Set<string>();
  for (const [index, trigger] of (workflow.triggers || []).entries()) {
    try { safeIdentifier(trigger.id, { invalidMessage: (raw) => `invalid workflow id: ${raw}` }); } catch (error) { issues.push({ path: `triggers[${index}].id`, message: (error as Error).message }); }
    if (triggerIds.has(trigger.id)) issues.push({ path: `triggers[${index}].id`, message: "must be unique" });
    triggerIds.add(trigger.id);
    if (!WORKFLOW_TRIGGER_TYPES.includes(trigger.type)) issues.push({ path: `triggers[${index}].type`, message: "is not supported" });
    if (trigger.type === "schedule" && !trigger.schedule) issues.push({ path: `triggers[${index}].schedule`, message: "is required for schedule triggers" });
    if (trigger.type === "schedule" && trigger.schedule && !parseEvery(trigger.schedule) && !parseCron(trigger.schedule)) {
      issues.push({ path: `triggers[${index}].schedule`, message: "must use a positive interval such as every 15m or a five-field cron expression" });
    }
    if (trigger.type === "schedule" && trigger.timezone && !validTimeZone(trigger.timezone)) {
      issues.push({ path: `triggers[${index}].timezone`, message: "must be local or a valid IANA timezone" });
    }
    if (trigger.whenBlocked !== undefined) {
      if (trigger.type !== "schedule") issues.push({ path: `triggers[${index}].whenBlocked`, message: "applies only to schedule triggers" });
      else if (!WORKFLOW_SCHEDULE_WHEN_BLOCKED.includes(trigger.whenBlocked)) issues.push({ path: `triggers[${index}].whenBlocked`, message: "must be continue or wait" });
    }
    if (trigger.whenRunning !== undefined) {
      if (trigger.type !== "schedule") issues.push({ path: `triggers[${index}].whenRunning`, message: "applies only to schedule triggers" });
      else if (!WORKFLOW_SCHEDULE_WHEN_RUNNING.includes(trigger.whenRunning)) issues.push({ path: `triggers[${index}].whenRunning`, message: "must be continue or wait" });
    }
    if (trigger.type === "file-change" && !trigger.path) issues.push({ path: `triggers[${index}].path`, message: "is required for file-change triggers" });
    if (trigger.gate && !(trigger.gate.events?.length || trigger.gate.paths?.length)) {
      issues.push({ path: `triggers[${index}].gate`, message: "must declare at least one event or path" });
    }
    for (const event of trigger.gate?.events || []) {
      if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(event)) {
        issues.push({ path: `triggers[${index}].gate.events`, message: `unsupported event: ${event}` });
      }
    }
    issues.push(...validateEventTriggerFields(trigger, index));
  }
  for (const [index, signal] of (workflow.signals || []).entries()) {
    if (!signal.id?.trim()) issues.push({ path: `signals[${index}].id`, message: "is required" });
    if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(signal.type)) issues.push({ path: `signals[${index}].type`, message: "is not supported" });
    if (!signal.at || Number.isNaN(new Date(signal.at).getTime())) issues.push({ path: `signals[${index}].at`, message: "must be an ISO timestamp" });
  }
  return { valid: issues.length === 0, issues };
}

const TODO_KEYWORD_PATTERN = /^[\p{L}][\p{L}\p{N}_-]*$/u;
const GITHUB_REPO_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/;
const GITHUB_LOGIN_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\[bot\])?$/;

function validateEventTriggerFields(trigger: WorkflowTrigger, index: number): WorkflowValidationResult["issues"] {
  const issues: WorkflowValidationResult["issues"] = [];
  const at = (field: string) => `triggers[${index}].${field}`;
  const isTodoState = trigger.type === "todo-state";
  const isPullRequest = trigger.type === "pull-request";
  const only = (field: keyof WorkflowTrigger, type: string, allowed: boolean) => {
    if (trigger[field] !== undefined && !allowed) issues.push({ path: at(field), message: `applies only to ${type} triggers` });
  };
  only("states", "todo-state", isTodoState);
  only("tags", "todo-state", isTodoState);
  only("paths", "todo-state", isTodoState);
  only("property", "todo-state", isTodoState);
  only("repo", "pull-request", isPullRequest);
  only("events", "pull-request", isPullRequest);
  only("number", "pull-request", isPullRequest);
  only("author", "pull-request", isPullRequest);
  only("coalesce", "todo-state and pull-request", isTodoState || isPullRequest);
  if (isTodoState) {
    if (!Array.isArray(trigger.states) || trigger.states.length === 0) {
      issues.push({ path: at("states"), message: "must list at least one TODO keyword for todo-state triggers, such as [\"NEXT\"]" });
    } else {
      for (const state of trigger.states) {
        if (typeof state !== "string" || !TODO_KEYWORD_PATTERN.test(state)) issues.push({ path: at("states"), message: `invalid TODO keyword: ${String(state)}` });
      }
    }
    if (trigger.tags !== undefined && (!Array.isArray(trigger.tags) || trigger.tags.some((tag) => typeof tag !== "string" || !/^[\p{L}\p{N}_@#%]+$/u.test(tag)))) {
      issues.push({ path: at("tags"), message: "must be a list of Org tag names without colons" });
    }
    if (trigger.paths !== undefined && (!Array.isArray(trigger.paths) || trigger.paths.some((item) => typeof item !== "string" || !item.trim() || item.startsWith("/") || item.split("/").includes("..")))) {
      issues.push({ path: at("paths"), message: "must be a list of corpus-relative path globs" });
    }
    if (trigger.property !== undefined && !/^[A-Za-z][A-Za-z0-9_-]*(?:=.*)?$/.test(String(trigger.property))) {
      issues.push({ path: at("property"), message: "must be a property NAME or NAME=VALUE, such as AGENT_REF" });
    }
  }
  if (isPullRequest) {
    if (!trigger.repo || !GITHUB_REPO_PATTERN.test(trigger.repo)) issues.push({ path: at("repo"), message: "must be a GitHub repository as owner/name for pull-request triggers" });
    if (trigger.events !== undefined) {
      if (!Array.isArray(trigger.events) || trigger.events.length === 0) issues.push({ path: at("events"), message: `must list at least one of ${WORKFLOW_PULL_REQUEST_EVENTS.join(", ")} when present` });
      else for (const event of trigger.events) {
        if (!WORKFLOW_PULL_REQUEST_EVENTS.includes(event)) issues.push({ path: at("events"), message: `unsupported pull-request event: ${String(event)}; use ${WORKFLOW_PULL_REQUEST_EVENTS.join(", ")}` });
      }
    }
    if (trigger.number !== undefined && (!Number.isSafeInteger(trigger.number) || trigger.number < 1)) issues.push({ path: at("number"), message: "must be a positive pull request number" });
    if (trigger.author !== undefined && !GITHUB_LOGIN_PATTERN.test(String(trigger.author))) issues.push({ path: at("author"), message: "must be a GitHub login" });
  }
  if (trigger.coalesce !== undefined && parseCoalesce(trigger.coalesce) === null) {
    issues.push({ path: at("coalesce"), message: "must be a duration such as 30s, 5m, or 1h, at most 24h" });
  }
  return issues;
}

/** Parses a coalescing window such as `30s`, `5m`, or `1h` into milliseconds. */
export function parseCoalesce(raw: string | undefined): number | null {
  const match = String(raw ?? "").trim().match(/^(\d+)\s*(s|m|h)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  const unit = match[2]!.toLowerCase();
  const ms = amount * (unit === "s" ? 1_000 : unit === "m" ? 60_000 : 3_600_000);
  return Number.isSafeInteger(amount) && ms >= 0 && ms <= WORKFLOW_COALESCE_MAX_MS ? ms : null;
}

export function isSignalTrigger(trigger: Pick<WorkflowTrigger, "type">): trigger is WorkflowTrigger & { type: WorkflowSignalTriggerType } {
  return (WORKFLOW_SIGNAL_TRIGGER_TYPES as readonly string[]).includes(trigger.type);
}

function applyTemplate(value: string, inputs: Record<string, string>): string {
  return value.replace(/\{\{\s*([A-Za-z0-9._-]+)\s*\}\}/g, (_match, name: string) => inputs[name] ?? `{{${name}}}`);
}

export function instantiateWorkflow(workflow: AgentWorkflow, inputs: Record<string, string>, options: {
  owner?: string;
  assignee?: string;
  agentRef?: string;
  goalRef?: string;
  now?: string;
  logicalWorkId?: string;
  attempt?: AgentRun["attempt"];
  /** Additional run context, such as the headings that fired a todo-state trigger. */
  context?: Array<{ ref: string; title?: string; citation?: string }>;
} = {}): AgentRun {
  const missing = workflow.inputs.filter((input) => input.required && !(inputs[input.id] || input.default));
  if (missing.length) throw new Error(`missing required workflow inputs: ${missing.map((input) => input.id).join(", ")}`);
  const resolved = Object.fromEntries(workflow.inputs.map((input) => [input.id, inputs[input.id] ?? input.default ?? ""]));
  return createAgentRun({
    title: applyTemplate(workflow.title, resolved),
    goal: applyTemplate(workflow.instructions || workflow.title, resolved),
    acceptanceCriteria: workflow.outputs.map((output) => `Produce ${applyTemplate(output.path, resolved)}`).concat(workflow.validations.map((name) => `Pass validation: ${name}`)),
    riskClass: workflow.riskClass,
    owner: options.owner,
    assignee: options.assignee,
    agentRef: options.agentRef || workflow.agentRef,
    goalRef: options.goalRef || workflow.goalRef,
    workflowId: workflow.id,
    workflowVersion: workflow.version,
    destinationRef: workflow.destinationRef,
    capabilities: workflow.capabilities,
    context: [...workflow.contextRules.map((ref) => ({ ref: applyTemplate(ref, resolved) })), ...(options.context || [])],
    plan: workflow.steps.map((step) => ({ ...step, title: applyTemplate(step.title, resolved), detail: step.detail ? applyTemplate(step.detail, resolved) : undefined })),
    logicalWorkId: options.logicalWorkId,
    attempt: options.attempt,
    now: options.now,
  });
}

export function workflowExecutionPrompt(
  workflow: AgentWorkflow,
  run: AgentRun,
  inputs: Record<string, string> = {},
): string {
  const signals = (run.attempt?.signals || []) as unknown as WorkflowSignal[];
  return [
    `ORG2_WORKFLOW_ID: ${workflow.id}`,
    `ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `ORG2_WORKFLOW_RUN_ID: ${run.id}`,
    "ORG2_WORKFLOW_RUN_STARTED: true",
    ...(run.attempt?.triggerId ? [`ORG2_WORKFLOW_TRIGGER_ID: ${run.attempt.triggerId}`] : []),
    ...(workflow.destinationRef ? [`ORG2_AI_DESTINATION_REF: ${workflow.destinationRef}`] : []),
    ...(workflow.model ? [`ORG2_MODEL: ${workflow.model}`] : []),
    ...(workflow.reasoningEffort ? [`ORG2_REASONING_EFFORT: ${workflow.reasoningEffort}`] : []),
    `ORG2_WORKFLOW_INPUTS: ${JSON.stringify(inputs)}`,
    ...(signals.length ? [`ORG2_WORKFLOW_SIGNALS: ${JSON.stringify(signals)}`] : []),
    "",
    `Execute the Celorga automation “${workflow.title}”.`,
    "",
    "Automation prompt:",
    run.goal,
    ...workflowSignalPromptLines(signals),
    "",
    "This automation already has a durable Celorga run. Do not create a replacement run.",
    "If the Celorga CLI is available, continue this run, update its steps and artifacts as work progresses, preserve approval boundaries, and record its final outcome before completing it.",
    "If the destination cannot access Celorga tools, return the complete result in this chat; the Celorga app will retain the destination thread with the automation history.",
  ].join("\n");
}

export function workflowDirectory(root: string): string { return path.join(path.resolve(root), "workflows"); }
export function legacyWorkflowDirectory(root: string): string { return stateDir(path.resolve(root), "workflows"); }
export function workflowPath(root: string, id: string): string { return orgRecordPath(workflowDirectory(root), safeIdentifier(id, { invalidMessage: (raw) => `invalid workflow id: ${raw}` })); }

export function workflowSourcePath(root: string, id: string): string {
  const primary = workflowPath(root, id);
  if (fs.existsSync(primary)) return primary;
  const legacy = orgRecordPath(legacyWorkflowDirectory(root), safeIdentifier(id, { invalidMessage: (raw) => `invalid workflow id: ${raw}` }));
  if (fs.existsSync(legacy)) return legacy;
  return primary;
}

export function renderWorkflowOrg(workflow: AgentWorkflow): string {
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return [
    "#+TITLE: Org2 workflow package",
    `* ${workflow.title}`,
    ":PROPERTIES:",
    `:ORG2_WORKFLOW_ID: ${workflow.id}`,
    `:ORG2_WORKFLOW_VERSION: ${workflow.version}`,
    `:WORKFLOW_STATE: ${workflow.state}`,
    `:RISK_CLASS: ${workflow.riskClass}`,
    ...(workflow.agentRef ? [`:AGENT_REF: ${workflow.agentRef}`] : []),
    ...(workflow.goalRef ? [`:GOAL_REF: ${workflow.goalRef}`] : []),
    ...(workflow.destinationRef ? [`:AI_DESTINATION_REF: ${workflow.destinationRef}`] : []),
    ...(workflow.model ? [`:MODEL: ${workflow.model}`] : []),
    ...(workflow.reasoningEffort ? [`:REASONING_EFFORT: ${workflow.reasoningEffort}`] : []),
    ":END:",
    workflow.description,
    "",
    "** Instructions",
    workflow.instructions,
    "",
    "** Machine state",
    "#+begin_src json :org2-workflow",
    JSON.stringify(workflow, null, 2),
    "#+end_src",
    "",
  ].join("\n");
}

function stripDuplicatedWorkflowHeaders(description: string, id: string): string {
  let remaining = description.trim();
  // Older reads started at a document-level :END: and captured the generated
  // wrapper as prose. Only unwrap leading package headers for this workflow.
  while (true) {
    const header = remaining.match(/^#\+TITLE:[ \t]+(?:Celorga|Org2) workflow package[ \t]*\r?\n(?:[ \t]*\r?\n)*\*[ \t]+[^\r\n]+\r?\n:PROPERTIES:[ \t]*\r?\n((?::[^\r\n]*\r?\n)*?):END:[ \t]*(?:\r?\n|$)/i);
    if (!header || header[1].match(/^:(?:CELORGA|ORG2)_WORKFLOW_ID:[ \t]*(.+)\r?$/mi)?.[1]?.trim() !== id) return remaining;
    remaining = remaining.slice(header[0].length).trimStart();
  }
}

export function parseWorkflowOrg(raw: string): AgentWorkflow {
  const match = raw.match(/#\+begin_src\s+json\s+:org2-workflow\s*\r?\n([\s\S]*?)\r?\n#\+end_src/i);
  if (!match) throw new Error("workflow file is missing its :org2-workflow machine-state block");
  const parsed = JSON.parse(match[1] || "{}") as AgentWorkflow;
  const readable = raw.slice(0, match.index);
  const heading = readable.match(/^\*[ \t]+([^\r\n]+)\r?$/m);
  const headingTitle = heading?.[1]?.trim();
  const afterHeading = heading ? readable.slice(heading.index! + heading[0].length) : "";
  // The workflow's own drawer, not a file ID drawer or a drawer in its prompt,
  // defines the editable metadata and the start of the description.
  const drawer = afterHeading.match(/^\r?\n(?:[ \t]*\r?\n)*:PROPERTIES:[ \t]*\r?\n((?::[^\r\n]*\r?\n)*?):END:[ \t]*(?:\r?\n|$)/i);
  const properties = drawer?.[1] || "";
  const state = properties.match(/^:WORKFLOW_STATE:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const riskClass = properties.match(/^:RISK_CLASS:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const version = properties.match(/^:(?:CELORGA|ORG2)_WORKFLOW_VERSION:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const agentRef = properties.match(/^:AGENT_REF:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const goalRef = properties.match(/^:GOAL_REF:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const destinationRef = properties.match(/^:AI_DESTINATION_REF:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const model = properties.match(/^:MODEL:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const reasoningEffort = properties.match(/^:REASONING_EFFORT:[ \t]*(.+)\r?$/mi)?.[1]?.trim();
  const visibleDescription = drawer
    ? afterHeading.slice(drawer[0].length).match(/^([\s\S]*?)^\*\* Instructions[ \t]*\r?$/m)?.[1]?.trim()
    : undefined;
  const description = stripDuplicatedWorkflowHeaders(visibleDescription ?? parsed.description, parsed.id);
  const instructions = raw.match(/^\*\* Instructions\s*\r?\n([\s\S]*?)\r?\n\*\* Machine state\s*$/m)?.[1]?.trim();
  // The readable Org fields are authoring fields, not a decorative copy. The
  // machine block carries the complete portable schema; editing these visible
  // fields in any text editor overrides their corresponding machine values and
  // the next structured save writes the normalized definition back out.
  const workflow = {
    ...parsed,
    ...(headingTitle ? { title: headingTitle } : {}),
    description,
    // Older step-based workflows have no prompt. Keep the required wire field
    // present so native clients can decode the complete workflow list.
    instructions: instructions ?? parsed.instructions ?? "",
    ...(version ? { version } : {}),
    ...(agentRef ? { agentRef } : {}),
    ...(goalRef ? { goalRef } : {}),
    ...(destinationRef ? { destinationRef } : {}),
    ...(model ? { model } : {}),
    ...(reasoningEffort ? { reasoningEffort } : {}),
    ...(riskClass ? { riskClass: riskClass as AgentRunRiskClass } : {}),
    state: (state || parsed.state || "draft") as AgentWorkflowState,
  };
  const validation = validateWorkflow(workflow);
  if (!validation.valid) throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return workflow;
}

export function saveWorkflow(
  root: string,
  workflow: AgentWorkflow,
  options: GuardedFileWriteOptions = {},
): string {
  const target = workflowPath(root, workflow.id);
  const source = workflowSourcePath(root, workflow.id);
  const snapshot = fs.existsSync(source) ? readGuardedFile(source) : undefined;
  const rendered = renderWorkflowOrg(workflow);
  // Keep document identity and other file-level metadata across structured
  // saves. They belong to the source document, not the portable workflow JSON.
  const preamble = snapshot?.content.match(/^[\s\S]*?(?=^\*[ \t]+\S)/m)?.[0];
  const content = preamble === undefined ? rendered : preamble + rendered.slice(rendered.indexOf("\n") + 1);
  return guardedWriteFile(target, content, {
    expectedRevision: options.expectedRevision !== undefined
      ? options.expectedRevision
      : snapshot?.file === target ? snapshot.revision : null,
  }).file;
}

export function installBuiltinWorkflow(root: string, template: AgentWorkflowTemplate): string {
  const now = new Date().toISOString();
  return saveWorkflow(root, {
    ...template,
    schema: ORG2_WORKFLOW_SCHEMA,
    state: "draft",
    compatibility: { org2: ">=0.3.0 <1", schema: ORG2_WORKFLOW_SCHEMA },
    createdAt: now,
    updatedAt: now,
  }, { expectedRevision: null });
}

export function loadWorkflow(root: string, id: string): AgentWorkflow {
  return loadWorkflowSnapshot(root, id).workflow;
}

export function loadWorkflowSnapshot(root: string, id: string): AgentWorkflowSnapshot {
  const snapshot = readGuardedFile(workflowSourcePath(root, id));
  return {
    file: snapshot.file,
    revision: snapshot.revision,
    raw: snapshot.content,
    workflow: parseWorkflowOrg(snapshot.content),
  };
}

export function listWorkflows(root: string): AgentWorkflow[] {
  const byID = new Map<string, AgentWorkflow>();
  // Load the legacy directory first so a visible top-level workflow wins when
  // both locations contain the same id during migration.
  for (const dir of [legacyWorkflowDirectory(root), workflowDirectory(root)]) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir).filter((item) => isOrgRecordFileName(item) && !/\.sync-conflict-/i.test(item))) {
      try {
        const workflow = parseWorkflowOrg(fs.readFileSync(path.join(dir, name), "utf8"));
        byID.set(workflow.id, workflow);
      } catch {}
    }
  }
  return [...byID.values()].sort((a, b) => a.id.localeCompare(b.id));
}

export function deleteWorkflow(
  root: string,
  id: string,
  options: { apply?: boolean } = {},
): { id: string; files: string[]; applied: boolean } {
  const safeID = safeIdentifier(id, {
    invalidMessage: (raw) => `invalid workflow id: ${raw}`,
  });
  const files = [
    workflowPath(root, safeID),
    orgRecordPath(legacyWorkflowDirectory(root), safeID),
  ].filter((file, index, candidates) =>
    candidates.indexOf(file) === index && fs.existsSync(file)
  );
  if (files.length === 0) throw new Error(`workflow not found: ${safeID}`);

  const snapshots = files.map(readGuardedFile);
  for (const snapshot of snapshots) {
    const workflow = parseWorkflowOrg(snapshot.content);
    if (workflow.id !== safeID) {
      throw new Error(`workflow source id mismatch: expected ${safeID}, found ${workflow.id}: ${snapshot.file}`);
    }
  }
  if (options.apply) {
    for (const snapshot of snapshots) {
      guardedDeleteFile(snapshot.file, { expectedRevision: snapshot.revision });
    }
  }
  return { id: safeID, files, applied: options.apply === true };
}

export function updateWorkflow(
  root: string,
  id: string,
  update: (workflow: AgentWorkflow) => AgentWorkflow,
  now?: string,
): { workflow: AgentWorkflow; file: string } {
  const snapshot = loadWorkflowSnapshot(root, id);
  const workflow = update(snapshot.workflow);
  workflow.updatedAt = nowIso(now);
  const validation = validateWorkflow(workflow);
  if (!validation.valid) {
    throw new Error(`invalid workflow: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  }
  const target = workflowPath(root, workflow.id);
  if (path.resolve(snapshot.file) !== path.resolve(target)) {
    const current = readGuardedFile(snapshot.file);
    if (current.revision !== snapshot.revision) throw new Error(`workflow changed after it was read: ${snapshot.file}`);
  }
  return {
    workflow,
    file: saveWorkflow(root, workflow, {
      expectedRevision: path.resolve(snapshot.file) === path.resolve(target) ? snapshot.revision : null,
    }),
  };
}

export function migrateLegacyWorkflows(root: string): Array<{ id: string; from: string; to: string; skipped: boolean }> {
  const legacy = legacyWorkflowDirectory(root);
  if (!fs.existsSync(legacy)) return [];
  const results: Array<{ id: string; from: string; to: string; skipped: boolean }> = [];
  for (const name of fs.readdirSync(legacy).filter((item) => isOrgRecordFileName(item))) {
    const from = path.join(legacy, name);
    let workflow: AgentWorkflow;
    try { workflow = parseWorkflowOrg(fs.readFileSync(from, "utf8")); } catch { continue; }
    const to = workflowPath(root, workflow.id);
    if (fs.existsSync(to)) {
      results.push({ id: workflow.id, from, to, skipped: true });
      continue;
    }
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.renameSync(from, to);
    results.push({ id: workflow.id, from, to, skipped: false });
  }
  return results;
}

export function parseEvery(raw: string): number | null {
  const match = raw.trim().match(/^every\s+(\d+)\s*(m|h|d)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  if (!Number.isSafeInteger(amount) || amount < 1) return null;
  return amount * (match[2]?.toLowerCase() === "m" ? 60_000 : match[2]?.toLowerCase() === "h" ? 3_600_000 : 86_400_000);
}

interface ParsedCronField {
  values: Set<number>;
  wildcard: boolean;
}

interface ParsedCron {
  minute: ParsedCronField;
  hour: ParsedCronField;
  dayOfMonth: ParsedCronField;
  month: ParsedCronField;
  dayOfWeek: ParsedCronField;
}

function parseCronField(raw: string, minimum: number, maximum: number, normalize?: (value: number) => number): ParsedCronField | null {
  const source = raw.trim();
  if (!source) return null;
  const values = new Set<number>();
  for (const segment of source.split(",")) {
    const parts = segment.split("/");
    if (parts.length > 2) return null;
    const base = parts[0] || "";
    const step = parts[1] === undefined ? 1 : Number(parts[1]);
    if (!Number.isSafeInteger(step) || step < 1) return null;
    let start: number;
    let end: number;
    if (base === "*") {
      start = minimum;
      end = maximum;
    } else if (base.includes("-")) {
      const range = base.split("-");
      if (range.length !== 2) return null;
      start = Number(range[0]);
      end = Number(range[1]);
    } else {
      start = Number(base);
      end = start;
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)
      || start < minimum || end > maximum || start > end) return null;
    for (let value = start; value <= end; value += step) values.add(normalize ? normalize(value) : value);
  }
  return values.size ? { values, wildcard: source.startsWith("*") } : null;
}

function parseCron(raw: string): ParsedCron | null {
  const fields = raw.trim().split(/\s+/);
  if (fields.length !== 5) return null;
  const minute = parseCronField(fields[0] || "", 0, 59);
  const hour = parseCronField(fields[1] || "", 0, 23);
  const dayOfMonth = parseCronField(fields[2] || "", 1, 31);
  const month = parseCronField(fields[3] || "", 1, 12);
  const dayOfWeek = parseCronField(fields[4] || "", 0, 7, (value) => value === 7 ? 0 : value);
  return minute && hour && dayOfMonth && month && dayOfWeek
    ? { minute, hour, dayOfMonth, month, dayOfWeek }
    : null;
}

function validTimeZone(raw: string): boolean {
  const timezone = raw.trim();
  if (!timezone || timezone.toLowerCase() === "local") return true;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone }).format(new Date());
    return true;
  } catch {
    return false;
  }
}

function scheduleTimeZone(raw?: string): string {
  const timezone = String(raw || "").trim();
  if (!timezone || timezone.toLowerCase() === "local") {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  }
  return timezone;
}

const WEEKDAY_INDEX: Record<string, number> = {
  Sun: 0,
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
};

function cronMatches(date: Date, schedule: ParsedCron, formatter: Intl.DateTimeFormat): boolean {
  const parts = Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
  const minute = Number(parts.minute);
  const hour = Number(parts.hour);
  const dayOfMonth = Number(parts.day);
  const month = Number(parts.month);
  const dayOfWeek = WEEKDAY_INDEX[parts.weekday || ""];
  if (![minute, hour, dayOfMonth, month, dayOfWeek].every(Number.isFinite)) return false;
  if (!schedule.minute.values.has(minute) || !schedule.hour.values.has(hour) || !schedule.month.values.has(month)) return false;
  const dayOfMonthMatches = schedule.dayOfMonth.values.has(dayOfMonth);
  const dayOfWeekMatches = schedule.dayOfWeek.values.has(dayOfWeek!);
  if (schedule.dayOfMonth.wildcard && schedule.dayOfWeek.wildcard) return true;
  if (schedule.dayOfMonth.wildcard) return dayOfWeekMatches;
  if (schedule.dayOfWeek.wildcard) return dayOfMonthMatches;
  return dayOfMonthMatches || dayOfWeekMatches;
}

function scheduleBoundary(workflow: AgentWorkflow, trigger: WorkflowTrigger): number {
  const raw = trigger.lastAttemptAt || trigger.lastRunAt || workflow.updatedAt || workflow.createdAt;
  const parsed = new Date(raw).getTime();
  return Number.isFinite(parsed) ? parsed : 0;
}

export function workflowScheduleOccurrence(
  workflow: AgentWorkflow,
  trigger: WorkflowTrigger,
  nowRaw?: string,
): WorkflowScheduleOccurrence | null {
  if (!trigger.enabled || trigger.type !== "schedule" || !trigger.schedule) return null;
  const now = new Date(nowRaw || Date.now()).getTime();
  if (!Number.isFinite(now)) throw new Error(`invalid timestamp: ${nowRaw}`);
  const boundary = scheduleBoundary(workflow, trigger);
  if (boundary >= now) return null;
  const interval = parseEvery(trigger.schedule);
  if (interval) {
    const count = Math.floor((now - boundary) / interval);
    if (count < 1) return null;
    return { trigger, scheduledFor: new Date(boundary + count * interval).toISOString() };
  }
  const cron = parseCron(trigger.schedule);
  if (!cron || !validTimeZone(trigger.timezone || "")) return null;
  const formatter = new Intl.DateTimeFormat("en-US-u-ca-gregory-nu-latn", {
    timeZone: scheduleTimeZone(trigger.timezone),
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const maximumLookback = 366 * 24 * 60 * 60 * 1_000;
  const lowerBound = Math.max(boundary, now - maximumLookback);
  for (let candidate = Math.floor(now / 60_000) * 60_000; candidate > lowerBound; candidate -= 60_000) {
    if (cronMatches(new Date(candidate), cron, formatter)) {
      return { trigger, scheduledFor: new Date(candidate).toISOString() };
    }
  }
  return null;
}

export function workflowScheduleOccurrences(workflow: AgentWorkflow, options: { now?: string } = {}): WorkflowScheduleOccurrence[] {
  return workflow.triggers.flatMap((trigger) => {
    const occurrence = workflowScheduleOccurrence(workflow, trigger, options.now);
    return occurrence && workflowTriggerEligibility(workflow, trigger.id).eligible ? [occurrence] : [];
  });
}

export function workflowScheduleTrigger(workflow: AgentWorkflow): WorkflowTrigger | undefined {
  return workflow.triggers.find((trigger) => trigger.type === "schedule" && trigger.id === WORKFLOW_SCHEDULE_TRIGGER_ID)
    || LEGACY_WORKFLOW_SCHEDULE_TRIGGER_IDS.flatMap((id) => workflow.triggers.filter((trigger) => trigger.type === "schedule" && trigger.id === id))[0]
    || workflow.triggers.find((trigger) => trigger.type === "schedule");
}

export function dueWorkflowTriggers(workflow: AgentWorkflow, options: { now?: string; changedPaths?: string[]; event?: WorkflowEventTriggerType } = {}): WorkflowTrigger[] {
  return workflow.triggers.filter((trigger) => {
    if (!trigger.enabled || trigger.type === "manual") return false;
    if (trigger.type === options.event) return true;
    if (trigger.type === "file-change") return (options.changedPaths || []).some((item) => item === trigger.path || item.startsWith(`${trigger.path}/`));
    if (trigger.type === "schedule") return workflowScheduleOccurrence(workflow, trigger, options.now) !== null
      && workflowTriggerEligibility(workflow, trigger.id).eligible;
    if (isSignalTrigger(trigger)) return workflowEventTriggerWindows(workflow, trigger, { now: options.now }).some((window) => window.ready);
    return false;
  });
}

export interface RecordWorkflowSignalInput {
  id?: string;
  type: WorkflowSignalType;
  at?: string;
  paths?: string[];
  triggerId?: string;
  source?: string;
  todoState?: WorkflowTodoStateSignalDetail;
  pullRequest?: WorkflowPullRequestSignalDetail;
}

export function recordWorkflowSignal(workflow: AgentWorkflow, input: RecordWorkflowSignalInput): AgentWorkflow {
  return recordWorkflowSignals(workflow, [input]);
}

/**
 * Appends signals in one revision. A signal whose id is already recorded is
 * skipped, so deterministic detector ids make replays idempotent.
 */
export function recordWorkflowSignals(workflow: AgentWorkflow, inputs: RecordWorkflowSignalInput[]): AgentWorkflow {
  const existing = new Set((workflow.signals || []).map((signal) => signal.id));
  const added: WorkflowSignal[] = [];
  let latest = "";
  for (const input of inputs) {
    if (![...WORKFLOW_EVENT_TRIGGER_TYPES, "file-change"].includes(input.type)) throw new Error(`invalid workflow signal: ${input.type}`);
    if (input.triggerId !== undefined && !workflow.triggers.some((trigger) => trigger.id === input.triggerId)) {
      throw new Error(`workflow trigger not found: ${input.triggerId}`);
    }
    const at = nowIso(input.at);
    const id = safeIdentifier(input.id || crypto.randomUUID(), { invalidMessage: (raw) => `invalid workflow id: ${raw}` });
    if (existing.has(id)) continue;
    existing.add(id);
    added.push({
      id,
      type: input.type,
      at,
      paths: Array.from(new Set((input.paths || []).map((item) => item.trim()).filter(Boolean))),
      ...(input.triggerId ? { triggerId: input.triggerId } : {}),
      ...(input.source ? { source: input.source } : {}),
      ...(input.todoState ? { todoState: input.todoState } : {}),
      ...(input.pullRequest ? { pullRequest: input.pullRequest } : {}),
    });
    if (at > latest) latest = at;
  }
  if (!added.length) return workflow;
  return {
    ...workflow,
    signals: [...(workflow.signals || []), ...added],
    updatedAt: latest,
  };
}

/** Whether a recorded signal belongs to a todo-state or pull-request trigger. */
export function signalMatchesEventTrigger(signal: WorkflowSignal, trigger: WorkflowTrigger): boolean {
  if (signal.triggerId) return signal.triggerId === trigger.id;
  return signal.type === trigger.type;
}

function eventTriggerBoundary(trigger: WorkflowTrigger): number {
  const parsed = new Date(trigger.lastAttemptAt || trigger.lastRunAt || 0).getTime();
  return Number.isFinite(parsed) ? parsed : 0;
}

export interface WorkflowEventTriggerWindow {
  /** The planned attempt time: the first signal plus the coalescing window. */
  scheduledFor: string;
  /** False while the coalescing window is still open. */
  ready: boolean;
  signals: WorkflowSignal[];
}

/**
 * Groups the pending signals of a todo-state or pull-request trigger into
 * attempt windows. A window opens at its first signal and closes after the
 * trigger's `coalesce` duration (immediately when absent); every pending
 * signal recorded at or before the close joins that one attempt.
 */
export function workflowEventTriggerWindows(
  workflow: AgentWorkflow,
  trigger: WorkflowTrigger,
  options: { now?: string; until?: string } = {},
): WorkflowEventTriggerWindow[] {
  if (!trigger.enabled || !isSignalTrigger(trigger)) return [];
  const now = new Date(options.now || Date.now()).getTime();
  if (!Number.isFinite(now)) throw new Error(`invalid timestamp: ${options.now}`);
  const until = options.until === undefined ? Number.POSITIVE_INFINITY : new Date(options.until).getTime();
  if (Number.isNaN(until)) throw new Error(`invalid timestamp: ${options.until}`);
  const boundary = eventTriggerBoundary(trigger);
  const window = parseCoalesce(trigger.coalesce) ?? 0;
  const pending = (workflow.signals || [])
    .map((signal) => ({ signal, at: new Date(signal.at).getTime() }))
    .filter((item) => Number.isFinite(item.at) && item.at > boundary && item.at <= until && signalMatchesEventTrigger(item.signal, trigger))
    .sort((a, b) => a.at - b.at || a.signal.id.localeCompare(b.signal.id));
  const windows: WorkflowEventTriggerWindow[] = [];
  let index = 0;
  while (index < pending.length) {
    const close = pending[index]!.at + window;
    const signals: WorkflowSignal[] = [];
    while (index < pending.length && pending[index]!.at <= close) signals.push(pending[index++]!.signal);
    windows.push({ scheduledFor: new Date(close).toISOString(), ready: close <= now, signals });
  }
  return windows;
}

export function workflowTriggerEligibility(
  workflow: AgentWorkflow,
  triggerId: string,
  options: { now?: string; until?: string } = {},
): { eligible: boolean; reason: string; signalIds: string[]; scheduledFor?: string } {
  const trigger = workflow.triggers.find((item) => item.id === triggerId);
  if (!trigger) throw new Error(`workflow trigger not found: ${triggerId}`);
  if (!trigger.enabled) return { eligible: false, reason: "trigger is disabled", signalIds: [] };
  if (isSignalTrigger(trigger)) {
    const windows = workflowEventTriggerWindows(workflow, trigger, options);
    const [first] = windows;
    if (!first) return { eligible: false, reason: `no ${trigger.type} signal arrived after the previous attempt`, signalIds: [] };
    // An explicit planned time closes the attempt there: every pending signal
    // up to it is consumed together. Otherwise the first window must close.
    const signalIds = (options.until === undefined ? first.signals : windows.flatMap((item) => item.signals)).map((item) => item.id);
    const plural = signalIds.length === 1 ? "" : "s";
    if (!first.ready && options.until === undefined) {
      return { eligible: false, reason: `coalescing ${signalIds.length} ${trigger.type} signal${plural} until ${first.scheduledFor}`, signalIds, scheduledFor: first.scheduledFor };
    }
    return { eligible: true, reason: `${signalIds.length} ${trigger.type} signal${plural} combined`, signalIds, scheduledFor: options.until === undefined ? first.scheduledFor : new Date(options.until).toISOString() };
  }
  if (!trigger.gate) return { eligible: true, reason: "trigger has no event gate", signalIds: [] };
  const boundary = new Date(trigger.lastAttemptAt || trigger.lastRunAt || 0).getTime();
  const matching = (workflow.signals || []).filter((signal) => {
    const at = new Date(signal.at).getTime();
    if (!Number.isFinite(at) || at <= boundary) return false;
    const eventMatches = !trigger.gate?.events?.length || trigger.gate.events.includes(signal.type);
    const pathMatches = !trigger.gate?.paths?.length || signal.paths.some((candidate) =>
      trigger.gate!.paths!.some((expected) => candidate === expected || candidate.startsWith(`${expected}/`))
    );
    return eventMatches && pathMatches;
  });
  return matching.length
    ? { eligible: true, reason: `${matching.length} fresh signal${matching.length === 1 ? "" : "s"} matched`, signalIds: matching.map((item) => item.id) }
    : { eligible: false, reason: "no matching event or fresh-work signal arrived after the previous attempt", signalIds: [] };
}

export function markWorkflowTriggerAttempt(workflow: AgentWorkflow, triggerId: string, atRaw?: string): AgentWorkflow {
  const at = nowIso(atRaw);
  let found = false;
  const triggers = workflow.triggers.map((trigger) => {
    if (trigger.id !== triggerId) return trigger;
    found = true;
    return { ...trigger, lastAttemptAt: at, lastRunAt: at };
  });
  if (!found) throw new Error(`workflow trigger not found: ${triggerId}`);
  // Detector signals addressed to this trigger are consumed by the attempt,
  // which keeps a copy; prune them so polling cannot grow the file forever.
  const atMs = new Date(at).getTime();
  const signals = workflow.signals?.filter((signal) =>
    !(signal.triggerId === triggerId && new Date(signal.at).getTime() <= atMs));
  return {
    ...workflow,
    triggers,
    ...(workflow.signals ? { signals } : {}),
    updatedAt: at,
  };
}

/** Summaries of signals carried into a run attempt and its prompt. */
export function workflowSignalsById(workflow: AgentWorkflow, ids: readonly string[]): WorkflowSignal[] {
  const byId = new Map((workflow.signals || []).map((signal) => [signal.id, signal]));
  return ids.flatMap((id) => byId.get(id) ? [byId.get(id)!] : []);
}

function describeWorkflowSignal(signal: WorkflowSignal): string {
  if (signal.todoState) {
    const item = signal.todoState;
    return `- ${item.file}:${item.line} “${item.title}” entered ${item.to}${item.from ? ` from ${item.from}` : ""}${item.headingId ? ` (ID ${item.headingId})` : ""}`;
  }
  if (signal.pullRequest) {
    const item = signal.pullRequest;
    return `- ${item.repo}#${item.number} ${item.event}${item.actor ? ` by ${item.actor}` : ""}${item.title ? ` — ${item.title}` : ""}${item.url ? ` ${item.url}` : ""}`;
  }
  return `- ${signal.type} at ${signal.at}${signal.paths.length ? ` (${signal.paths.join(", ")})` : ""}`;
}

/** Readable trigger evidence appended to an event-triggered attempt's prompt. */
export function workflowSignalPromptLines(signals: readonly WorkflowSignal[]): string[] {
  if (!signals.length) return [];
  return [
    "",
    `Trigger events (${signals.length}):`,
    ...signals.map(describeWorkflowSignal),
  ];
}

/** Context references for event-triggered attempts, so the run cites its input headings. */
export function workflowSignalContext(signals: readonly WorkflowSignal[]): Array<{ ref: string; title?: string; citation?: string }> {
  const seen = new Set<string>();
  return signals.flatMap((signal) => {
    const item = signal.todoState;
    if (!item) return [];
    const ref = item.headingId ? `id:${item.headingId}` : `${item.file}::${item.line}`;
    if (seen.has(ref)) return [];
    seen.add(ref);
    return [{ ref, title: item.title, citation: `${item.file}:${item.line}` }];
  });
}

export function packagedWorkflowManifest(workflow: AgentWorkflow): Record<string, unknown> {
  return {
    schema: "org2:workflow-package:v1",
    id: workflow.id,
    version: workflow.version,
    title: workflow.title,
    state: workflow.state,
    compatibility: workflow.compatibility,
    capabilities: workflow.capabilities,
    riskClass: workflow.riskClass,
    destinationRef: workflow.destinationRef,
    model: workflow.model,
    reasoningEffort: workflow.reasoningEffort,
    inputs: workflow.inputs,
    outputs: workflow.outputs,
    approvals: workflow.approvals,
  };
}

export function packagedCorpusTemplate(workflow: AgentWorkflow): Record<string, unknown> {
  return {
    schema: "org2:corpus-template:v1",
    id: `${workflow.id}-workspace`,
    version: workflow.version,
    compatibility: workflow.compatibility,
    directories: ["notes", "raw", "views", "compiled", "workflows", ".org2/runs"],
    starterFiles: [
      { path: "inbox.org", content: "#+TITLE: Inbox\n\n* Inbox\n" },
      { path: "notes/welcome.org", content: `#+TITLE: ${workflow.title}\n\nThis workspace includes the ${workflow.id} workflow.\n` },
    ],
    workflows: [packagedWorkflowManifest(workflow)],
  };
}
