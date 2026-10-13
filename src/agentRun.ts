import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  guardedWriteFile,
  readGuardedFile,
  type GuardedFileWriteOptions,
} from "./guardedFile.js";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { defaultRunApprovalIndexPath } from "./indexPaths.js";
import { safeIdentifier } from "./safeIdentifier.js";
import { brandProperty, schemaMatches, stateDir } from "./brandNames.js";

export const ORG2_AGENT_RUN_SCHEMA = "org2:agent-run:v1" as const;
export const AGENT_RUN_TITLE_MAX_LENGTH = 120;

export const AGENT_RUN_STATUSES = [
  "queued",
  "running",
  "waiting-approval",
  "blocked",
  "completed",
  "failed",
  "canceled",
] as const;

export const AGENT_RUN_RISK_CLASSES = [
  "read-only",
  "local-draft",
  "canonical-write",
  "external-action",
  "high-impact",
] as const;

export const AGENT_RUN_STEP_KINDS = [
  "compiler",
  "agent",
  "tool",
  "approval",
  "artifact",
  "validation",
] as const;

export const AGENT_RUN_STEP_STATUSES = [
  "pending",
  "running",
  "completed",
  "blocked",
  "failed",
  "skipped",
] as const;

export const AGENT_RUN_ARTIFACT_ROLES = [
  "draft",
  "diff",
  "compiled",
  "view",
  "report",
  "export",
  "receipt",
] as const;

export const AGENT_RUN_ARTIFACT_REVIEW_STATUSES = [
  "generated",
  "review-required",
  "reviewed",
  "promoted",
  "rejected",
] as const;

export const AGENT_RUN_APPROVAL_DECISIONS = [
  "approved",
  "rejected",
  "revised",
  "canceled",
] as const;

export const AGENT_RUN_APPROVAL_BLOCK_REASON = "One or more approvals were not approved";

export const AGENT_RUN_VALIDATION_STATUSES = [
  "passed",
  "failed",
  "warning",
  "skipped",
] as const;

export type AgentRunStatus = (typeof AGENT_RUN_STATUSES)[number];
export type AgentRunRiskClass = (typeof AGENT_RUN_RISK_CLASSES)[number];
export type AgentRunStepKind = (typeof AGENT_RUN_STEP_KINDS)[number];
export type AgentRunStepStatus = (typeof AGENT_RUN_STEP_STATUSES)[number];
export type AgentRunArtifactRole = (typeof AGENT_RUN_ARTIFACT_ROLES)[number];
export type AgentRunArtifactReviewStatus = (typeof AGENT_RUN_ARTIFACT_REVIEW_STATUSES)[number];
export type AgentRunApprovalDecision = (typeof AGENT_RUN_APPROVAL_DECISIONS)[number];
export type AgentRunApprovalStatus = "pending" | AgentRunApprovalDecision;
export type AgentRunValidationStatus = (typeof AGENT_RUN_VALIDATION_STATUSES)[number];

export interface AgentRunContextRef {
  ref: string;
  title?: string;
  citation?: string;
  sha256?: string;
}

export interface AgentRunPlanStep {
  id: string;
  title: string;
  kind: AgentRunStepKind;
  status: AgentRunStepStatus;
  capability?: string;
  startedAt?: string;
  completedAt?: string;
  detail?: string;
}

export interface AgentRunArtifact {
  id: string;
  path: string;
  role: AgentRunArtifactRole;
  title?: string;
  mediaType?: string;
  sha256?: string;
  reviewStatus?: AgentRunArtifactReviewStatus;
  createdAt: string;
}

export interface AgentRunApproval {
  id: string;
  fingerprint: string;
  title: string;
  action: string;
  riskClass: AgentRunRiskClass;
  status: AgentRunApprovalStatus;
  requestedRole?: string;
  requestedFrom?: string;
  requestedAt: string;
  decidedAt?: string;
  decidedBy?: string;
  decisionNote?: string;
  note?: string;
  receipt?: string;
  /** Delivery order for interrupting channels such as walkie-talkie prompts. Absent means normal.
   * Not part of the fingerprint: urgency changes when a person is asked, not what is approved. */
  priority?: AgentRunApprovalPriority;
}

export const AGENT_RUN_APPROVAL_PRIORITIES = ["normal", "urgent"] as const;
export type AgentRunApprovalPriority = typeof AGENT_RUN_APPROVAL_PRIORITIES[number];

export interface AgentRunAttempt {
  id: string;
  number: number;
  triggerId?: string;
  triggerType?: string;
  scheduledFor?: string;
  signalIds?: string[];
}

export interface AgentRunValidation {
  id: string;
  name: string;
  status: AgentRunValidationStatus;
  checkedAt: string;
  detail?: string;
}

export interface AgentRunComment {
  id: string;
  author: string;
  body: string;
  createdAt: string;
}

export interface AgentRunEvent {
  id: string;
  type: string;
  at: string;
  actor?: string;
  detail?: string;
  data?: Record<string, unknown>;
}

export interface AgentRunBudget {
  tokenLimit?: number;
  costLimitUsd?: number;
  timeLimitSeconds?: number;
  tokensUsed?: number;
  costUsedUsd?: number;
  elapsedSeconds?: number;
}

export interface AgentRunOutcome {
  summary: string;
  highlights: string[];
  nextActions: string[];
}

export interface AgentRun {
  schema: typeof ORG2_AGENT_RUN_SCHEMA;
  id: string;
  title?: string;
  goal: string;
  acceptanceCriteria: string[];
  status: AgentRunStatus;
  riskClass: AgentRunRiskClass;
  owner?: string;
  assignee?: string;
  agentRef?: string;
  goalRef?: string;
  workflowId?: string;
  workflowVersion?: string;
  destinationRef?: string;
  providerPolicy?: string;
  provider?: string;
  model?: string;
  capabilities: string[];
  context: AgentRunContextRef[];
  plan: AgentRunPlanStep[];
  artifacts: AgentRunArtifact[];
  approvals: AgentRunApproval[];
  validations: AgentRunValidation[];
  comments: AgentRunComment[];
  events: AgentRunEvent[];
  outcome?: AgentRunOutcome;
  budget?: AgentRunBudget;
  logicalWorkId?: string;
  attempt?: AgentRunAttempt;
  parentRunId?: string;
  forkedFromEventId?: string;
  createdAt: string;
  updatedAt: string;
  startedAt?: string;
  completedAt?: string;
  blockedReason?: string;
  failure?: string;
}

export interface AgentRunCreateInput {
  id?: string;
  title?: string;
  goal: string;
  acceptanceCriteria?: string[];
  status?: AgentRunStatus;
  riskClass?: AgentRunRiskClass;
  owner?: string;
  assignee?: string;
  agentRef?: string;
  goalRef?: string;
  workflowId?: string;
  workflowVersion?: string;
  destinationRef?: string;
  providerPolicy?: string;
  provider?: string;
  model?: string;
  capabilities?: string[];
  context?: AgentRunContextRef[];
  plan?: Array<Omit<AgentRunPlanStep, "id" | "status"> & { id?: string; status?: AgentRunStepStatus }>;
  outcome?: Partial<AgentRunOutcome>;
  budget?: AgentRunBudget;
  logicalWorkId?: string;
  attempt?: AgentRunAttempt;
  parentRunId?: string;
  forkedFromEventId?: string;
  now?: string;
}

export interface AgentRunRuntimeUpdate {
  provider?: string;
  model?: string;
  tokensUsed?: number;
  costUsedUsd?: number;
  elapsedSeconds?: number;
  actor?: string;
  now?: string;
}

export interface AgentRunValidationIssue {
  path: string;
  message: string;
}

export interface AgentRunValidationResult {
  valid: boolean;
  issues: AgentRunValidationIssue[];
}

export interface AgentRunAttemptRollup {
  logicalWorkId: string;
  attempts: number;
  queued: number;
  running: number;
  blocked: number;
  terminal: number;
  latestRunId: string;
  latestAttemptNumber: number;
  latestStatus: AgentRunStatus;
  updatedAt: string;
}

export interface AgentRunSourceConsistencyIssue {
  field: "id" | "status" | "updatedAt" | "title" | "goal" | "approvals";
  readable?: string;
  canonical: string;
}

export interface AgentRunSnapshot {
  file: string;
  revision: string;
  raw: string;
  run: AgentRun;
  sourceIssues: AgentRunSourceConsistencyIssue[];
}

export interface SaveAgentRunOptions extends GuardedFileWriteOptions {
  rejectSourceDrift?: boolean;
}

