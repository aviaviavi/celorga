import { listProjectNotes } from "./project.js";
import path from "node:path";
import {
  AGENT_RUN_STATUSES,
  queryAgentRuns,
  summarizeAgentRunForList,
  type AgentRun,
  type AgentRunAttemptRollup,
  type AgentRunListSummary,
} from "./agentRun.js";
import { listWorkflows, workflowSourcePath } from "./agentWorkflow.js";
import { listGoals, goalPath, listAgentProfiles, agentProfilePath } from "./coordination.js";

export interface WorkspaceRunListOptions {
  /** Match any of these statuses. Unknown statuses are rejected. */
  statuses?: readonly string[];
  /** Positive page size. Setting limit, offset, or summary adds `projection` and `page`. */
  limit?: number;
  offset?: number;
  /** Return compact summaries instead of full run records. */
  summary?: boolean;
}

export interface WorkspaceRunListPage {
  total: number;
  offset: number;
  limit: number | null;
  returned: number;
  hasMore: boolean;
  nextOffset: number | null;
}

export interface WorkspaceRunListPayload<Run> {
  schema: "org2:run-list:v1";
  runs: Run[];
  logicalWork: AgentRunAttemptRollup[];
  projection?: "full" | "summary";
  statuses?: string[];
  page?: WorkspaceRunListPage;
}

function nonNegativeInteger(value: number | undefined, label: string, minimum: number): number | undefined {
  if (value === undefined) return undefined;
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new Error(`${label} must be ${minimum > 0 ? "a positive" : "a non-negative"} integer`);
  }
  return value;
}

export function workspaceRunList(root: string, status?: string): WorkspaceRunListPayload<AgentRun>;
export function workspaceRunList(root: string, options: WorkspaceRunListOptions): WorkspaceRunListPayload<AgentRun | AgentRunListSummary>;
export function workspaceRunList(root: string, filter?: string | WorkspaceRunListOptions): WorkspaceRunListPayload<AgentRun | AgentRunListSummary> {
  if (filter === undefined || typeof filter === "string") {
    const result = queryAgentRuns(root, { statuses: filter ? [filter] : undefined, project: (run) => run });
    return { schema: "org2:run-list:v1", runs: result.items, logicalWork: result.logicalWork };
  }
  const statuses = [...new Set(filter.statuses || [])];
  for (const status of statuses) {
    if (!(AGENT_RUN_STATUSES as readonly string[]).includes(status)) {
      throw new Error(`invalid run status: ${status}; expected one of: ${AGENT_RUN_STATUSES.join(", ")}`);
    }
  }
  const limit = nonNegativeInteger(filter.limit, "limit", 1);
  const offset = nonNegativeInteger(filter.offset, "offset", 0);
  const summary = filter.summary === true;
  const result = queryAgentRuns<AgentRun | AgentRunListSummary>(root, {
    statuses,
    limit,
    offset,
    project: summary ? summarizeAgentRunForList : (run) => run,
  });
  const payload: WorkspaceRunListPayload<AgentRun | AgentRunListSummary> = {
    schema: "org2:run-list:v1",
    runs: result.items,
    logicalWork: result.logicalWork,
  };
  // A status filter alone keeps the original envelope; explicit paging or a
  // projection reports what was returned and how to continue.
  if (limit === undefined && offset === undefined && !summary) return payload;
  const start = offset ?? 0;
  const next = start + result.items.length;
  const hasMore = next < result.total;
  return {
    ...payload,
    projection: summary ? "summary" : "full",
    ...(statuses.length > 0 ? { statuses } : {}),
    page: {
      total: result.total,
      offset: start,
      limit: limit ?? null,
      returned: result.items.length,
      hasMore,
      nextOffset: hasMore ? next : null,
    },
  };
}

export function workspaceWorkflowList(root: string) {
  const workflows = listWorkflows(root).map((workflow) => {
    const file = workflowSourcePath(root, workflow.id);
    return { ...workflow, file, legacyLocation: file.includes(`${path.sep}.org2${path.sep}workflows${path.sep}`) };
  });
  return { schema: "org2:workflow-list:v1", workflows };
}

export function workspaceGoalList(root: string, status?: string) {
  const goals = listGoals(root).filter((goal) => !status || goal.status === status)
    .map((goal) => ({ ...goal, file: goalPath(root, goal.id) }));
  return { schema: "org2:goal-list:v1", goals };
}

export function workspaceProfileList(root: string, status?: string) {
  const profiles = listAgentProfiles(root).filter((profile) => !status || profile.status === status)
    .map((profile) => ({ ...profile, file: agentProfilePath(root, profile.id) }));
  return { schema: "org2:agent-profile-list:v1", profiles };
}

// Each section retains its ordinary list envelope. One unreadable section must
// not discard successful reads of the other independent workspace projections.
function section<T>(read: () => T) {
  const started = performance.now();
  try {
    return { value: read(), elapsedMilliseconds: performance.now() - started };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error), elapsedMilliseconds: performance.now() - started };
  }
}

export function workspaceAgentState(root: string) {
  return {
    schema: "org2:workspace-agent-state:v1",
    runs: section(() => workspaceRunList(root)),
    workflows: section(() => workspaceWorkflowList(root)),
    goals: section(() => workspaceGoalList(root)),
    profiles: section(() => workspaceProfileList(root)),
    projects: section(() => listProjectNotes(root)),
  };
}
