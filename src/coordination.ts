import fs from "node:fs";
import path from "node:path";
import { guardedWriteFile, readGuardedFile, type GuardedFileWriteOptions } from "./guardedFile.js";
import { safeIdentifier } from "./safeIdentifier.js";
import { orgRecordPath, schemaMatches } from "./brandNames.js";

export const ORG2_GOAL_SCHEMA = "org2:goal:v1" as const;
export const ORG2_AGENT_PROFILE_SCHEMA = "org2:agent-profile:v1" as const;
export const GOAL_STATUSES = ["planned", "active", "achieved", "canceled"] as const;
export const AGENT_PROFILE_STATUSES = ["active", "paused", "retired"] as const;
export const AGENT_PROFILE_DEFAULT_RUNTIMES = ["openclaw", "codex", "claude"] as const;

export type GoalStatus = typeof GOAL_STATUSES[number];
export type AgentProfileStatus = typeof AGENT_PROFILE_STATUSES[number];
export type AgentProfileDefaultRuntime = typeof AGENT_PROFILE_DEFAULT_RUNTIMES[number];

export interface GoalRecord {
  schema: typeof ORG2_GOAL_SCHEMA;
  id: string;
  title: string;
  description: string;
  status: GoalStatus;
  parentGoalRef?: string;
  ownerAgentRef?: string;
  measures: string[];
  createdAt: string;
  updatedAt: string;
}

export interface AgentRuntimeBinding {
  runtime: string;
  runtimeAgentId: string;
}

export interface AgentProfile {
  schema: typeof ORG2_AGENT_PROFILE_SCHEMA;
  id: string;
  name: string;
  description: string;
  status: AgentProfileStatus;
  responsibilities: string[];
  capabilities: string[];
  skills: string[];
  defaultRuntime?: AgentProfileDefaultRuntime;
  runtimeBindings: AgentRuntimeBinding[];
  goalRefs: string[];
  primaryGoalRef?: string;
  reportsToAgentRef?: string;
  createdAt: string;
  updatedAt: string;
}

export interface CoordinationSnapshot<T> {
  file: string;
  revision: string;
  raw: string;
  value: T;
}

export interface AgentProfileResolution {
  schema: "org2:agent-profile-resolution:v1";
  found: boolean;
  runtime: string;
  runtimeAgentId: string;
  agentRef?: string;
  goalRef?: string;
  profile?: AgentProfile;
}

function clean(raw: unknown): string {
  return String(raw || "").trim();
}

function unique(values: readonly string[] | undefined): string[] {
  return [...new Set((values || []).map(clean).filter(Boolean))];
}

function iso(raw?: string): string {
  const value = raw ? new Date(raw) : new Date();
  if (Number.isNaN(value.getTime())) throw new Error(`invalid timestamp: ${raw}`);
  return value.toISOString();
}

function orgText(raw: string): string {
  return clean(raw).replace(/\r?\n/g, " ");
}

function machineState<T>(raw: string, language: string): T {
  const escaped = language.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`#\\+begin_src\\s+json\\s+:${escaped}\\s*\\r?\\n([\\s\\S]*?)\\r?\\n#\\+end_src`, "i").exec(raw);
  if (!match) throw new Error(`file is missing its :${language} machine-state block`);
  return JSON.parse(match[1] || "{}") as T;
}

function assertGoal(goal: GoalRecord): GoalRecord {
  if (!schemaMatches(goal.schema, ORG2_GOAL_SCHEMA)) throw new Error(`goal schema must be ${ORG2_GOAL_SCHEMA}`);
  safeIdentifier(goal.id, { label: "goal id" });
  if (!clean(goal.title)) throw new Error("goal title is required");
  if (!GOAL_STATUSES.includes(goal.status)) throw new Error(`invalid goal status: ${goal.status}`);
  if (goal.parentGoalRef && goal.parentGoalRef === goal.id) throw new Error("a goal cannot be its own parent");
  if (!goal.createdAt || Number.isNaN(new Date(goal.createdAt).getTime())) throw new Error("goal createdAt must be an ISO timestamp");
  if (!goal.updatedAt || Number.isNaN(new Date(goal.updatedAt).getTime())) throw new Error("goal updatedAt must be an ISO timestamp");
  return goal;
}