const TRANSITIONS: Record<AgentRunStatus, readonly AgentRunStatus[]> = {
  queued: ["running", "waiting-approval", "blocked", "canceled", "failed"],
  running: ["waiting-approval", "blocked", "completed", "failed", "canceled"],
  "waiting-approval": ["running", "blocked", "completed", "failed", "canceled"],
  blocked: ["queued", "running", "waiting-approval", "failed", "canceled"],
  completed: [],
  failed: ["queued", "running", "canceled"],
  canceled: ["queued"],
};

function unique(values: readonly string[] | undefined): string[] {
  return Array.from(new Set((values || []).map((value) => String(value || "").trim()).filter(Boolean)));
}

function optional(raw: unknown): string | undefined {
  const value = String(raw || "").trim();
  return value || undefined;
}

export function deriveAgentRunTitle(rawGoal: string): string {
  const normalized = String(rawGoal || "").replace(/\s+/g, " ").trim();
  if (!normalized) return "Agent run";
  const task = /\bTask:\s*/i.exec(normalized);
  let candidate = task ? normalized.slice(task.index + task[0].length) : normalized;
  const metadata = /\s+(?:Repository|Source|TODO|Dispatch ID|Acceptance criteria|Protected exclusions|Origin thread):\s*/i.exec(candidate);
  if (metadata) candidate = candidate.slice(0, metadata.index);
  if (!task) {
    const sentence = /^(.+?[.!?])(?:\s|$)/.exec(candidate);
    if (sentence) candidate = sentence[1];
  }
  candidate = candidate.trim().replace(/[\s:;,.-]+$/, "");
  if (!candidate) candidate = "Agent run";
  if (candidate.length <= AGENT_RUN_TITLE_MAX_LENGTH) return candidate;
  return `${candidate.slice(0, AGENT_RUN_TITLE_MAX_LENGTH - 1).trimEnd()}…`;
}

function explicitAgentRunTitle(raw: unknown): string | undefined {
  const title = optional(raw)?.replace(/\s+/g, " ");
  if (!title) return undefined;
  if (title.length > AGENT_RUN_TITLE_MAX_LENGTH) {
    throw new Error(`run title must be at most ${AGENT_RUN_TITLE_MAX_LENGTH} characters; put execution details in --goal`);
  }
  return title;
}

export function agentRunBlockReasonLooksLikeApprovalBoundary(reasonRaw: unknown): boolean {
  const reason = String(reasonRaw || "").toLowerCase();
  return reason === AGENT_RUN_APPROVAL_BLOCK_REASON.toLowerCase()
    || /\b(?:awaiting|waiting|pending)\b.*\b(?:approval|review|decision)\b/.test(reason)
    || /\b(?:approval|review)\b.*\b(?:required|needed|pending)\b/.test(reason)
    || /\buntil\b.*\bapproved\b/.test(reason)
    || /\bexplicitly\s+approve\b/.test(reason)
    || /\bapprove\b.*\b(?:or|before)\b.*\b(?:edits?|publish|publication)\b/.test(reason);
}

function isApprovalBoundaryBlock(run: AgentRun): boolean {
  if (run.status !== "blocked") return false;
  if (run.blockedReason === AGENT_RUN_APPROVAL_BLOCK_REASON) return true;
  return agentRunBlockReasonLooksLikeApprovalBoundary(run.blockedReason);
}

function isoNow(raw?: string): string {
  const date = raw ? new Date(raw) : new Date();
  if (Number.isNaN(date.getTime())) throw new Error(`invalid timestamp: ${raw}`);
  return date.toISOString();
}

function event(type: string, at: string, actor?: string, detail?: string, data?: Record<string, unknown>): AgentRunEvent {
  return {
    id: crypto.randomUUID(),
    type,
    at,
    ...(optional(actor) ? { actor: optional(actor) } : {}),
    ...(optional(detail) ? { detail: optional(detail) } : {}),
    ...(data && Object.keys(data).length > 0 ? { data } : {}),
  };
}

export function agentRunApprovalFingerprint(input: Pick<AgentRunApproval, "title" | "action" | "riskClass"> & Partial<Pick<AgentRunApproval, "requestedRole" | "requestedFrom" | "note">>): string {
  const material = {
    title: String(input.title || "").trim(),
    action: String(input.action || "").trim(),
    riskClass: input.riskClass,
    requestedRole: optional(input.requestedRole) || null,
    requestedFrom: optional(input.requestedFrom) || null,
    note: optional(input.note) || null,
  };
  return `sha256:${crypto.createHash("sha256").update(JSON.stringify(material)).digest("hex")}`;
}

export function agentRunApprovalDecisionKeys(
  input: Pick<AgentRunApproval, "action"> & Partial<Pick<AgentRunApproval, "note">>,
): string[] {
  const keys = new Set<string>();
  const reviewMaterial = `${input.action || ""}\n${input.note || ""}`;
  for (const match of reviewMaterial.matchAll(/^\s*Provider draft:\s*(\S+)\s*$/gim)) {
    const raw = String(match[1] || "").trim().toLowerCase();
    if (!raw) continue;
    keys.add(raw.startsWith("artifact:") ? raw : `artifact:${raw}`);
  }
  return [...keys].sort();
}

export function createAgentRun(input: AgentRunCreateInput): AgentRun {
  const now = isoNow(input.now);
  const id = safeIdentifier(input.id || crypto.randomUUID(), { label: "run id" });
  const goal = String(input.goal || "").trim();
  if (!goal) throw new Error("run goal is required");
  const title = explicitAgentRunTitle(input.title) || deriveAgentRunTitle(goal);
  const status = input.status || "queued";
  if (!AGENT_RUN_STATUSES.includes(status)) throw new Error(`invalid run status: ${status}`);
  const riskClass = input.riskClass || "local-draft";
  if (!AGENT_RUN_RISK_CLASSES.includes(riskClass)) throw new Error(`invalid run risk class: ${riskClass}`);
  if (input.budget) {
    for (const [name, value] of Object.entries(input.budget)) {
      if (value !== undefined && (!Number.isFinite(value) || value < 0)) throw new Error(`run budget ${name} must be a non-negative finite number`);
    }
  }

  const plan = (input.plan || []).map((step, index) => {
    if (!AGENT_RUN_STEP_KINDS.includes(step.kind)) throw new Error(`invalid run step kind: ${step.kind}`);
    const status = step.status || "pending";
    if (!AGENT_RUN_STEP_STATUSES.includes(status)) throw new Error(`invalid run step status: ${status}`);
    return {
      id: safeIdentifier(step.id || `step-${index + 1}`, { label: "run plan step id" }),
      title: String(step.title || "").trim(),
      kind: step.kind,
      status,
      ...(optional(step.capability) ? { capability: optional(step.capability) } : {}),
      ...(optional(step.detail) ? { detail: optional(step.detail) } : {}),
    };
  }).filter((step) => step.title);
  const planIds = new Set<string>();
  for (const step of plan) {
    if (planIds.has(step.id)) throw new Error(`run plan step ids must be unique: ${step.id}`);
    planIds.add(step.id);
  }

  const run: AgentRun = {
    schema: ORG2_AGENT_RUN_SCHEMA,
    id,
    title,
    goal,
    acceptanceCriteria: unique(input.acceptanceCriteria),
    status,
    riskClass,
    capabilities: unique(input.capabilities),
    context: (input.context || []).map((item) => ({
      ref: String(item.ref || "").trim(),
      ...(optional(item.title) ? { title: optional(item.title) } : {}),
      ...(optional(item.citation) ? { citation: optional(item.citation) } : {}),
      ...(optional(item.sha256) ? { sha256: optional(item.sha256)?.toLowerCase() } : {}),
    })).filter((item) => item.ref),
    plan,
    artifacts: [],
    approvals: [],
    validations: [],
    comments: [],
    events: [event("created", now, input.owner, goal)],
    createdAt: now,
    updatedAt: now,
    ...(optional(input.owner) ? { owner: optional(input.owner) } : {}),
    ...(optional(input.assignee) ? { assignee: optional(input.assignee) } : {}),
    ...(optional(input.agentRef) ? { agentRef: optional(input.agentRef) } : {}),
    ...(optional(input.goalRef) ? { goalRef: optional(input.goalRef) } : {}),
    ...(optional(input.workflowId) ? { workflowId: optional(input.workflowId) } : {}),
    ...(optional(input.workflowVersion) ? { workflowVersion: optional(input.workflowVersion) } : {}),
    ...(optional(input.destinationRef) ? { destinationRef: optional(input.destinationRef) } : {}),
    ...(optional(input.providerPolicy) ? { providerPolicy: optional(input.providerPolicy) } : {}),
    ...(optional(input.provider) ? { provider: optional(input.provider) } : {}),
    ...(optional(input.model) ? { model: optional(input.model) } : {}),
    ...(input.budget ? { budget: { ...input.budget } } : {}),
    ...(optional(input.logicalWorkId) ? { logicalWorkId: optional(input.logicalWorkId) } : {}),
    ...(input.attempt ? { attempt: {
      id: safeIdentifier(input.attempt.id, { label: "run attempt id" }),
      number: input.attempt.number,
      ...(optional(input.attempt.triggerId) ? { triggerId: optional(input.attempt.triggerId) } : {}),
      ...(optional(input.attempt.triggerType) ? { triggerType: optional(input.attempt.triggerType) } : {}),
      ...(optional(input.attempt.scheduledFor) ? { scheduledFor: isoNow(input.attempt.scheduledFor) } : {}),
      ...(input.attempt.signalIds?.length ? { signalIds: unique(input.attempt.signalIds) } : {}),
    } } : {}),
    ...(optional(input.parentRunId) ? { parentRunId: optional(input.parentRunId) } : {}),
    ...(optional(input.forkedFromEventId) ? { forkedFromEventId: optional(input.forkedFromEventId) } : {}),
    ...(optional(input.outcome?.summary) ? { outcome: {
      summary: optional(input.outcome?.summary)!,
      highlights: unique(input.outcome?.highlights),
      nextActions: unique(input.outcome?.nextActions),
    } } : {}),
  };
  if (status === "running") run.startedAt = now;
  if (status === "completed") run.completedAt = now;
  if (run.attempt && (!Number.isInteger(run.attempt.number) || run.attempt.number < 1)) {
    throw new Error("run attempt number must be a positive integer");
  }
  return run;
}

