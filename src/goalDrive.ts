import crypto from "node:crypto";
import path from "node:path";
import {
  GOAL_DRIVE_DEFAULT_STALL_AFTER,
  loadGoalSnapshot,
  type GoalDrive,
  type GoalRecord,
} from "./coordination.js";
import {
  promptAutomation,
  WORKFLOW_SCHEDULE_TRIGGER_ID,
  type AgentWorkflow,
} from "./agentWorkflow.js";
import { AGENT_RUN_SCHEDULE_SLOT_STATUSES, type AgentRun } from "./agentRun.js";
import { extractTodoHeadings } from "./workflowEventTriggers.js";
import { isTerminalTodoKeyword, todoSequencesForFile } from "./todo.js";
import { safeIdentifier } from "./safeIdentifier.js";

export const ORG2_GOAL_DRIVE_STATUS_SCHEMA = "org2:goal-drive-status:v1" as const;
export const GOAL_PLAN_ACTORS = ["agent", "human", "external"] as const;
export const GOAL_DRIVE_DEFAULT_SCHEDULE = "every 15m";
const DAY_MS = 24 * 60 * 60 * 1_000;

export type GoalPlanActor = typeof GOAL_PLAN_ACTORS[number];

/**
 * What the next driver pass should do. `work`, `plan`, and `replan` admit a
 * pass; every other mode makes the scheduler skip the pass without spending.
 */
export type GoalDriveMode =
  | "work"
  | "plan"
  | "replan"
  | "waiting"
  | "complete"
  | "stalled"
  | "paused"
  | "over-budget"
  | "inactive"
  | "not-driving";

export interface GoalPlanItem {
  title: string;
  state: string;
  actor: GoalPlanActor;
  open: boolean;
  line: number;
  id?: string;
}

export interface GoalPlan {
  /** Whether the goal heading has a level-2 Plan section. */
  present: boolean;
  line?: number;
  items: GoalPlanItem[];
  open: Record<GoalPlanActor, number>;
  done: number;
  checkboxes: { checked: number; total: number };
  /** Hash of item titles, states, actors, and checkbox states. Prose notes do not count as progress. */
  fingerprint: string;
  issues: string[];
}

export interface GoalDriveSpend {
  windowHours: 24;
  passes: number;
  costUsd: number;
  tokens: number;
}

export interface GoalDriveStatus {
  schema: typeof ORG2_GOAL_DRIVE_STATUS_SCHEMA;
  goalId: string;
  title: string;
  goalStatus: GoalRecord["status"];
  file: string;
  drive: GoalDrive | null;
  plan: GoalPlan;
  spend: GoalDriveSpend;
  activeRun?: { id: string; status: string };
  /** Settled driver passes since the last checkpoint that never checkpointed. */
  uncheckpointedPasses: number;
  mode: GoalDriveMode;
  eligible: boolean;
  reason: string;
  /** Open agent items, top first. */
  next: GoalPlanItem[];
  /** Open human items: decisions, access, or approvals a person must provide. */
  needsYou: GoalPlanItem[];
}