function assertAgentProfile(profile: AgentProfile): AgentProfile {
  if (!schemaMatches(profile.schema, ORG2_AGENT_PROFILE_SCHEMA)) throw new Error(`agent profile schema must be ${ORG2_AGENT_PROFILE_SCHEMA}`);
  safeIdentifier(profile.id, { label: "agent profile id" });
  if (!clean(profile.name)) throw new Error("agent profile name is required");
  if (!AGENT_PROFILE_STATUSES.includes(profile.status)) throw new Error(`invalid agent profile status: ${profile.status}`);
  if (profile.defaultRuntime !== undefined && !AGENT_PROFILE_DEFAULT_RUNTIMES.includes(profile.defaultRuntime)) {
    throw new Error(`invalid agent default runtime: ${profile.defaultRuntime}`);
  }
  if (profile.reportsToAgentRef && profile.reportsToAgentRef === profile.id) throw new Error("an agent profile cannot report to itself");
  if (profile.primaryGoalRef && !profile.goalRefs.includes(profile.primaryGoalRef)) throw new Error("primaryGoalRef must also appear in goalRefs");
  const seenBindings = new Set<string>();
  for (const binding of profile.runtimeBindings) {
    const runtime = clean(binding.runtime).toLowerCase();
    const runtimeAgentId = clean(binding.runtimeAgentId);
    if (!runtime || !runtimeAgentId) throw new Error("runtime bindings require runtime and runtimeAgentId");
    const key = `${runtime}\0${runtimeAgentId.toLowerCase()}`;
    if (seenBindings.has(key)) throw new Error(`duplicate runtime binding: ${runtime}:${runtimeAgentId}`);
    seenBindings.add(key);
  }
  if (!profile.createdAt || Number.isNaN(new Date(profile.createdAt).getTime())) throw new Error("agent profile createdAt must be an ISO timestamp");
  if (!profile.updatedAt || Number.isNaN(new Date(profile.updatedAt).getTime())) throw new Error("agent profile updatedAt must be an ISO timestamp");
  return profile;
}

export function createGoal(input: {
  id: string;
  title: string;
  description?: string;
  status?: GoalStatus;
  parentGoalRef?: string;
  ownerAgentRef?: string;
  measures?: string[];
  now?: string;
}): GoalRecord {
  const now = iso(input.now);
  return assertGoal({
    schema: ORG2_GOAL_SCHEMA,
    id: safeIdentifier(input.id, { label: "goal id" }),
    title: clean(input.title),
    description: clean(input.description),
    status: input.status || "active",
    ...(clean(input.parentGoalRef) ? { parentGoalRef: clean(input.parentGoalRef) } : {}),
    ...(clean(input.ownerAgentRef) ? { ownerAgentRef: clean(input.ownerAgentRef) } : {}),
    measures: unique(input.measures),
    createdAt: now,
    updatedAt: now,
  });
}

export function createAgentProfile(input: {
  id: string;
  name: string;
  description?: string;
  status?: AgentProfileStatus;
  responsibilities?: string[];
  capabilities?: string[];
  skills?: string[];
  defaultRuntime?: AgentProfileDefaultRuntime;
  runtimeBindings?: AgentRuntimeBinding[];
  goalRefs?: string[];
  primaryGoalRef?: string;
  reportsToAgentRef?: string;
  now?: string;
}): AgentProfile {
  const now = iso(input.now);
  const primaryGoalRef = clean(input.primaryGoalRef);
  const goalRefs = unique([...(input.goalRefs || []), ...(primaryGoalRef ? [primaryGoalRef] : [])]);
  return assertAgentProfile({
    schema: ORG2_AGENT_PROFILE_SCHEMA,
    id: safeIdentifier(input.id, { label: "agent profile id" }),
    name: clean(input.name),
    description: clean(input.description),
    status: input.status || "active",
    responsibilities: unique(input.responsibilities),
    capabilities: unique(input.capabilities),
    skills: unique(input.skills),
    ...(input.defaultRuntime ? { defaultRuntime: input.defaultRuntime } : {}),
    runtimeBindings: (input.runtimeBindings || []).map((binding) => ({
      runtime: clean(binding.runtime).toLowerCase(),
      runtimeAgentId: clean(binding.runtimeAgentId),
    })),
    goalRefs,
    ...(primaryGoalRef ? { primaryGoalRef } : {}),
    ...(clean(input.reportsToAgentRef) ? { reportsToAgentRef: clean(input.reportsToAgentRef) } : {}),
    createdAt: now,
    updatedAt: now,
  });
}

