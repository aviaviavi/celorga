import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { AgentWorkflowTemplate } from "./agentWorkflow.js";
import { stateDir } from "./brandNames.js";

export const ORG2_ARTIFACT_GRAPH_SCHEMA = "org2:artifact-graph:v1" as const;

export interface ArtifactNode {
  id: string;
  path: string;
  sources: string[];
  command?: string;
  generatedAt?: string;
  sourceHashes: Record<string, string>;
  status: "fresh" | "stale" | "missing" | "conflicted" | "review-required";
  reason?: string;
}

export interface ArtifactGraph {
  schema: typeof ORG2_ARTIFACT_GRAPH_SCHEMA;
  root: string;
  generatedAt: string;
  artifacts: ArtifactNode[];
}

function sha256File(file: string): string {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function resolve(root: string, file: string): string {
  return path.isAbsolute(file) ? file : path.resolve(root, file);
}

export function inspectArtifact(root: string, input: Omit<ArtifactNode, "status" | "sourceHashes"> & { sourceHashes?: Record<string, string> }): ArtifactNode {
  const output = resolve(root, input.path);
  const hashes: Record<string, string> = {};
  let status: ArtifactNode["status"] = fs.existsSync(output) ? "fresh" : "missing";
  let reason = status === "missing" ? "output does not exist" : undefined;
  for (const source of input.sources) {
    const sourcePath = resolve(root, source);
    if (!fs.existsSync(sourcePath)) {
      status = "conflicted";
      reason = `source does not exist: ${source}`;
      continue;
    }
    hashes[source] = sha256File(sourcePath);
    if (input.sourceHashes?.[source] && input.sourceHashes[source] !== hashes[source]) {
      status = "stale";
      reason = `source changed: ${source}`;
    }
    if (status === "fresh" && fs.existsSync(output) && fs.statSync(sourcePath).mtimeMs > fs.statSync(output).mtimeMs) {
      status = "stale";
      reason = `source is newer: ${source}`;
    }
  }
  return { ...input, sourceHashes: hashes, status, ...(reason ? { reason } : {}) };
}

export function buildArtifactGraph(root: string, declarations: Array<Omit<ArtifactNode, "status" | "sourceHashes"> & { sourceHashes?: Record<string, string> }>, now?: string): ArtifactGraph {
  return {
    schema: ORG2_ARTIFACT_GRAPH_SCHEMA,
    root: path.resolve(root),
    generatedAt: new Date(now || Date.now()).toISOString(),
    artifacts: declarations.map((item) => inspectArtifact(root, item)),
  };
}

export function artifactRebuildPlan(graph: ArtifactGraph): Array<{ id: string; path: string; command?: string; reason: string }> {
  const pending = new Set(graph.artifacts.filter((artifact) => artifact.status !== "fresh").map((artifact) => artifact.path));
  let changed = true;
  while (changed) {
    changed = false;
    for (const artifact of graph.artifacts) {
      if (!pending.has(artifact.path) && artifact.sources.some((source) => pending.has(source))) {
        pending.add(artifact.path);
        changed = true;
      }
    }
  }
  const byPath = new Map(graph.artifacts.map((artifact) => [artifact.path, artifact]));
  const ordered: ArtifactNode[] = [];
  const visited = new Set<string>();
  const visiting = new Set<string>();
  const visit = (artifact: ArtifactNode) => {
    if (visited.has(artifact.path)) return;
    if (visiting.has(artifact.path)) return;
    visiting.add(artifact.path);
    for (const source of artifact.sources) {
      const upstream = byPath.get(source);
      if (upstream && pending.has(upstream.path)) visit(upstream);
    }
    visiting.delete(artifact.path);
    visited.add(artifact.path);
    ordered.push(artifact);
  };
  for (const artifact of graph.artifacts) if (pending.has(artifact.path)) visit(artifact);
  return ordered.map((artifact) => ({
    id: artifact.id,
    path: artifact.path,
    ...(artifact.command ? { command: artifact.command } : {}),
    reason: artifact.reason || "depends on a stale upstream artifact",
  }));
}

export function loadArtifactDeclarations(file: string): Array<Omit<ArtifactNode, "status">> {
  const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as { artifacts?: Array<Omit<ArtifactNode, "status">> } | Array<Omit<ArtifactNode, "status">>;
  return Array.isArray(parsed) ? parsed : parsed.artifacts || [];
}

export function saveArtifactGraph(root: string, graph: ArtifactGraph): string {
  const target = stateDir(path.resolve(root), "artifact-graph.json");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(graph, null, 2)}\n`, "utf8");
  return target;
}

export const MEETING_TO_CONTROLLED_EXECUTION_WORKFLOW = {
  schema: "org2:workflow-template:v1",
  id: "meeting-to-controlled-execution",
  version: "1.0.0",
  title: "Meeting to controlled execution",
  description: "Turn a provenance-preserving meeting capture into cited decisions, reviewable tasks, refreshed data, finished artifacts, and approval-gated publication.",
  instructions: "Process {{meeting}} into a cited meeting brief with decisions, reviewable tasks, and portable outputs under {{output}}.",
  riskClass: "external-action",
  capabilities: ["agent-context", "meeting-ingest", "data-query", "chart-render", "publish", "approval"],
  inputs: [
    { id: "meeting", description: "Meeting transcript or capture reference", required: true },
    { id: "output", description: "Reviewable output directory", required: false, default: "views/meeting-execution" },
  ],
  contextRules: ["{{meeting}}"],
  steps: [
    { id: "preserve", kind: "compiler", title: "Preserve transcript provenance" },
    { id: "extract", kind: "agent", title: "Extract cited summary, decisions, questions, and proposed tasks" },
    { id: "delegate", kind: "agent", title: "Delegate bounded research and drafting" },
    { id: "refresh", kind: "compiler", title: "Refresh configured datasets and charts" },
    { id: "compile", kind: "artifact", title: "Compile the finished briefing and portable outputs" },
    { id: "review", kind: "approval", title: "Review ambiguous claims and consequential actions" },
    { id: "release", kind: "tool", title: "Publish or send the approved result" },
  ],
  outputs: [
    { id: "briefing", path: "{{output}}/briefing.org", role: "view" },
    { id: "publication", path: "{{output}}/publication.pdf", role: "export", mediaType: "application/pdf" },
  ],
  validations: ["citations", "artifact-freshness", "protected-zones", "export"],
  approvals: [{ title: "Release finished meeting artifacts", action: "publish-or-send", riskClass: "external-action", requestedRole: "owner" }],
  triggers: [{ id: "meeting-import", type: "meeting-import", enabled: true }],
} satisfies AgentWorkflowTemplate;
