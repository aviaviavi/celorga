import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { corpusIdentityStatus, type Org2CorpusIdentity } from "./corpusIdentity.js";

export interface WorkspaceCorpusRef extends Org2CorpusIdentity {
  root: string;
}

export interface WorkspaceReadIssue {
  root: string;
  message: string;
}

type AgendaItem = Record<string, unknown>;
type AgendaDay = { date: string; weekday: string; items: AgendaItem[] };
type AgendaPayload = {
  range: { start: string; end: string; days: number };
  overdue: AgendaDay[];
  days: AgendaDay[];
  skippedFiles?: number;
  workload?: { totalMinutes: number; byDate: Record<string, number>; byGroup: Record<string, number>; byTag: Record<string, number> };
};

type SearchPayload = {
  query: string;
  mode: string;
  sort: string;
  results: Array<Record<string, unknown>>;
};

export interface FederatedCommandOptions {
  mounts: string[];
  forwardedArgs: string[];
  limit?: number;
}

type FederatedPayload<T> = { corpus: WorkspaceCorpusRef; payload: T };
type FederatedOutcome<T> = FederatedPayload<T> | { corpus: WorkspaceCorpusRef; error: unknown };

function cliPath(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "cli.js");
}

const execFileAsync = promisify(execFile);

async function runCorpusJSON<T>(command: string, root: string, forwardedArgs: string[]): Promise<T> {
  // Federation composes the canonical CLI engines; it does not reimplement
  // agenda, search, config discovery, repeaters, or filtering semantics.
  const { stdout } = await execFileAsync(
    process.execPath,
    [cliPath(), command, ...forwardedArgs, "--dir", root, "--format", "json"],
    { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  return JSON.parse(stdout) as T;
}

function readErrorMessage(error: unknown): string {
  if (error && typeof error === "object" && "stderr" in error) {
    const stderr = String((error as { stderr?: unknown }).stderr || "").trim();
    if (stderr) return stderr;
  }
  return error instanceof Error ? error.message : String(error);
}

export function resolveFederatedCorpora(mounts: string[]): { corpora: WorkspaceCorpusRef[]; issues: WorkspaceReadIssue[] } {
  const corpora: WorkspaceCorpusRef[] = [];
  const issues: WorkspaceReadIssue[] = [];
  const seenRoots = new Set<string>();
  const seenIDs = new Map<string, string>();
  for (const mount of mounts) {
    const root = path.resolve(mount);
    if (seenRoots.has(root)) continue;
    seenRoots.add(root);
    const status = corpusIdentityStatus(root);
    if (!status.valid || !status.identity) {
      issues.push({ root, message: status.issues.map((issue) => `${issue.path}: ${issue.message}`).join("; ") || "invalid corpus identity" });
      continue;
    }
    const previousRoot = seenIDs.get(status.identity.id);
    if (previousRoot && previousRoot !== root) {
      issues.push({ root, message: `duplicates corpus id ${status.identity.id} mounted at ${previousRoot}` });
      continue;
    }
    seenIDs.set(status.identity.id, root);
    corpora.push({ ...status.identity, root });
  }
  return { corpora, issues };
}

async function collectFederatedPayloads<T>(
  mounts: string[],
  load: (corpus: WorkspaceCorpusRef) => Promise<T>,
): Promise<{ corpora: WorkspaceCorpusRef[]; issues: WorkspaceReadIssue[]; payloads: FederatedPayload<T>[] }> {
  const { corpora, issues } = resolveFederatedCorpora(mounts);
  const outcomes: FederatedOutcome<T>[] = await Promise.all(corpora.map(async (corpus) => {
    try { return { corpus, payload: await load(corpus) }; }
    catch (error) { return { corpus, error }; }
  }));
  const payloads: FederatedPayload<T>[] = [];
  for (const outcome of outcomes) {
    if ("error" in outcome) issues.push({ root: outcome.corpus.root, message: readErrorMessage(outcome.error) });
    else payloads.push(outcome);
  }
  issues.sort((left, right) => left.root.localeCompare(right.root) || left.message.localeCompare(right.message));
  return { corpora, issues, payloads };
}

function addCorpus<T extends Record<string, unknown>>(item: T, corpus: WorkspaceCorpusRef): T & { corpus: WorkspaceCorpusRef } {
  return { ...item, corpus };
}

function mergeAgendaDays(payloads: Array<{ corpus: WorkspaceCorpusRef; days: AgendaDay[] }>): AgendaDay[] {
  const byDate = new Map<string, AgendaDay>();
  for (const { corpus, days } of payloads) {
    for (const day of days) {
      const current = byDate.get(day.date) ?? { date: day.date, weekday: day.weekday, items: [] };
      current.items.push(...day.items.map((item) => addCorpus(item, corpus)));
      byDate.set(day.date, current);
    }
  }
  return Array.from(byDate.values()).sort((left, right) => left.date.localeCompare(right.date));
}

function addNumberMaps(target: Record<string, number>, source: Record<string, number>): void {
  for (const [key, value] of Object.entries(source)) target[key] = (target[key] || 0) + value;
}

export async function federatedAgenda(options: FederatedCommandOptions): Promise<Record<string, unknown>> {
  const { corpora, issues, payloads } = await collectFederatedPayloads(
    options.mounts,
    (corpus) => runCorpusJSON<AgendaPayload>("agenda", corpus.root, options.forwardedArgs),
  );
  const first = payloads[0]?.payload;
  const workload = payloads.some(({ payload }) => payload.workload)
    ? { totalMinutes: 0, byDate: {} as Record<string, number>, byGroup: {} as Record<string, number>, byTag: {} as Record<string, number> }
    : undefined;
  if (workload) {
    for (const { payload } of payloads) {
      if (!payload.workload) continue;
      workload.totalMinutes += payload.workload.totalMinutes;
      addNumberMaps(workload.byDate, payload.workload.byDate);
      addNumberMaps(workload.byGroup, payload.workload.byGroup);
      addNumberMaps(workload.byTag, payload.workload.byTag);
    }
  }
  return {
    $schema: "org2:workspace-agenda:v1",
    range: first?.range ?? { start: "", end: "", days: 0 },
    overdue: mergeAgendaDays(payloads.map(({ corpus, payload }) => ({ corpus, days: payload.overdue }))),
    days: mergeAgendaDays(payloads.map(({ corpus, payload }) => ({ corpus, days: payload.days }))),
    corpora,
    issues,
    skippedFiles: payloads.reduce((sum, { payload }) => sum + (payload.skippedFiles || 0), 0),
    ...(workload ? { workload } : {}),
  };
}

/** Takes each corpus's best result in turn, attaching its corpus identity. */
export function interleaveFederatedResults(
  perCorpus: Array<{ corpus: WorkspaceCorpusRef; results: Array<Record<string, unknown>> }>,
  limit: number,
): Array<Record<string, unknown>> {
  const qualifiedResults = perCorpus.map(({ corpus, results }) => results.map((item) => addCorpus(item, corpus)));
  const results: Array<Record<string, unknown>> = [];
  for (let index = 0; results.length < limit; index += 1) {
    let added = false;
    for (const corpusResults of qualifiedResults) {
      const item = corpusResults[index];
      if (!item) continue;
      results.push(item);
      added = true;
      if (results.length >= limit) break;
    }
    if (!added) break;
  }
  return results;
}

export async function federatedSearch(query: string, options: FederatedCommandOptions): Promise<Record<string, unknown>> {
  const { corpora, issues, payloads } = await collectFederatedPayloads(
    options.mounts,
    (corpus) => runCorpusJSON<SearchPayload>("search", corpus.root, [query, ...options.forwardedArgs]),
  );
  const first = payloads[0]?.payload;
  const results = interleaveFederatedResults(
    payloads.map(({ corpus, payload }) => ({ corpus, results: payload.results })),
    options.limit ?? 50,
  );
  return {
    $schema: "org2:workspace-search:v1",
    query,
    mode: first?.mode ?? "line",
    sort: first?.sort ?? "scan",
    corpora,
    issues,
    results,
  };
}