export function renderGoalOrg(goal: GoalRecord): string {
  assertGoal(goal);
  return [
    `#+TITLE: Goal: ${orgText(goal.title)}`,
    "#+ORG2_KIND: goal",
    "",
    `* ${goal.status === "achieved" ? "DONE" : "TODO"} ${orgText(goal.title)} :goal:`,
    ":PROPERTIES:",
    `:ID: ${goal.id}`,
    ":KIND: goal",
    `:GOAL_SCHEMA: ${goal.schema}`,
    `:GOAL_STATUS: ${goal.status}`,
    ...(goal.parentGoalRef ? [`:PARENT_GOAL_REF: ${orgText(goal.parentGoalRef)}`] : []),
    ...(goal.ownerAgentRef ? [`:OWNER_AGENT_REF: ${orgText(goal.ownerAgentRef)}`] : []),
    `:CREATED_AT: ${goal.createdAt}`,
    `:UPDATED_AT: ${goal.updatedAt}`,
    ":END:",
    "",
    goal.description || "No description recorded.",
    "",
    "** Measures",
    ...(goal.measures.length ? goal.measures.map((measure) => `- ${measure}`) : ["- None recorded."]),
    "",
    "** Machine state",
    "#+begin_src json :org2-goal",
    JSON.stringify(goal, null, 2),
    "#+end_src",
    "",
  ].join("\n");
}

export function renderAgentProfileOrg(profile: AgentProfile): string {
  assertAgentProfile(profile);
  return [
    `#+TITLE: Agent profile: ${orgText(profile.name)}`,
    "#+ORG2_KIND: agent-profile",
    "",
    `* ${orgText(profile.name)} :agent-profile:`,
    ":PROPERTIES:",
    `:ID: ${profile.id}`,
    ":KIND: agent-profile",
    `:AGENT_PROFILE_SCHEMA: ${profile.schema}`,
    `:AGENT_STATUS: ${profile.status}`,
    ...(profile.defaultRuntime ? [`:DEFAULT_RUNTIME: ${profile.defaultRuntime}`] : []),
    ...(profile.primaryGoalRef ? [`:GOAL_REF: ${orgText(profile.primaryGoalRef)}`] : []),
    ...(profile.reportsToAgentRef ? [`:REPORTS_TO_AGENT_REF: ${orgText(profile.reportsToAgentRef)}`] : []),
    `:CREATED_AT: ${profile.createdAt}`,
    `:UPDATED_AT: ${profile.updatedAt}`,
    ":END:",
    "",
    profile.description || "No description recorded.",
    "",
    "** Execution",
    `- Default runtime: ${profile.defaultRuntime || "None recorded."}`,
    "",
    "** Responsibilities",
    ...(profile.responsibilities.length ? profile.responsibilities.map((item) => `- ${item}`) : ["- None recorded."]),
    "",
    "** Runtime bindings",
    ...(profile.runtimeBindings.length ? profile.runtimeBindings.map((item) => `- ${item.runtime}: ${item.runtimeAgentId}`) : ["- None recorded."]),
    "",
    "** Goals",
    ...(profile.goalRefs.length ? profile.goalRefs.map((item) => `- ${item}${item === profile.primaryGoalRef ? " (primary)" : ""}`) : ["- None recorded."]),
    "",
    "** Capabilities",
    ...(profile.capabilities.length ? profile.capabilities.map((item) => `- ${item}`) : ["- None recorded."]),
    "",
    "** Skills",
    ...(profile.skills.length ? profile.skills.map((item) => `- ${item}`) : ["- None recorded."]),
    "",
    "** Machine state",
    "#+begin_src json :org2-agent-profile",
    JSON.stringify(profile, null, 2),
    "#+end_src",
    "",
  ].join("\n");
}