export function validateAgentRun(value: unknown): AgentRunValidationResult {
  const issues: AgentRunValidationIssue[] = [];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { valid: false, issues: [{ path: "$", message: "run must be an object" }] };
  }
  const run = value as Partial<AgentRun>;
  if (!schemaMatches(run.schema, ORG2_AGENT_RUN_SCHEMA)) issues.push({ path: "$.schema", message: `must be ${ORG2_AGENT_RUN_SCHEMA}` });
  if (!run.id || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(run.id)) issues.push({ path: "$.id", message: "must be a safe non-empty id" });
  if (run.title !== undefined && !String(run.title).trim()) issues.push({ path: "$.title", message: "must not be empty when present" });
  if (!String(run.goal || "").trim()) issues.push({ path: "$.goal", message: "must not be empty" });
  if (run.agentRef !== undefined && !String(run.agentRef).trim()) issues.push({ path: "$.agentRef", message: "must not be empty when present" });
  if (run.goalRef !== undefined && !String(run.goalRef).trim()) issues.push({ path: "$.goalRef", message: "must not be empty when present" });
  if (run.destinationRef !== undefined && !String(run.destinationRef).trim()) issues.push({ path: "$.destinationRef", message: "must not be empty when present" });
  if (!run.status || !AGENT_RUN_STATUSES.includes(run.status)) issues.push({ path: "$.status", message: `must be one of: ${AGENT_RUN_STATUSES.join(", ")}` });
  if (!run.riskClass || !AGENT_RUN_RISK_CLASSES.includes(run.riskClass)) issues.push({ path: "$.riskClass", message: `must be one of: ${AGENT_RUN_RISK_CLASSES.join(", ")}` });
  for (const field of ["acceptanceCriteria", "capabilities", "context", "plan", "artifacts", "approvals", "validations", "comments", "events"] as const) {
    if (!Array.isArray(run[field])) issues.push({ path: `$.${field}`, message: "must be an array" });
  }
  for (const field of ["createdAt", "updatedAt"] as const) {
    const raw = run[field];
    if (!raw || Number.isNaN(new Date(raw).getTime())) issues.push({ path: `$.${field}`, message: "must be an ISO timestamp" });
  }
  for (const [name, value] of Object.entries(run.budget || {})) {
    if (value !== undefined && (!Number.isFinite(value) || value < 0)) issues.push({ path: `$.budget.${name}`, message: "must be a non-negative finite number" });
  }
  if (run.attempt) {
    if (!run.logicalWorkId?.trim()) issues.push({ path: "$.logicalWorkId", message: "is required when attempt is present" });
    if (!run.attempt.id || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(run.attempt.id)) issues.push({ path: "$.attempt.id", message: "must be a safe non-empty id" });
    if (!Number.isInteger(run.attempt.number) || run.attempt.number < 1) issues.push({ path: "$.attempt.number", message: "must be a positive integer" });
  }
  for (const [index, approval] of (run.approvals || []).entries()) {
    const expected = agentRunApprovalFingerprint(approval);
    if (!approval.fingerprint) {
      issues.push({ path: `$.approvals[${index}].fingerprint`, message: "must be present" });
    } else if (approval.fingerprint !== expected) {
      issues.push({ path: `$.approvals[${index}].fingerprint`, message: "does not match immutable approval material" });
    }
    if (approval.priority !== undefined && !AGENT_RUN_APPROVAL_PRIORITIES.includes(approval.priority)) {
      issues.push({ path: `$.approvals[${index}].priority`, message: `must be one of: ${AGENT_RUN_APPROVAL_PRIORITIES.join(", ")}` });
    }
  }
  if (run.outcome !== undefined) {
    if (!String(run.outcome.summary || "").trim()) issues.push({ path: "$.outcome.summary", message: "must not be empty" });
    if (!Array.isArray(run.outcome.highlights)) issues.push({ path: "$.outcome.highlights", message: "must be an array" });
    if (!Array.isArray(run.outcome.nextActions)) issues.push({ path: "$.outcome.nextActions", message: "must be an array" });
  }
  const stepIds = new Set<string>();
  for (const [index, step] of (run.plan || []).entries()) {
    if (!step.id || stepIds.has(step.id)) issues.push({ path: `$.plan[${index}].id`, message: "must be unique and non-empty" });
    stepIds.add(step.id);
    if (!String(step.title || "").trim()) issues.push({ path: `$.plan[${index}].title`, message: "must not be empty" });
  }
  return { valid: issues.length === 0, issues };
}

export function transitionAgentRun(run: AgentRun, status: AgentRunStatus, options: { actor?: string; reason?: string; summary?: string; highlights?: string[]; nextActions?: string[]; now?: string; completionSource?: "external"; separateFromApproval?: boolean } = {}): AgentRun {
  const completedExternally = status === "completed" && options.completionSource === "external";
  if (completedExternally && run.status === "completed") {
    throw new Error("a completed run cannot be marked completed outside the workflow");
  }
  if (run.status === status) return { ...run };
  const allowedExternalCompletion = completedExternally;
  if (!TRANSITIONS[run.status].includes(status) && !allowedExternalCompletion) throw new Error(`run cannot transition from ${run.status} to ${status}`);
  if (options.completionSource === "external" && !allowedExternalCompletion) {
    throw new Error("external completion must transition an unfinished run to completed");
  }
  const blockedReason = status === "blocked" ? optional(options.reason) : undefined;
  if (status === "blocked" && !blockedReason) {
    throw new Error("blocking a run requires --reason with a specific clarification or next action");
  }
  if (status === "blocked" && run.approvals.some((approval) => approval.status === "pending")) {
    if (agentRunBlockReasonLooksLikeApprovalBoundary(blockedReason)) {
      throw new Error("blocking reason duplicates the pending approval boundary; leave the run waiting-approval and decide the canonical approval");
    }
    if (!options.separateFromApproval) {
      throw new Error("run has a pending approval; pass --separate-from-approval only for an independent clarification or operational blocker");
    }
  }
  const completionSummary = status === "completed" ? optional(options.summary) || optional(run.outcome?.summary) : undefined;
  if (status === "completed" && !completedExternally && run.approvals.some((approval) => approval.status === "pending")) {
    throw new Error("completing a run with pending approvals is not allowed");
  }
  if (status === "completed" && !completedExternally && run.artifacts.some((artifact) => artifact.reviewStatus === "review-required")) {
    throw new Error("completing a run with review-required artifacts is not allowed; record the review with `celorga run artifact-review RUN_ID ARTIFACT_ID --status reviewed`");
  }
  if (status === "completed" && !completionSummary) {
    throw new Error("completing a run requires --summary with a human-readable outcome");
  }
  const now = isoNow(options.now);
  const statusEvent = event("status-changed", now, options.actor, `${run.status} -> ${status}`, {
    from: run.status,
    to: status,
    ...(options.reason ? { reason: options.reason } : {}),
    ...(completedExternally ? { completionSource: "external" } : {}),
  });
  const next: AgentRun = {
    ...run,
    status,
    updatedAt: now,
    events: [
      ...run.events,
      statusEvent,
      ...(completedExternally ? [event("completed-externally", now, options.actor, completionSummary)] : []),
    ],
  };
  if (status === "running" && !next.startedAt) next.startedAt = now;
  if (status === "completed") {
    next.completedAt = now;
    next.outcome = {
      summary: completionSummary!,
      highlights: options.highlights === undefined ? unique(run.outcome?.highlights) : unique(options.highlights),
      nextActions: options.nextActions === undefined ? unique(run.outcome?.nextActions) : unique(options.nextActions),
    };
  }
  if (status !== "blocked") delete next.blockedReason;
  if (status === "blocked") next.blockedReason = blockedReason;
  if (status === "failed") next.failure = optional(options.reason) || "Run failed";
  if (status !== "failed") delete next.failure;
  return next;
}