function sha256(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function actorFor(raw: string | undefined, issues: string[], title: string): GoalPlanActor {
  const value = String(raw || "").trim().toLowerCase();
  if (!value) return "agent";
  if ((GOAL_PLAN_ACTORS as readonly string[]).includes(value)) return value as GoalPlanActor;
  issues.push(`plan item "${title}" has unknown :ACTOR: ${raw}; treating it as human`);
  return "human";
}

/**
 * Reads the Plan section of a goal file: the level-2 heading named Plan under
 * the goal heading. Every descendant heading with a TODO keyword is a plan
 * item; its :ACTOR: property is agent (default), human, or external.
 */
export function parseGoalPlan(raw: string, sourcePath?: string): GoalPlan {
  const headings = extractTodoHeadings(raw, sourcePath);
  const goalHeading = headings.find((heading) => heading.level === 1);
  const planHeading = headings.find((heading) =>
    heading.level === 2 && heading.title.replace(/\s+:[\w@#%:]+:\s*$/, "").trim().toLowerCase() === "plan"
    && (!goalHeading || heading.line > goalHeading.line));
  const issues: string[] = [];
  const empty = { agent: 0, human: 0, external: 0 };
  if (!planHeading) {
    return { present: false, items: [], open: empty, done: 0, checkboxes: { checked: 0, total: 0 }, fingerprint: sha256("no-plan"), issues };
  }
  const after = headings.find((heading) => heading.line > planHeading.line && heading.level <= 2);
  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  const endLine = after ? after.line - 1 : lines.length;
  const sequences = todoSequencesForFile(sourcePath, true);
  const items: GoalPlanItem[] = headings
    .filter((heading) => heading.line > planHeading.line && heading.line <= endLine && heading.level > 2 && heading.state)
    .map((heading) => ({
      title: heading.title,
      state: heading.state!,
      actor: actorFor(heading.properties.ACTOR, issues, heading.title),
      open: !isTerminalTodoKeyword(heading.state, sequences),
      line: heading.line,
      ...(heading.id ? { id: heading.id } : {}),
    }));
  const boxes = lines.slice(planHeading.line, endLine)
    .map((line) => /^\s*(?:[-+]|\d+[.)])\s+\[([ xX-])\]/.exec(line)?.[1])
    .filter((value): value is string => value !== undefined);
  const open = { ...empty };
  for (const item of items) if (item.open) open[item.actor] += 1;
  return {
    present: true,
    line: planHeading.line,
    items,
    open,
    done: items.filter((item) => !item.open).length,
    checkboxes: { checked: boxes.filter((box) => box.toLowerCase() === "x").length, total: boxes.length },
    fingerprint: sha256(JSON.stringify({
      items: items.map((item) => [item.title, item.state, item.actor]),
      boxes,
    })),
    issues,
  };
}

function driverRuns(runs: readonly AgentRun[], drive: GoalDrive): AgentRun[] {
  return runs.filter((run) => run.workflowId === drive.workflowRef || run.logicalWorkId === `workflow:${drive.workflowRef}`);
}

function time(value: string | undefined): number {
  const parsed = value ? new Date(value).getTime() : Number.NaN;
  return Number.isFinite(parsed) ? parsed : 0;
}

/** When a pass happened: its creation, or its planned occurrence when that is later (as with replayed schedules). */
function passTime(run: AgentRun): number {
  return Math.max(time(run.createdAt), time(run.attempt?.scheduledFor));
}

/**
 * Deterministic drive evaluation: no model decides whether a pass runs.
 * Reads the goal file, its plan, and the driver's run records.
 */
export function evaluateGoalDrive(
  goal: GoalRecord,
  raw: string,
  file: string,
  runs: readonly AgentRun[],
  options: { now?: string } = {},
): GoalDriveStatus {
  const now = time(options.now) || Date.now();
  const plan = parseGoalPlan(raw, file);
  const drive = goal.drive || null;
  const passes = drive ? driverRuns(runs, drive) : [];
  const windowed = passes.filter((run) => passTime(run) > now - DAY_MS);
  const spend: GoalDriveSpend = {
    windowHours: 24,
    passes: windowed.length,
    costUsd: Math.round(windowed.reduce((sum, run) => sum + (run.budget?.costUsedUsd || 0), 0) * 10_000) / 10_000,
    tokens: windowed.reduce((sum, run) => sum + (run.budget?.tokensUsed || 0), 0),
  };
  const active = passes.find((run) => AGENT_RUN_SCHEDULE_SLOT_STATUSES.has(run.status));
  const since = Math.max(time(drive?.lastCheckpointAt), time(drive?.resumedAt), time(drive?.startedAt));
  const uncheckpointedPasses = passes.filter((run) =>
    !AGENT_RUN_SCHEDULE_SLOT_STATUSES.has(run.status) && run.status !== "blocked"
    && passTime(run) >= since && run.id !== drive?.lastCheckpointRunId).length;
  const next = plan.items.filter((item) => item.open && item.actor === "agent");
  const needsYou = plan.items.filter((item) => item.open && item.actor === "human");
  const decide = (): { mode: GoalDriveMode; eligible: boolean; reason: string } => {
    if (!drive) return { mode: "not-driving", eligible: false, reason: "goal is not being driven; start with celorga goal drive" };
    if (goal.status !== "active") return { mode: "inactive", eligible: false, reason: `goal is ${goal.status}` };
    if (drive.state === "paused") return { mode: "paused", eligible: false, reason: "drive is paused" };
    if (drive.state === "stalled") return { mode: "stalled", eligible: false, reason: drive.stalledReason || "drive stalled; review the plan and resume" };
    if (uncheckpointedPasses >= drive.stallAfter) {
      return { mode: "stalled", eligible: false, reason: `${uncheckpointedPasses} passes ended without a goal checkpoint; inspect the driver runs and resume` };
    }
    if (drive.dailyCostLimitUsd !== undefined && spend.costUsd >= drive.dailyCostLimitUsd) {
      return { mode: "over-budget", eligible: false, reason: `spent $${spend.costUsd} of $${drive.dailyCostLimitUsd} in the last 24 hours` };
    }
    if (drive.dailyTokenLimit !== undefined && spend.tokens >= drive.dailyTokenLimit) {
      return { mode: "over-budget", eligible: false, reason: `used ${spend.tokens} of ${drive.dailyTokenLimit} tokens in the last 24 hours` };
    }
    if (next.length) return { mode: "work", eligible: true, reason: `${next.length} open agent item${next.length === 1 ? "" : "s"}; next: ${next[0]!.title}` };
    const changed = !drive.lastCheckpointAt || drive.planFingerprint !== plan.fingerprint;
    if (!plan.items.length) {
      return changed
        ? { mode: "plan", eligible: true, reason: "no plan items yet; the next pass writes the plan" }
        : { mode: "plan", eligible: false, reason: "the last pass left the plan empty; add plan items or resume after editing the goal" };
    }
    if (changed) return { mode: "replan", eligible: true, reason: "no open agent items, but the plan changed since the last checkpoint" };
    const waiting = plan.open.human + plan.open.external;
    if (waiting) {
      return { mode: "waiting", eligible: false, reason: `waiting on ${plan.open.human} human and ${plan.open.external} external plan item${waiting === 1 ? "" : "s"}; editing the plan resumes the drive` };
    }
    return { mode: "complete", eligible: false, reason: "every plan item is done; confirm the goal's measures and mark it achieved, or add plan items" };
  };
  const decision = decide();
  return {
    schema: ORG2_GOAL_DRIVE_STATUS_SCHEMA,
    goalId: goal.id,
    title: goal.title,
    goalStatus: goal.status,
    file,
    drive,
    plan,
    spend,
    ...(active ? { activeRun: { id: active.id, status: active.status } } : {}),
    uncheckpointedPasses,
    ...decision,
    next,
    needsYou,
  };
}

export function goalDriveStatus(root: string, goalId: string, runs: readonly AgentRun[], options: { now?: string } = {}): GoalDriveStatus {
  const snapshot = loadGoalSnapshot(root, goalId);
  return evaluateGoalDrive(snapshot.value, snapshot.raw, snapshot.file, runs, options);
}

/**
 * The scheduler gate for a driver workflow. Returns null when the workflow
 * does not drive a goal, so ordinary automations are unaffected.
 */
export function goalDriveGate(
  root: string,
  workflow: Pick<AgentWorkflow, "id" | "goalRef">,
  runs: readonly AgentRun[],
  options: { now?: string } = {},
): { eligible: boolean; reason: string; goalId: string; mode: GoalDriveMode } | null {
  if (!workflow.goalRef) return null;
  let snapshot: ReturnType<typeof loadGoalSnapshot>;
  try { snapshot = loadGoalSnapshot(root, workflow.goalRef); } catch { return null; }
  if (snapshot.value.drive?.workflowRef !== workflow.id) return null;
  const status = evaluateGoalDrive(snapshot.value, snapshot.raw, snapshot.file, runs, options);
  return { eligible: status.eligible, reason: `goal ${status.goalId}: ${status.reason}`, goalId: status.goalId, mode: status.mode };
}

export interface GoalCheckpointResult {
  goal: GoalRecord;
  idempotent: boolean;
  progress: boolean;
  stalled: boolean;
  previousFingerprint?: string;
  fingerprint: string;
}

/**
 * Records the end of a driver pass. A pass that changed the plan resets the
 * no-progress count; otherwise the count rises and the drive stalls at
 * stallAfter. Checkpointing the same run twice changes nothing.
 */
export function checkpointGoalDrive(
  goal: GoalRecord,
  raw: string,
  file: string,
  run: Pick<AgentRun, "id" | "goalRef" | "workflowId">,
  options: { now?: string } = {},
): GoalCheckpointResult {
  const drive = goal.drive;
  if (!drive) throw new Error(`goal ${goal.id} is not being driven`);
  if (run.goalRef !== goal.id && run.workflowId !== drive.workflowRef) {
    throw new Error(`run ${run.id} does not belong to goal ${goal.id} or its driver workflow ${drive.workflowRef}`);
  }
  const plan = parseGoalPlan(raw, file);
  if (drive.lastCheckpointRunId === run.id) {
    return { goal, idempotent: true, progress: false, stalled: drive.state === "stalled", previousFingerprint: drive.planFingerprint, fingerprint: plan.fingerprint };
  }
  const at = new Date(options.now || Date.now()).toISOString();
  const progress = drive.planFingerprint !== plan.fingerprint;
  const passesWithoutProgress = progress ? 0 : drive.passesWithoutProgress + 1;
  const stalled = drive.state === "driving" && passesWithoutProgress >= drive.stallAfter;
  const { stalledReason: _previousReason, ...rest } = drive;
  const nextDrive: GoalDrive = {
    ...rest,
    state: stalled ? "stalled" : drive.state,
    passesWithoutProgress,
    planFingerprint: plan.fingerprint,
    lastCheckpointRunId: run.id,
    lastCheckpointAt: at,
    ...(stalled
      ? { stalledReason: `${passesWithoutProgress} consecutive passes left the plan unchanged` }
      : drive.state === "stalled" && drive.stalledReason ? { stalledReason: drive.stalledReason } : {}),
    updatedAt: at,
  };
  return {
    goal: { ...goal, drive: nextDrive, updatedAt: at },
    idempotent: false,
    progress,
    stalled,
    previousFingerprint: drive.planFingerprint,
    fingerprint: plan.fingerprint,
  };
}

export interface GoalDriveOptions {
  schedule?: string;
  timezone?: string;
  stallAfter?: number;
  dailyCostLimitUsd?: number;
  dailyTokenLimit?: number;
  permissions?: string[];
  destinationRef?: string;
  model?: string;
  reasoningEffort?: string;
  agentRef?: string;
  threadId?: string;
  workflowId?: string;
  now?: string;
}

export function goalDriverWorkflowId(goalId: string): string {
  return safeIdentifier(`goal-drive-${goalId}`, { label: "goal drive workflow id" });
}

export function goalDriverInstructions(goal: GoalRecord, drive: GoalDrive, options: { goalFile: string; threadId?: string }): string {
  const permissions = drive.permissions.length
    ? drive.permissions.map((item) => `   - ${item}`).join("\n")
    : "   - None. Research, analysis, drafting, and edits to this corpus are allowed; nothing that leaves the corpus is.";
  return [
    `Drive the Celorga goal "${goal.title}" (goal ID ${goal.id}) forward by one pass. Work from the corpus root, or pass --dir CORPUS to every command.`,
    "",
    `1. Run \`celorga goal status ${goal.id} --json\` and follow its mode.`,
    "   - work: take the first item in `next` and make real, verifiable progress on it.",
    "   - plan or replan: read the goal, its measures and other sections, and recent driver run outcomes, then write or revise the plan.",
    "   - any other mode: do no work. Checkpoint and complete the run with a one-line summary.",
    `2. The plan is the Plan section under the goal heading in ${options.goalFile}. Each plan item is a heading with a TODO keyword and an :ACTOR: property: agent (you may do it), human (a person must decide, grant access, or approve; state the exact question or action), or external (waiting on someone outside). Put the highest-priority item first. Mark finished items DONE, add the next concrete items you discover, and track partial progress with checkboxes. Preserve IDs and Org syntax. Mark abandoned items CANCELED with a reason instead of deleting them.`,
    "3. Standing permissions for this goal:",
    permissions,
    "   Anything beyond them, such as spending, sending, publishing, deleting, or production changes, is not yours to do. Add a human item describing the exact action and why, then continue with other agent items. Do not request run approvals or block this run waiting for a person.",
    `4. Celorga measures progress by plan changes: item states, new items, and checkboxes. Prose notes do not count, so do not log "no progress" in the plan. After ${drive.stallAfter} pass${drive.stallAfter === 1 ? "" : "es"} without a plan change, the drive stalls and waits for a person.`,
    `5. Finish with \`celorga goal checkpoint ${goal.id} --run RUN_ID --apply\`, using this run's ORG2_WORKFLOW_RUN_ID. Then complete the run with a concise summary: what changed, the next agent item, and anything a person must decide.`,
    ...(options.threadId ? [
      `6. Only when this pass added a human item or the checkpoint reports a stall, post one short message after the run is durable: \`celorga thread post ${options.threadId} --message TEXT --author "Goal driver" --source run:RUN_ID --idempotency-key goal-drive:${goal.id}:RUN_ID --apply\`. Stay silent otherwise.`,
    ] : []),
  ].join("\n");
}

/** Builds (or rebuilds) the driver workflow for a goal, keeping trigger history from an existing one. */
export function goalDriverWorkflow(
  goal: GoalRecord,
  drive: GoalDrive,
  options: GoalDriveOptions & { goalFile: string },
  existing?: AgentWorkflow,
): AgentWorkflow {
  const schedule = options.schedule?.trim()
    || existing?.triggers.find((trigger) => trigger.id === WORKFLOW_SCHEDULE_TRIGGER_ID)?.schedule
    || GOAL_DRIVE_DEFAULT_SCHEDULE;
  const built = promptAutomation({
    id: drive.workflowRef,
    title: `Drive goal: ${goal.title}`.slice(0, 120),
    description: `Driver passes for goal ${goal.id}. Celorga skips a pass while the goal is paused, stalled, over budget, or waiting on a person.`,
    instructions: goalDriverInstructions(goal, drive, { goalFile: options.goalFile, threadId: options.threadId }),
    destinationRef: options.destinationRef ?? existing?.destinationRef,
    model: options.model ?? existing?.model,
    reasoningEffort: options.reasoningEffort ?? existing?.reasoningEffort,
    agentRef: options.agentRef ?? existing?.agentRef,
    goalRef: goal.id,
    schedule,
    timezone: options.timezone ?? existing?.triggers.find((trigger) => trigger.id === WORKFLOW_SCHEDULE_TRIGGER_ID)?.timezone,
    state: "active",
    now: options.now,
  });
  const previous = new Map((existing?.triggers || []).map((trigger) => [trigger.id, trigger]));
  return {
    ...built,
    // One pass at a time: passes edit the same plan, and a pass parked on an
    // approval or blocker should hold the drive instead of piling up.
    triggers: built.triggers.map((trigger) => trigger.type !== "schedule" ? trigger : {
      ...trigger,
      whenRunning: "wait" as const,
      whenBlocked: "wait" as const,
      ...(previous.get(trigger.id)?.lastAttemptAt ? { lastAttemptAt: previous.get(trigger.id)!.lastAttemptAt } : {}),
      ...(previous.get(trigger.id)?.lastRunAt ? { lastRunAt: previous.get(trigger.id)!.lastRunAt } : {}),
    }),
    ...(existing ? { createdAt: existing.createdAt, version: existing.version } : {}),
  };
}

/** Starts or reconfigures a drive. Resets the no-progress count and clears a stall. */
export function startGoalDrive(goal: GoalRecord, options: GoalDriveOptions = {}): GoalRecord {
  if (goal.status !== "active") throw new Error(`goal ${goal.id} is ${goal.status}; set it active before driving it`);
  const now = new Date(options.now || Date.now()).toISOString();
  const previous = goal.drive;
  const { stalledReason: _stalledReason, ...kept } = previous || ({} as Partial<GoalDrive>);
  const drive: GoalDrive = {
    ...kept,
    state: "driving",
    workflowRef: options.workflowId || previous?.workflowRef || goalDriverWorkflowId(goal.id),
    stallAfter: options.stallAfter ?? previous?.stallAfter ?? GOAL_DRIVE_DEFAULT_STALL_AFTER,
    permissions: options.permissions ?? previous?.permissions ?? [],
    passesWithoutProgress: 0,
    startedAt: previous?.startedAt || now,
    ...(previous ? { resumedAt: now } : {}),
    updatedAt: now,
  };
  if (options.dailyCostLimitUsd !== undefined) drive.dailyCostLimitUsd = options.dailyCostLimitUsd;
  if (options.dailyTokenLimit !== undefined) drive.dailyTokenLimit = options.dailyTokenLimit;
  return { ...goal, drive, updatedAt: now };
}

export function setGoalDriveState(goal: GoalRecord, state: "paused" | "driving", options: { now?: string } = {}): GoalRecord {
  if (!goal.drive) throw new Error(`goal ${goal.id} is not being driven`);
  const now = new Date(options.now || Date.now()).toISOString();
  const { stalledReason: _stalledReason, ...rest } = goal.drive;
  return {
    ...goal,
    drive: {
      ...rest,
      state,
      ...(state === "driving" ? { passesWithoutProgress: 0, resumedAt: now } : {}),
      updatedAt: now,
    },
    updatedAt: now,
  };
}

export function stopGoalDrive(goal: GoalRecord, options: { now?: string } = {}): GoalRecord {
  const now = new Date(options.now || Date.now()).toISOString();
  const { drive: _drive, ...rest } = goal;
  return { ...rest, updatedAt: now };
}

/** Adds an empty Plan section to a goal file when none exists. */
export function ensureGoalPlanSection(raw: string): string {
  if (parseGoalPlan(raw).present) return raw;
  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  const machine = lines.findIndex((line) => /^\*\* +Machine state\s*$/i.test(line));
  const section = [
    "** Plan",
    "Ordered plan items for driver passes, highest priority first. Give each a TODO keyword and an :ACTOR: of agent, human, or external.",
    "",
  ];
  if (machine < 0) return `${raw.replace(/\s*$/, "\n\n")}${section.join("\n")}`;
  lines.splice(machine, 0, ...section);
  return lines.join("\n");
}

export function goalFileRelative(root: string, file: string): string {
  const relative = path.relative(path.resolve(root), file);
  return relative && !relative.startsWith("..") ? relative : file;
}