export function parseGoalOrg(raw: string): GoalRecord {
  return assertGoal(machineState<GoalRecord>(raw, "org2-goal"));
}

export function parseAgentProfileOrg(raw: string): AgentProfile {
  return assertAgentProfile(machineState<AgentProfile>(raw, "org2-agent-profile"));
}

export function goalDirectory(root: string): string { return path.join(path.resolve(root), "goals"); }
export function agentProfileDirectory(root: string): string { return path.join(path.resolve(root), "agent-profiles"); }
export function goalPath(root: string, id: string): string { return orgRecordPath(goalDirectory(root), safeIdentifier(id, { label: "goal id" })); }
export function agentProfilePath(root: string, id: string): string { return orgRecordPath(agentProfileDirectory(root), safeIdentifier(id, { label: "agent profile id" })); }

export function saveGoal(root: string, goal: GoalRecord, options: GuardedFileWriteOptions = {}): string {
  return guardedWriteFile(goalPath(root, goal.id), renderGoalOrg(goal), options).file;
}

export function saveAgentProfile(root: string, profile: AgentProfile, options: GuardedFileWriteOptions = {}): string {
  return guardedWriteFile(agentProfilePath(root, profile.id), renderAgentProfileOrg(profile), options).file;
}

export function loadGoalSnapshot(root: string, id: string): CoordinationSnapshot<GoalRecord> {
  const snapshot = readGuardedFile(goalPath(root, id));
  return { ...snapshot, raw: snapshot.content, value: parseGoalOrg(snapshot.content) };
}

export function loadAgentProfileSnapshot(root: string, id: string): CoordinationSnapshot<AgentProfile> {
  const snapshot = readGuardedFile(agentProfilePath(root, id));
  return { ...snapshot, raw: snapshot.content, value: parseAgentProfileOrg(snapshot.content) };
}

function listRecords<T>(directory: string, parse: (raw: string) => T): T[] {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.org2?$/i.test(entry.name))
    .map((entry) => parse(fs.readFileSync(path.join(directory, entry.name), "utf8")));
}

export function listGoals(root: string): GoalRecord[] {
  return listRecords(goalDirectory(root), parseGoalOrg).sort((left, right) => left.title.localeCompare(right.title));
}

export function listAgentProfiles(root: string): AgentProfile[] {
  return listRecords(agentProfileDirectory(root), parseAgentProfileOrg).sort((left, right) => left.name.localeCompare(right.name));
}

export function resolveAgentProfile(root: string, runtimeRaw: string, runtimeAgentIdRaw: string): AgentProfileResolution {
  const runtime = clean(runtimeRaw).toLowerCase();
  const runtimeAgentId = clean(runtimeAgentIdRaw);
  if (!runtime || !runtimeAgentId) throw new Error("runtime and runtime agent id are required");
  const matches = listAgentProfiles(root).filter((profile) =>
    profile.status === "active" && profile.runtimeBindings.some((binding) =>
      binding.runtime.toLowerCase() === runtime && binding.runtimeAgentId.toLowerCase() === runtimeAgentId.toLowerCase()));
  if (matches.length > 1) throw new Error(`runtime identity ${runtime}:${runtimeAgentId} is bound to multiple active agent profiles: ${matches.map((profile) => profile.id).join(", ")}`);
  const profile = matches[0];
  if (profile?.primaryGoalRef && !listGoals(root).some((goal) => goal.id === profile.primaryGoalRef)) {
    throw new Error(`agent profile ${profile.id} references missing primary goal: ${profile.primaryGoalRef}`);
  }
  return {
    schema: "org2:agent-profile-resolution:v1",
    found: Boolean(profile),
    runtime,
    runtimeAgentId,
    ...(profile ? {
      agentRef: profile.id,
      ...(profile.primaryGoalRef ? { goalRef: profile.primaryGoalRef } : {}),
      profile,
    } : {}),
  };
}