export function completeAgentRunExternally(run: AgentRun, input: { summary: string; actor: string; now?: string }): AgentRun {
  if (run.status === "completed") throw new Error("a completed run cannot be marked completed outside the workflow");
  const actor = optional(input.actor);
  if (!actor) throw new Error("marking a run completed outside the workflow requires an actor");
  const now = isoNow(input.now);
  const externalDetail = "Outcome completed outside this workflow.";
  const prepared: AgentRun = {
    ...run,
    plan: run.plan.map((step) => ["completed", "skipped"].includes(step.status) ? step : {
      ...step,
      status: "skipped",
      detail: step.detail ? `${step.detail} ${externalDetail}` : externalDetail,
    }),
  };
  return transitionAgentRun(prepared, "completed", {
    summary: input.summary,
    actor,
    now,
    completionSource: "external",
  });
}

export function reopenExternallyCompletedApprovalRun(
  run: AgentRun,
  input: { summary: string; actor: string; now?: string },
): AgentRun {
  const actor = optional(input.actor);
  if (!actor) throw new Error("reopening an externally completed approval run requires an actor");
  const summary = optional(input.summary);
  if (!summary) throw new Error("reopening an externally completed approval run requires a replacement summary");
  if (run.status !== "completed") throw new Error("only a completed run can be reopened after external completion");
  if (!run.approvals.some((approval) => approval.status === "pending")) {
    throw new Error("reopening external completion requires at least one retained pending approval");
  }
  let completionIndex = -1;
  for (let index = run.events.length - 1; index >= 0; index -= 1) {
    if (run.events[index]?.type === "completed-externally") {
      completionIndex = index;
      break;
    }
  }
  let transitionIndex = -1;
  for (let index = completionIndex - 1; index >= 0; index -= 1) {
    const candidate = run.events[index];
    if (
      candidate?.type === "status-changed"
      && candidate.data?.to === "completed"
      && candidate.data?.completionSource === "external"
    ) {
      transitionIndex = index;
      break;
    }
  }
  const previousStatus = transitionIndex >= 0 ? optional(run.events[transitionIndex]?.data?.from) : undefined;
  if (completionIndex < 0 || previousStatus !== "waiting-approval") {
    throw new Error("only a run externally completed from waiting-approval can be reopened this way");
  }
  const now = isoNow(input.now);
  const next: AgentRun = {
    ...run,
    status: "waiting-approval",
    updatedAt: now,
    outcome: {
      summary,
      highlights: unique(run.outcome?.highlights),
      nextActions: unique(run.outcome?.nextActions),
    },
    events: [
      ...run.events,
      event("external-completion-reopened", now, actor, summary, {
        from: "completed",
        to: "waiting-approval",
        completionEventId: run.events[completionIndex]?.id,
      }),
    ],
  };
  delete next.completedAt;
  return next;
}

export function updateAgentRunOutcome(run: AgentRun, input: { summary: string; highlights?: string[]; nextActions?: string[]; actor?: string; now?: string }): AgentRun {
  const summary = optional(input.summary);
  if (!summary) throw new Error("run outcome summary is required");
  const now = isoNow(input.now);
  const outcome: AgentRunOutcome = {
    summary,
    highlights: unique(input.highlights),
    nextActions: unique(input.nextActions),
  };
  return {
    ...run,
    outcome,
    updatedAt: now,
    events: [...run.events, event("outcome-updated", now, input.actor, summary)],
  };
}

export function updateAgentRunRuntime(run: AgentRun, input: AgentRunRuntimeUpdate): AgentRun {
  const now = isoNow(input.now);
  const provider = optional(input.provider) || run.provider;
  const model = optional(input.model) || run.model;
  const budget = { ...(run.budget || {}) };
  for (const [name, value] of [
    ["tokensUsed", input.tokensUsed],
    ["costUsedUsd", input.costUsedUsd],
    ["elapsedSeconds", input.elapsedSeconds],
  ] as const) {
    if (value === undefined) continue;
    if (!Number.isFinite(value) || value < 0) throw new Error(`run runtime ${name} must be a non-negative finite number`);
    budget[name] = value;
  }
  const details = [
    provider ? `provider=${provider}` : undefined,
    model ? `model=${model}` : undefined,
    input.tokensUsed !== undefined ? `tokens=${input.tokensUsed}` : undefined,
    input.elapsedSeconds !== undefined ? `elapsed=${input.elapsedSeconds}s` : undefined,
  ].filter(Boolean).join(" ");
  return {
    ...run,
    ...(provider ? { provider } : {}),
    ...(model ? { model } : {}),
    ...(Object.keys(budget).length ? { budget } : {}),
    updatedAt: now,
    events: [...run.events, event("runtime-updated", now, input.actor, details || "Runtime metadata updated")],
  };
}

export function updateAgentRunAssignment(run: AgentRun, input: { owner?: string; assignee?: string; agentRef?: string; goalRef?: string; actor?: string; now?: string }): AgentRun {
  const now = isoNow(input.now);
  return {
    ...run,
    ...(input.owner !== undefined ? { owner: optional(input.owner) } : {}),
    ...(input.assignee !== undefined ? { assignee: optional(input.assignee) } : {}),
    ...(input.agentRef !== undefined ? { agentRef: optional(input.agentRef) } : {}),
    ...(input.goalRef !== undefined ? { goalRef: optional(input.goalRef) } : {}),
    updatedAt: now,
    events: [...run.events, event("assigned", now, input.actor, [
      `owner=${optional(input.owner) || run.owner || ""}`,
      `assignee=${optional(input.assignee) || run.assignee || ""}`,
      `agentRef=${optional(input.agentRef) || run.agentRef || ""}`,
      `goalRef=${optional(input.goalRef) || run.goalRef || ""}`,
    ].join("; "))],
  };
}

export function addAgentRunComment(run: AgentRun, author: string, body: string, nowRaw?: string): AgentRun {
  const now = isoNow(nowRaw);
  const cleanAuthor = String(author || "").trim();
  const cleanBody = String(body || "").trim();
  if (!cleanAuthor || !cleanBody) throw new Error("comment author and body are required");
  const comment: AgentRunComment = { id: crypto.randomUUID(), author: cleanAuthor, body: cleanBody, createdAt: now };
  return { ...run, comments: [...run.comments, comment], updatedAt: now, events: [...run.events, event("commented", now, cleanAuthor, cleanBody)] };
}

export function addAgentRunArtifact(run: AgentRun, input: Omit<AgentRunArtifact, "id" | "createdAt"> & { id?: string; createdAt?: string }, actor?: string): AgentRun {
  const now = isoNow(input.createdAt);
  const artifactPath = String(input.path || "").trim();
  if (!artifactPath) throw new Error("artifact path is required");
  if (!AGENT_RUN_ARTIFACT_ROLES.includes(input.role)) throw new Error(`invalid artifact role: ${input.role}`);
  if (input.reviewStatus && !AGENT_RUN_ARTIFACT_REVIEW_STATUSES.includes(input.reviewStatus)) throw new Error(`invalid artifact review status: ${input.reviewStatus}`);
  const artifact: AgentRunArtifact = {
    id: safeIdentifier(input.id || crypto.randomUUID(), { label: "run id" }),
    path: artifactPath,
    role: input.role,
    createdAt: now,
    ...(optional(input.title) ? { title: optional(input.title) } : {}),
    ...(optional(input.mediaType) ? { mediaType: optional(input.mediaType) } : {}),
    ...(optional(input.sha256) ? { sha256: optional(input.sha256)?.toLowerCase() } : {}),
    ...(input.reviewStatus ? { reviewStatus: input.reviewStatus } : {}),
  };
  return { ...run, artifacts: [...run.artifacts, artifact], updatedAt: now, events: [...run.events, event("artifact-added", now, actor, artifactPath, { artifactId: artifact.id, role: artifact.role })] };
}

export function updateAgentRunArtifactReview(
  run: AgentRun,
  artifactId: string,
  reviewStatus: AgentRunArtifactReviewStatus,
  options: { actor?: string; now?: string } = {},
): AgentRun {
  if (!AGENT_RUN_ARTIFACT_REVIEW_STATUSES.includes(reviewStatus)) throw new Error(`invalid artifact review status: ${reviewStatus}`);
  const index = run.artifacts.findIndex((artifact) => artifact.id === artifactId);
  if (index < 0) throw new Error(`unknown artifact id: ${artifactId}`);
  const previous = run.artifacts[index]!;
  if (previous.reviewStatus === reviewStatus) return { ...run };
  const now = isoNow(options.now);
  const artifacts = [...run.artifacts];
  artifacts[index] = { ...previous, reviewStatus };
  return {
    ...run,
    artifacts,
    updatedAt: now,
    events: [...run.events, event(
      "artifact-review-changed",
      now,
      options.actor,
      `${previous.path}: ${previous.reviewStatus || "unspecified"} -> ${reviewStatus}`,
      { artifactId, from: previous.reviewStatus || "", to: reviewStatus },
    )],
  };
}

export function addAgentRunValidation(run: AgentRun, input: Omit<AgentRunValidation, "id" | "checkedAt"> & { id?: string; checkedAt?: string }, actor?: string): AgentRun {
  const now = isoNow(input.checkedAt);
  const validation: AgentRunValidation = {
    id: safeIdentifier(input.id || crypto.randomUUID(), { label: "run id" }),
    name: String(input.name || "").trim(),
    status: input.status,
    checkedAt: now,
    ...(optional(input.detail) ? { detail: optional(input.detail) } : {}),
  };
  if (!validation.name) throw new Error("validation name is required");
  if (!AGENT_RUN_VALIDATION_STATUSES.includes(validation.status)) throw new Error(`invalid validation status: ${validation.status}`);
  return { ...run, validations: [...run.validations, validation], updatedAt: now, events: [...run.events, event("validated", now, actor, `${validation.name}: ${validation.status}`)] };
}

export function requestAgentRunApproval(run: AgentRun, input: Omit<AgentRunApproval, "id" | "fingerprint" | "status" | "requestedAt" | "decidedAt" | "decidedBy" | "decisionNote"> & { id?: string; requestedAt?: string }, actor?: string): AgentRun {
  if (["completed", "failed", "canceled"].includes(run.status)) throw new Error(`cannot request approval for a ${run.status} run`);
  if (!AGENT_RUN_RISK_CLASSES.includes(input.riskClass)) throw new Error(`invalid approval risk class: ${input.riskClass}`);
  const now = isoNow(input.requestedAt);
  const material = {
    id: safeIdentifier(input.id || crypto.randomUUID(), { label: "run id" }),
    title: String(input.title || "").trim(),
    action: String(input.action || "").trim(),
    riskClass: input.riskClass,
    status: "pending" as const,
    requestedAt: now,
    ...(optional(input.requestedRole) ? { requestedRole: optional(input.requestedRole) } : {}),
    ...(optional(input.requestedFrom) ? { requestedFrom: optional(input.requestedFrom) } : {}),
    ...(optional(input.note) ? { note: optional(input.note) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  const priority = input.priority ?? "normal";
  if (!AGENT_RUN_APPROVAL_PRIORITIES.includes(priority)) throw new Error(`invalid approval priority: ${priority}`);
  const approval: AgentRunApproval = {
    ...material,
    fingerprint: agentRunApprovalFingerprint(material),
    ...(priority === "urgent" ? { priority } : {}),
  };
  if (!approval.title || !approval.action) throw new Error("approval title and action are required");
  const opensApprovalBoundary = run.status === "running"
    || run.status === "queued"
    || isApprovalBoundaryBlock(run);
  const next = opensApprovalBoundary
    ? transitionAgentRun(run, "waiting-approval", { actor, now })
    : { ...run };
  return { ...next, approvals: [...next.approvals, approval], updatedAt: now, events: [...next.events, event("approval-requested", now, actor, approval.title, { approvalId: approval.id, fingerprint: approval.fingerprint, riskClass: approval.riskClass })] };
}

export function currentAgentRunApprovalBoundary(run: AgentRun): AgentRunApproval[] {
  let boundaryStart = -1;
  for (let index = run.events.length - 1; index >= 0; index -= 1) {
    const candidate = run.events[index]!;
    if (candidate.type === "status-changed" && candidate.data?.to === "waiting-approval") {
      boundaryStart = index;
      break;
    }
  }
  if (boundaryStart < 0) return run.approvals;

  const boundaryIds = new Set(
    run.events.slice(boundaryStart + 1)
      .filter((candidate) => candidate.type === "approval-requested")
      .map((candidate) => optional(candidate.data?.approvalId))
      .filter((id): id is string => Boolean(id)),
  );
  if (boundaryIds.size === 0) return run.approvals;
  return run.approvals.filter((approval) => boundaryIds.has(approval.id));
}

export function decideAgentRunApproval(run: AgentRun, approvalId: string, decision: AgentRunApprovalDecision, input: { actor: string; actorRole?: string; fingerprint?: string; note?: string; receipt?: string; now?: string }): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_APPROVAL_DECISIONS.includes(decision)) throw new Error(`invalid approval decision: ${decision}`);
  if (decision === "revised" && !optional(input.note)) throw new Error("revision decision requires a note describing the requested changes");
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  if (run.approvals[index]!.status !== "pending") throw new Error(`approval is already ${run.approvals[index]!.status}`);
  const expectedFingerprint = agentRunApprovalFingerprint(run.approvals[index]!);
  if (run.approvals[index]!.fingerprint !== expectedFingerprint) throw new Error("approval material changed after it was requested");
  if (input.fingerprint && input.fingerprint !== expectedFingerprint) throw new Error("approval fingerprint does not match the requested action");
  if (run.approvals[index]!.requestedRole && input.actorRole !== run.approvals[index]!.requestedRole) throw new Error(`approval requires role ${run.approvals[index]!.requestedRole}; pass the matching actor role`);
  if (run.approvals[index]!.requestedFrom && input.actor !== run.approvals[index]!.requestedFrom) throw new Error(`approval is assigned to ${run.approvals[index]!.requestedFrom}`);
  const approvals = [...run.approvals];
  approvals[index] = {
    ...approvals[index]!,
    status: decision,
    decidedAt: now,
    decidedBy: String(input.actor || "").trim(),
    ...(optional(input.note) ? { decisionNote: optional(input.note) } : {}),
    ...(optional(input.receipt) ? { receipt: optional(input.receipt) } : {}),
  };
  let next: AgentRun = { ...run, approvals, updatedAt: now, events: [...run.events, event("approval-decided", now, input.actor, `${approvalId}: ${decision}`, { approvalId, fingerprint: expectedFingerprint, decision, ...(input.actorRole ? { actorRole: input.actorRole } : {}) })] };
  if (
    (run.status === "waiting-approval"
      || isApprovalBoundaryBlock(run))
    && approvals.every((approval) => approval.status !== "pending")
  ) {
    const boundary = currentAgentRunApprovalBoundary(next);
    const needsRevision = boundary.some((approval) => approval.status === "revised");
    next = transitionAgentRun(next, needsRevision ? "blocked" : "running", {
      actor: input.actor,
      reason: needsRevision ? AGENT_RUN_APPROVAL_BLOCK_REASON : undefined,
      now,
    });
  }
  return next;
}

export function supersedeAgentRunApproval(
  run: AgentRun,
  approvalId: string,
  input: {
    actor?: string;
    replacementRunId: string;
    replacementApprovalId: string;
    now?: string;
  },
): AgentRun {
  const now = isoNow(input.now);
  const index = run.approvals.findIndex((approval) => approval.id === approvalId);
  if (index < 0) throw new Error(`approval not found: ${approvalId}`);
  if (run.approvals[index]!.status !== "pending") return run;
  const approvals = [...run.approvals];
  approvals[index] = {
    ...approvals[index]!,
    status: "canceled",
    decidedAt: now,
    decidedBy: input.actor || "org2-approval-reconciler",
    receipt: `Superseded by approval ${input.replacementApprovalId} on run ${input.replacementRunId}.`,
  };
  let next: AgentRun = {
    ...run,
    approvals,
    updatedAt: now,
    events: [...run.events, event(
      "approval-superseded",
      now,
      input.actor || "org2-approval-reconciler",
      `${approvalId} -> ${input.replacementRunId}:${input.replacementApprovalId}`,
      {
        approvalId,
        replacementRunId: input.replacementRunId,
        replacementApprovalId: input.replacementApprovalId,
      },
    )],
  };
  if (run.status === "waiting-approval" && approvals.every((approval) => approval.status !== "pending")) {
    next = transitionAgentRun(next, "blocked", {
      actor: input.actor || "org2-approval-reconciler",
      reason: AGENT_RUN_APPROVAL_BLOCK_REASON,
      now,
    });
  }
  return next;
}

export function updateAgentRunStep(run: AgentRun, stepId: string, status: AgentRunStepStatus, input: { actor?: string; detail?: string; now?: string } = {}): AgentRun {
  const now = isoNow(input.now);
  if (!AGENT_RUN_STEP_STATUSES.includes(status)) throw new Error(`invalid run step status: ${status}`);
  const index = run.plan.findIndex((step) => step.id === stepId);
  if (index < 0) throw new Error(`plan step not found: ${stepId}`);
  const plan = [...run.plan];
  const existing = plan[index]!;
  plan[index] = {
    ...existing,
    status,
    ...(status === "running" && !existing.startedAt ? { startedAt: now } : {}),
    ...(["completed", "failed", "skipped"].includes(status) ? { completedAt: now } : {}),
    ...(optional(input.detail) ? { detail: optional(input.detail) } : {}),
  };
  return { ...run, plan, updatedAt: now, events: [...run.events, event("step-updated", now, input.actor, `${stepId}: ${status}`, { stepId, status })] };
}

export function forkAgentRun(run: AgentRun, input: { id?: string; actor?: string; fromEventId?: string; now?: string } = {}): AgentRun {
  const fork = createAgentRun({
    id: input.id,
    goal: run.goal,
    acceptanceCriteria: run.acceptanceCriteria,
    riskClass: run.riskClass,
    owner: run.owner,
    assignee: run.assignee,
    agentRef: run.agentRef,
    goalRef: run.goalRef,
    workflowId: run.workflowId,
    workflowVersion: run.workflowVersion,
    destinationRef: run.destinationRef,
    providerPolicy: run.providerPolicy,
    capabilities: run.capabilities,
    context: run.context,
    plan: run.plan.map((step) => ({ title: step.title, kind: step.kind, capability: step.capability, detail: step.detail })),
    budget: run.budget ? { tokenLimit: run.budget.tokenLimit, costLimitUsd: run.budget.costLimitUsd, timeLimitSeconds: run.budget.timeLimitSeconds } : undefined,
    logicalWorkId: run.logicalWorkId,
    parentRunId: run.id,
    forkedFromEventId: input.fromEventId || run.events.at(-1)?.id,
    now: input.now,
  });
  fork.events.push(event("forked", fork.createdAt, input.actor, `Forked from ${run.id}`, { parentRunId: run.id }));
  return fork;
}

function orgEscape(raw: string): string {
  return String(raw || "").replace(/\r?\n/g, " ").trim();
}

function todoKeyword(status: AgentRunStatus): string {
  if (status === "completed") return "DONE";
  if (status === "canceled") return "CANCELED";
  return "TODO";
}

export function renderAgentRunOrg(run: AgentRun): string {
  const validation = validateAgentRun(run);
  if (!validation.valid) throw new Error(`invalid run: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  const title = orgEscape(run.title || run.goal);
  const lines = [
    `#+TITLE: Run: ${title}`,
    "#+ORG2_KIND: agent-run",
    "",
    `* ${todoKeyword(run.status)} ${title} :agent-run:`,
    ":PROPERTIES:",
    `:ID: ${run.id}`,
    `:KIND: agent-run`,
    ...(run.title ? [`:RUN_TITLE: ${title}`] : []),
    `:RUN_SCHEMA: ${run.schema}`,
    `:RUN_STATUS: ${run.status}`,
    `:RISK_CLASS: ${run.riskClass}`,
    ...(run.owner ? [`:OWNER: ${orgEscape(run.owner)}`] : []),
    ...(run.assignee ? [`:ASSIGNEE: ${orgEscape(run.assignee)}`] : []),
    ...(run.agentRef ? [`:AGENT_REF: ${orgEscape(run.agentRef)}`] : []),
    ...(run.goalRef ? [`:GOAL_REF: ${orgEscape(run.goalRef)}`] : []),
    ...(run.workflowId ? [`:WORKFLOW_ID: ${orgEscape(run.workflowId)}`] : []),
    ...(run.workflowVersion ? [`:WORKFLOW_VERSION: ${orgEscape(run.workflowVersion)}`] : []),
    ...(run.destinationRef ? [`:AI_DESTINATION_REF: ${orgEscape(run.destinationRef)}`] : []),
    ...(run.providerPolicy ? [`:PROVIDER_POLICY: ${orgEscape(run.providerPolicy)}`] : []),
    ...(run.provider ? [`:PROVIDER: ${orgEscape(run.provider)}`] : []),
    ...(run.model ? [`:MODEL: ${orgEscape(run.model)}`] : []),
    ...(run.logicalWorkId ? [`:LOGICAL_WORK_ID: ${orgEscape(run.logicalWorkId)}`] : []),
    ...(run.attempt ? [`:ATTEMPT_ID: ${orgEscape(run.attempt.id)}`, `:ATTEMPT_NUMBER: ${run.attempt.number}`] : []),
    `:CREATED_AT: ${run.createdAt}`,
    `:UPDATED_AT: ${run.updatedAt}`,
    ...(run.startedAt ? [`:STARTED_AT: ${run.startedAt}`] : []),
    ...(run.completedAt ? [`:COMPLETED_AT: ${run.completedAt}`] : []),
    ":END:",
    "",
    "** Goal",
    run.goal,
    "",
    "** Outcome",
    ...(run.outcome ? [
      run.outcome.summary,
      "",
      "*** Highlights",
      ...(run.outcome.highlights.length ? run.outcome.highlights.map((item) => `- ${item}`) : ["- None recorded."]),
      "",
      "*** Next actions",
      ...(run.outcome.nextActions.length ? run.outcome.nextActions.map((item) => `- ${item}`) : ["- None required."]),
    ] : ["No human-readable outcome has been recorded yet."]),
    "",
    "** Acceptance criteria",
    ...(run.acceptanceCriteria.length ? run.acceptanceCriteria.map((item) => `- ${item}`) : ["- None recorded."]),
    "",
    "** Plan",
    ...(run.plan.length ? run.plan.map((step) => `- [${step.status === "completed" ? "X" : step.status === "pending" ? " " : "-"}] ${step.title} =${step.id}= (${step.kind}; ${step.status})`) : ["- No plan recorded."]),
    "",
    "** Context",
    ...(run.context.length ? run.context.map((item) => `- ${item.citation || item.ref}${item.title ? ` — ${item.title}` : ""}`) : ["- No context recorded."]),
    "",
    "** Artifacts",
    ...(run.artifacts.length ? run.artifacts.map((artifact) => `- [[file:${artifact.path}][${artifact.title || artifact.path}]] (${artifact.role}; ${artifact.reviewStatus || "generated"})`) : ["- No artifacts recorded."]),
    "",
    `** Approvals [${run.approvals.filter((approval) => approval.status === "pending").length}/${run.approvals.length} pending]`,
    ...(run.approvals.length ? run.approvals.map((approval) => {
      const reviewer = approval.requestedFrom
        ? `; reviewer ${approval.requestedFrom}`
        : approval.requestedRole
          ? `; role ${approval.requestedRole}`
          : "";
      return `- ${approval.status.toUpperCase()} ${approval.title} — ${approval.action} (${approval.riskClass}${reviewer}) =${approval.id}= [${approval.fingerprint}]`;
    }) : ["- No approvals recorded."]),
    "",
    "** Validations",
    ...(run.validations.length ? run.validations.map((item) => `- ${item.status.toUpperCase()} ${item.name}${item.detail ? ` — ${item.detail}` : ""}`) : ["- No validations recorded."]),
    "",
    "** Machine state",
    "#+begin_src json :org2-agent-run",
    JSON.stringify(run, null, 2),
    "#+end_src",
    "",
  ];
  return lines.join("\n");
}

export function parseAgentRunOrg(raw: string): AgentRun {
  const match = /#\+begin_src\s+json\s+:org2-agent-run\s*\n([\s\S]*?)\n#\+end_src/i.exec(String(raw || "").replace(/\r\n/g, "\n"));
  if (!match) throw new Error("Celorga agent run is missing its machine-state JSON block");
  const parsed = JSON.parse(match[1]!) as AgentRun;
  const value: AgentRun = {
    ...parsed,
    approvals: (parsed.approvals || []).map((approval) => ({
      ...approval,
      fingerprint: approval.fingerprint || agentRunApprovalFingerprint(approval),
    })),
  };
  const validation = validateAgentRun(value);
  if (!validation.valid) throw new Error(`invalid Celorga agent run: ${validation.issues.map((issue) => `${issue.path} ${issue.message}`).join("; ")}`);
  return value;
}

function readableRunProperty(raw: string, key: string): string | undefined {
  return new RegExp(`^:${key}:\\s*(.*?)\\s*$`, "im").exec(raw)?.[1]?.trim() || undefined;
}

export function agentRunSourceConsistency(
  raw: string,
  run: AgentRun = parseAgentRunOrg(raw),
): AgentRunSourceConsistencyIssue[] {
  const issues: AgentRunSourceConsistencyIssue[] = [];
  const compare = (
    field: AgentRunSourceConsistencyIssue["field"],
    readable: string | undefined,
    canonical: string,
  ): void => {
    // Older generated run records do not contain every readable projection.
    // Absence is compatible; a present value that disagrees is ambiguous.
    if (readable !== undefined && readable !== canonical) issues.push({ field, readable, canonical });
  };
  compare("id", readableRunProperty(raw, "ID"), run.id);
  compare("status", readableRunProperty(raw, "RUN_STATUS"), run.status);
  compare("updatedAt", readableRunProperty(raw, "UPDATED_AT"), run.updatedAt);
  const canonicalTitle = orgEscape(run.title || run.goal);
  const projectedTitles = [
    /^#\+TITLE:\s*Run:\s*(.*?)\s*$/im.exec(raw)?.[1]?.trim(),
    readableRunProperty(raw, "RUN_TITLE"),
  ].filter((value): value is string => value !== undefined);
  const mismatchedTitle = projectedTitles.find((value) => value !== canonicalTitle);
  if (mismatchedTitle !== undefined) {
    issues.push({ field: "title", readable: mismatchedTitle, canonical: canonicalTitle });
  }
  compare("goal", /^\*\* Goal\s*\r?\n([\s\S]*?)(?=\r?\n\*\* )/m.exec(raw)?.[1]?.trim(), run.goal.trim());
  const approvalSummary = /^\*\* Approvals \[(\d+)\/(\d+) pending\]\s*$/im.exec(raw);
  compare(
    "approvals",
    approvalSummary ? `${approvalSummary[1]}/${approvalSummary[2]}` : undefined,
    `${run.approvals.filter((approval) => approval.status === "pending").length}/${run.approvals.length}`,
  );
  return issues;
}

export function agentRunDirectory(corpusRoot: string): string {
  return stateDir(path.resolve(corpusRoot), "runs");
}

export function agentRunPath(corpusRoot: string, id: string): string {
  return path.join(agentRunDirectory(corpusRoot), `${safeIdentifier(id, { label: "run id" })}.org2`);
}

export function saveAgentRun(
  corpusRoot: string,
  run: AgentRun,
  options: SaveAgentRunOptions = {},
): string {
  const outputPath = agentRunPath(corpusRoot, run.id);
  if (options.rejectSourceDrift && fs.existsSync(outputPath)) {
    const current = fs.readFileSync(outputPath, "utf8");
    const issues = agentRunSourceConsistency(current);
    if (issues.length > 0) {
      throw new Error(
        `run source has out-of-band readable-state changes (${issues.map((issue) => issue.field).join(", ")}); run celorga doctor and reconcile the source before writing: ${outputPath}`,
      );
    }
  }
  return guardedWriteFile(outputPath, renderAgentRunOrg(run), options).file;
}

export function loadAgentRun(corpusRoot: string, id: string): AgentRun {
  return loadAgentRunSnapshot(corpusRoot, id).run;
}

export function loadAgentRunSnapshot(corpusRoot: string, id: string): AgentRunSnapshot {
  const file = agentRunPath(corpusRoot, id);
  if (!fs.existsSync(file)) throw new Error(`run not found: ${id}`);
  const snapshot = readGuardedFile(file);
  const run = parseAgentRunOrg(snapshot.content);
  return {
    file: snapshot.file,
    revision: snapshot.revision,
    raw: snapshot.content,
    run,
    sourceIssues: agentRunSourceConsistency(snapshot.content, run),
  };
}

export function listAgentRuns(corpusRoot: string): AgentRun[] {
  // List consumers (including workspace refresh) need runs, not a retained copy
  // of every readable projection, revision, and source-consistency result.
  // Consume snapshots one at a time so large approval histories do not keep
  // the entire corpus of source strings alive until the list is complete.
  return Array.from(iterateAgentRunSnapshots(corpusRoot), (snapshot) => snapshot.run)
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
}

type AgentRunApprovalIndexEntry = {
  file: string;
  modifiedMs: number;
  byteCount: number;
  run: AgentRun | null;
};

type AgentRunApprovalIndex = {
  $schema: "org2:run-approval-index:v1";
  version: 1;
  rootDir: string;
  entries: AgentRunApprovalIndexEntry[];
};

function readAgentRunApprovalIndex(corpusRoot: string): AgentRunApprovalIndex | null {
  const rootDir = path.resolve(corpusRoot);
  try {
    const parsed = JSON.parse(fs.readFileSync(defaultRunApprovalIndexPath(rootDir), "utf8")) as AgentRunApprovalIndex;
    if (
      !schemaMatches(parsed.$schema, "org2:run-approval-index:v1")
      || parsed.version !== 1
      || path.resolve(parsed.rootDir) !== rootDir
      || !Array.isArray(parsed.entries)
    ) return null;
    for (const entry of parsed.entries) {
      if (
        !entry
        || typeof entry.file !== "string"
        || !Number.isFinite(entry.modifiedMs)
        || !Number.isFinite(entry.byteCount)
        || (entry.run !== null && !validateAgentRun(entry.run).valid)
      ) return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

function writeAgentRunApprovalIndex(corpusRoot: string, entries: AgentRunApprovalIndexEntry[]): void {
  const rootDir = path.resolve(corpusRoot);
  const outputPath = defaultRunApprovalIndexPath(rootDir);
  const temporaryPath = `${outputPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    const index: AgentRunApprovalIndex = {
      $schema: "org2:run-approval-index:v1",
      version: 1,
      rootDir,
      entries,
    };
    fs.writeFileSync(temporaryPath, `${JSON.stringify(index)}\n`, "utf8");
    fs.renameSync(temporaryPath, outputPath);
  } catch {
    // The index is disposable. Approval discovery remains correct if the
    // machine-local index directory is unavailable or a concurrent writer wins.
  } finally {
    try {
      if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
    } catch {
      // Best-effort cleanup for a disposable cache file.
    }
  }
}

/**
 * Loads only durable runs that can affect the unified approval queue.
 *
 * Run records carry a readable approval-count projection before the canonical
 * JSON block. A machine-local index fingerprints every durable run and retains
 * the parsed records that have approvals, so a warm queue refresh opens only
 * changed run files instead of rereading the entire run history. Older records
 * without the projection still fall back to a full parse.
 */
export function listAgentRunsWithApprovals(corpusRoot: string): AgentRun[] {
  const dir = agentRunDirectory(corpusRoot);
  if (!fs.existsSync(dir)) return [];

  const previous = readAgentRunApprovalIndex(corpusRoot);
  const previousByFile = new Map((previous?.entries || []).map((entry) => [entry.file, entry]));
  let changed = previous === null;
  const entries = fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".org2"))
    .map((entry): AgentRunApprovalIndexEntry | null => {
      const file = path.join(dir, entry.name);
      let stat: fs.Stats;
      try {
        stat = fs.statSync(file);
      } catch {
        changed = true;
        return null;
      }
      if (!stat.isFile()) return null;
      const modifiedMs = Math.trunc(stat.mtimeMs);
      const cached = previousByFile.get(file);
      if (cached && cached.modifiedMs === modifiedMs && cached.byteCount === stat.size) {
        return cached;
      }

      changed = true;
      const raw = fs.readFileSync(file, "utf8");
      const summary = /^\*\* Approvals \[\d+\/(\d+) pending\]\s*$/im.exec(raw);
      if (summary && Number(summary[1]) === 0) {
        return { file, modifiedMs, byteCount: stat.size, run: null };
      }

      const run = parseAgentRunOrg(raw);
      const canonicalRun = run.approvals.length > 0 && file === agentRunPath(corpusRoot, run.id)
        ? run
        : null;
      return { file, modifiedMs, byteCount: stat.size, run: canonicalRun };
    })
    .filter((entry): entry is AgentRunApprovalIndexEntry => entry !== null)
    .sort((a, b) => a.file.localeCompare(b.file));

  if (entries.length !== previousByFile.size) changed = true;
  if (changed) writeAgentRunApprovalIndex(corpusRoot, entries);

  return entries
    .flatMap((entry) => entry.run ? [entry.run] : [])
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id));
}

function* iterateAgentRunSnapshots(corpusRoot: string): Generator<AgentRunSnapshot> {
  const dir = agentRunDirectory(corpusRoot);
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".org2")) continue;
    const snapshot = readGuardedFile(path.join(dir, entry.name));
    const run = parseAgentRunOrg(snapshot.content);
    // Syncthing conflict copies are not authoritative, even when they carry
    // the same durable ID and a more recent timestamp.
    if (snapshot.file !== agentRunPath(corpusRoot, run.id)) continue;
    yield {
      file: snapshot.file,
      revision: snapshot.revision,
      raw: snapshot.content,
      run,
      sourceIssues: agentRunSourceConsistency(snapshot.content, run),
    };
  }
}

export function listAgentRunSnapshots(corpusRoot: string): AgentRunSnapshot[] {
  return Array.from(iterateAgentRunSnapshots(corpusRoot))
    .sort((a, b) => b.run.updatedAt.localeCompare(a.run.updatedAt) || a.run.id.localeCompare(b.run.id));
}

export function summarizeAgentRunAttempts(runs: AgentRun[]): AgentRunAttemptRollup[] {
  const groups = new Map<string, AgentRun[]>();
  for (const run of runs) {
    if (!run.logicalWorkId || !run.attempt) continue;
    groups.set(run.logicalWorkId, [...(groups.get(run.logicalWorkId) || []), run]);
  }
  return [...groups.entries()].map(([logicalWorkId, attempts]) => {
    const sorted = [...attempts].sort((a, b) =>
      (b.attempt?.number || 0) - (a.attempt?.number || 0)
      || b.updatedAt.localeCompare(a.updatedAt)
    );
    const latest = sorted[0]!;
    return {
      logicalWorkId,
      attempts: attempts.length,
      queued: attempts.filter((item) => item.status === "queued").length,
      running: attempts.filter((item) => item.status === "running").length,
      blocked: attempts.filter((item) => item.status === "blocked" || item.status === "waiting-approval").length,
      terminal: attempts.filter((item) => ["completed", "failed", "canceled"].includes(item.status)).length,
      latestRunId: latest.id,
      latestAttemptNumber: latest.attempt!.number,
      latestStatus: latest.status,
      updatedAt: latest.updatedAt,
    };
  }).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.logicalWorkId.localeCompare(b.logicalWorkId));
}

function walkOrgFiles(root: string, output: string[] = []): string[] {
  if (!fs.existsSync(root)) return output;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if ([".git", "node_modules", "site", "dist"].includes(entry.name)) continue;
    const absolute = path.join(root, entry.name);
    if (entry.isDirectory()) {
      if (absolute === agentRunDirectory(root)) continue;
      walkOrgFiles(absolute, output);
    } else if (entry.isFile() && /\.(org2?|ORG2?)$/.test(entry.name)) {
      output.push(absolute);
    }
  }
  return output;
}

function normalizeLegacyStatus(raw: string): AgentRunStatus {
  const value = String(raw || "").trim().toLowerCase().replace(/_/g, "-");
  if (["done", "complete", "completed", "promoted", "merged"].includes(value)) return "completed";
  if (["running", "in-progress", "active", "delegated"].includes(value)) return "running";
  if (value.includes("approval") || value.includes("review")) return "waiting-approval";
  if (value.includes("block") || value.includes("clarification") || value.includes("needs-avi") || value.includes("needs-human")) return "blocked";
  if (["failed", "error"].includes(value)) return "failed";
  if (["canceled", "cancelled", "rejected"].includes(value)) return "canceled";
  return "queued";
}

export interface LegacyAgentRunNormalizationResult {
  created: Array<{ id: string; file: string; runFile: string }>;
  skippedExisting: string[];
}

export function normalizeLegacyAgentRuns(corpusRoot: string, nowRaw?: string): LegacyAgentRunNormalizationResult {
  const root = path.resolve(corpusRoot);
  const existing = new Set(listAgentRuns(root).map((run) => run.id));
  const result: LegacyAgentRunNormalizationResult = { created: [], skippedExisting: [] };
  for (const file of walkOrgFiles(root)) {
    if (file.startsWith(agentRunDirectory(root) + path.sep)) continue;
    const lines = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const match = /^\s*:AGENT_RUN_ID:\s*(\S.*?)\s*$/i.exec(lines[index] || "");
      if (!match) continue;
      const id = String(match[1] || "").trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) continue;
      if (existing.has(id)) {
        if (!result.skippedExisting.includes(id)) result.skippedExisting.push(id);
        continue;
      }
      let headingIndex = index;
      while (headingIndex >= 0 && !/^\*+\s+/.test(lines[headingIndex] || "")) headingIndex -= 1;
      const heading = headingIndex >= 0 ? parseHeadlineTitleForRoam(lines[headingIndex] || "") : `Imported agent run ${id}`;
      const props = new Map<string, string>();
      let drawerStart = index;
      while (drawerStart >= headingIndex && !/^\s*:PROPERTIES:\s*$/i.test(lines[drawerStart] || "")) drawerStart -= 1;
      if (drawerStart >= headingIndex) {
        for (let propertyIndex = drawerStart + 1; propertyIndex < lines.length; propertyIndex += 1) {
          if (/^\s*:END:\s*$/i.test(lines[propertyIndex] || "")) break;
          const property = /^\s*:([^:]+):\s*(.*?)\s*$/.exec(lines[propertyIndex] || "");
          if (property) props.set(property[1]!.trim().toUpperCase(), property[2]!.trim());
        }
      }
      const status = normalizeLegacyStatus(props.get("STATUS") || props.get("AGENT_STATUS") || (headingIndex >= 0 ? lines[headingIndex] || "" : ""));
      let run = createAgentRun({
        id,
        goal: heading || `Imported agent run ${id}`,
        status,
        owner: props.get("OWNER"),
        assignee: props.get("ASSIGNEE"),
        providerPolicy: props.get("PROVIDER_POLICY"),
        context: [
          { ref: `file:${path.relative(root, file).split(path.sep).join("/")}::${headingIndex + 1}`, citation: `${path.relative(root, file).split(path.sep).join("/")}:${headingIndex + 1}` },
          ...([props.get("AGENT_SESSION_ID"), props.get("OPENCLAW_SESSION_ID"), props.get("SESSION_ID")].filter(Boolean).slice(0, 1).map((session) => ({ ref: `session:${session}` }))),
        ],
        parentRunId: props.get("PARENT_RUN_ID"),
        now: nowRaw,
      });
      const artifactRole = String(brandProperty(props, "ORG2_ARTIFACT_ROLE") || props.get("ARTIFACT_ROLE") || "").toLowerCase();
      if (["draft", "diff", "compiled", "view", "report", "export", "receipt"].includes(artifactRole)) {
        run = addAgentRunArtifact(run, {
          path: path.relative(root, file).split(path.sep).join("/"),
          role: artifactRole as AgentRunArtifact["role"],
          title: heading,
          reviewStatus: (["generated", "review-required", "reviewed", "promoted", "rejected"].includes(String(brandProperty(props, "ORG2_REVIEW_STATUS") || "").toLowerCase()) ? String(brandProperty(props, "ORG2_REVIEW_STATUS")).toLowerCase() : "review-required") as AgentRunArtifact["reviewStatus"],
        }, "org2");
      }
      const approvalStatus = String(props.get("APPROVAL_STATUS") || props.get("REVIEW_STATUS") || "").toLowerCase();
      const needsApproval = /^(1|true|yes|pending|required)$/i.test(String(props.get("NEEDS_APPROVAL") || "")) || approvalStatus === "pending" || status === "waiting-approval";
      if (needsApproval) {
        run = requestAgentRunApproval(run, {
          title: props.get("APPROVAL_TITLE") || `Review ${heading}`,
          action: props.get("APPROVAL_ACTION") || "Review the imported agent work before promotion or external action",
          riskClass: (AGENT_RUN_RISK_CLASSES.includes(props.get("RISK_CLASS") as AgentRunRiskClass) ? props.get("RISK_CLASS") : "canonical-write") as AgentRunRiskClass,
          requestedRole: props.get("APPROVAL_ROLE"),
          requestedFrom: props.get("APPROVER"),
        }, "org2");
      }
      run.events.push(event("legacy-imported", run.createdAt, "org2", `Imported from ${path.relative(root, file)}:${headingIndex + 1}`));
      const runFile = saveAgentRun(root, run, { expectedRevision: null });
      existing.add(id);
      result.created.push({ id, file, runFile });
    }
  }
  return result;
}
