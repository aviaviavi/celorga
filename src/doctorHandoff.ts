import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { auditAgenticWorkspace, type AgenticDoctorReport } from "./agenticWorkspaceDoctor.js";
import { findAgentPlaybook, renderAgentPlaybookPrompt } from "./agentPlaybooks.js";
import { brandEnv } from "./brandNames.js";
import { loadAgentProfileSnapshot } from "./coordination.js";
import { corpusIdentityStatus } from "./corpusIdentity.js";
import { guardedWriteFile } from "./guardedFile.js";

export const CELORGA_MACHINE_EVIDENCE_SCHEMA = "celorga:doctor-machine-evidence:v1" as const;
export const CELORGA_DOCTOR_HANDOFF_SCHEMA = "celorga:doctor-handoff:v1" as const;

/** Bounds keep the packet small enough to pass as one prompt argument. */
export const MACHINE_EVIDENCE_LIMITS = {
  findings: 20,
  messageCharacters: 300,
  incidents: 5,
  crashReports: 5,
  incidentScanEntries: 2000,
} as const;

export const HANDOFF_RUNTIMES = ["codex", "claude", "opencode", "pi", "openclaw"] as const;
export type HandoffRuntime = typeof HANDOFF_RUNTIMES[number];

interface RuntimeSpec {
  name: string;
  executableName: string;
  /** Environment variable the app already honors for this runtime. */
  executableEnv: string;
  /** Whether the CLI can start an interactive session directly. */
  launchSupported: boolean;
  permissionPosture: string;
}

const RUNTIME_SPECS: Record<HandoffRuntime, RuntimeSpec> = {
  codex: { name: "Codex", executableName: "codex", executableEnv: "ORG2_CODEX_EXECUTABLE", launchSupported: true,
    permissionPosture: "read-only sandbox (--sandbox read-only)" },
  claude: { name: "Claude Code", executableName: "claude", executableEnv: "ORG2_CLAUDE_EXECUTABLE", launchSupported: true,
    permissionPosture: "plan permission mode (no edits without approval)" },
  opencode: { name: "OpenCode", executableName: "opencode", executableEnv: "ORG2_OPENCODE_EXECUTABLE", launchSupported: true,
    permissionPosture: "edit, bash, and external-directory permissions set to ask" },
  pi: { name: "Pi", executableName: "pi", executableEnv: "ORG2_PI_EXECUTABLE", launchSupported: true,
    permissionPosture: "read-only tool allowlist (read,grep,find,ls)" },
  openclaw: { name: "OpenClaw", executableName: "openclaw", executableEnv: "ORG2_OPENCLAW_EXECUTABLE", launchSupported: false,
    permissionPosture: "prepare-only: deliver the packet to the selected OpenClaw agent" },
};

export interface MachineEvidence {
  $schema: typeof CELORGA_MACHINE_EVIDENCE_SCHEMA;
  collectedAt: string;
  readOnly: true;
  host: { hostname: string; platform: string; release: string; arch: string };
  cli: { version: string; node: string };
  corpus: { valid: boolean; id?: string; kind?: string; issues: string[] };
  workspace: {
    ok: boolean | null;
    error?: string;
    summary?: AgenticDoctorReport["summary"];
    findings: Array<{ rule: string; severity: string; message: string; file?: string; line?: number; runId?: string }>;
    truncatedFindings: number;
  };
  app: { bundles: Array<{ name: string; location: "system" | "user" }>; running: boolean | null };
  runtimes: Array<{ id: HandoffRuntime; name: string; found: boolean; source?: "env" | "path" }>;
  diagnostics: { recentIncidents: string[]; crashReports: Array<{ name: string; modifiedAt: string }> };
}

function truncate(value: string, limit: number): string {
  return value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
}

function packageVersion(): string {
  try {
    const file = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "package.json");
    return String(JSON.parse(fs.readFileSync(file, "utf8")).version || "unknown");
  } catch {
    return "unknown";
  }
}

function isExecutable(file: string): boolean {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

export function resolveRuntimeExecutable(
  runtime: HandoffRuntime,
  env: NodeJS.ProcessEnv = process.env,
): { path: string; source: "env" | "path" } | null {
  const spec = RUNTIME_SPECS[runtime];
  const configured = brandEnv(spec.executableEnv, env);
  if (configured) return isExecutable(configured) ? { path: configured, source: "env" } : null;
  const directories = [
    ...(env.PATH || "").split(path.delimiter),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    path.join(os.homedir(), ".local/bin"),
  ].filter(Boolean);
  for (const directory of directories) {
    const candidate = path.join(directory, spec.executableName);
    if (isExecutable(candidate)) return { path: candidate, source: "path" };
  }
  return null;
}

const APP_BUNDLE_NAMES = ["Celorga.app", "OpenOrg.app", "Celorga Preview.app", "OpenOrg Preview.app"];
const CRASH_REPORT_PATTERN = /(celorga|openorg|org2workspace)/i;

function appBundles(): MachineEvidence["app"]["bundles"] {
  const result: MachineEvidence["app"]["bundles"] = [];
  for (const [location, directory] of [["system", "/Applications"], ["user", path.join(os.homedir(), "Applications")]] as const) {
    for (const name of APP_BUNDLE_NAMES) {
      if (fs.existsSync(path.join(directory, name))) result.push({ name, location });
    }
  }
  return result;
}

function appRunning(): boolean | null {
  if (process.platform !== "darwin") return null;
  const result = spawnSync("/usr/bin/pgrep", ["-x", "Org2Workspace"], { encoding: "utf8", timeout: 2000 });
  if (result.error || result.status === null) return null;
  return result.status === 0;
}

function recentIncidents(root: string): string[] {
  const base = path.join(root, "raw", "diagnostics");
  const found: string[] = [];
  let scanned = 0;
  const walk = (dir: string, depth: number): void => {
    if (depth > 6 || scanned > MACHINE_EVIDENCE_LIMITS.incidentScanEntries) return;
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      scanned += 1;
      const absolute = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(absolute, depth + 1);
      else if (entry.name === "incident.json") found.push(path.relative(root, path.dirname(absolute)));
    }
  };
  walk(base, 0);
  // Incident directories are date-partitioned and timestamp-prefixed, so a
  // lexical sort is chronological.
  return found.sort().slice(-MACHINE_EVIDENCE_LIMITS.incidents).reverse();
}

function crashReports(): MachineEvidence["diagnostics"]["crashReports"] {
  if (process.platform !== "darwin") return [];
  const directory = path.join(os.homedir(), "Library", "Logs", "DiagnosticReports");
  let names: string[];
  try { names = fs.readdirSync(directory).filter((name) => CRASH_REPORT_PATTERN.test(name)); } catch { return []; }
  return names
    .map((name) => {
      try { return { name, modifiedAt: fs.statSync(path.join(directory, name)).mtime.toISOString() }; } catch { return null; }
    })
    .filter((value): value is { name: string; modifiedAt: string } => value !== null)
    .sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt))
    .slice(0, MACHINE_EVIDENCE_LIMITS.crashReports);
}

/**
 * Gather bounded, read-only evidence about this machine and corpus. Never
 * includes environment values, note contents, or absolute paths outside the
 * corpus; app and crash-report entries are names only.
 */
export function collectMachineEvidence(corpusRoot: string, env: NodeJS.ProcessEnv = process.env): MachineEvidence {
  const root = path.resolve(corpusRoot);
  const identity = corpusIdentityStatus(root);
  let workspace: MachineEvidence["workspace"];
  try {
    const report = auditAgenticWorkspace(root);
    const ordered = [...report.findings].sort((left, right) => {
      const rank = { error: 0, warning: 1, info: 2 } as const;
      return rank[left.severity] - rank[right.severity];
    });
    workspace = {
      ok: report.ok,
      summary: report.summary,
      findings: ordered.slice(0, MACHINE_EVIDENCE_LIMITS.findings).map((item) => ({
        rule: item.rule,
        severity: item.severity,
        message: truncate(item.message, MACHINE_EVIDENCE_LIMITS.messageCharacters),
        ...(item.file ? { file: path.isAbsolute(item.file) ? path.relative(root, item.file) : item.file } : {}),
        ...(item.line ? { line: item.line } : {}),
        ...(item.runId ? { runId: item.runId } : {}),
      })),
      truncatedFindings: Math.max(0, ordered.length - MACHINE_EVIDENCE_LIMITS.findings),
    };
  } catch (error) {
    // The handoff matters most when the workspace audit itself breaks.
    workspace = {
      ok: null,
      error: truncate(error instanceof Error ? error.message : String(error), MACHINE_EVIDENCE_LIMITS.messageCharacters),
      findings: [],
      truncatedFindings: 0,
    };
  }
  return {
    $schema: CELORGA_MACHINE_EVIDENCE_SCHEMA,
    collectedAt: new Date().toISOString(),
    readOnly: true,
    host: { hostname: os.hostname(), platform: process.platform, release: os.release(), arch: process.arch },
    cli: { version: packageVersion(), node: process.version },
    corpus: {
      valid: identity.valid,
      ...(identity.identity ? { id: identity.identity.id, kind: identity.identity.kind } : {}),
      issues: identity.issues.map((issue) => `${issue.path}: ${issue.message}`),
    },
    workspace,
    app: { bundles: appBundles(), running: appRunning() },
    runtimes: HANDOFF_RUNTIMES.map((id) => {
      const resolved = resolveRuntimeExecutable(id, env);
      return { id, name: RUNTIME_SPECS[id].name, found: resolved !== null, ...(resolved ? { source: resolved.source } : {}) };
    }),
    diagnostics: { recentIncidents: recentIncidents(root), crashReports: crashReports() },
  };
}

export function renderMachineEvidence(evidence: MachineEvidence): string {
  const lines = [
    `Host: ${evidence.host.hostname} (${evidence.host.platform} ${evidence.host.release}, ${evidence.host.arch})`,
    `CLI: celorga ${evidence.cli.version} on Node ${evidence.cli.node}`,
    `Corpus: ${evidence.corpus.valid ? `valid (${evidence.corpus.id}, ${evidence.corpus.kind})` : `invalid: ${evidence.corpus.issues.join("; ")}`}`,
    evidence.workspace.ok === null
      ? `Workspace audit failed: ${evidence.workspace.error}`
      : `Workspace audit: ${evidence.workspace.ok ? "ok" : "contradictions found"} (${evidence.workspace.summary?.errorCount ?? 0} errors, ${evidence.workspace.summary?.warningCount ?? 0} warnings)`,
    `App bundles: ${evidence.app.bundles.map((bundle) => `${bundle.name} [${bundle.location}]`).join(", ") || "none found"}; running: ${evidence.app.running === null ? "unknown" : evidence.app.running ? "yes" : "no"}`,
    `Runtimes: ${evidence.runtimes.map((runtime) => `${runtime.id}=${runtime.found ? "found" : "missing"}`).join(", ")}`,
    `Recent incidents: ${evidence.diagnostics.recentIncidents.join(", ") || "none"}`,
    `Crash reports: ${evidence.diagnostics.crashReports.map((report) => report.name).join(", ") || "none"}`,
  ];
  return lines.join("\n");
}

export interface DoctorHandoff {
  $schema: typeof CELORGA_DOCTOR_HANDOFF_SCHEMA;
  createdAt: string;
  playbook: { id: string; version: number; title: string };
  runtime: { id: HandoffRuntime; name: string; found: boolean; launchSupported: boolean; permissionPosture: string };
  agentRef?: string;
  /** Always false: a handoff is one foreground launch, never a scheduled job. */
  recurring: false;
  evidence: MachineEvidence;
  prompt: string;
  launch: {
    /** argv[0] is the runtime executable name; the resolved path stays local. */
    argv: string[];
    cwd: string;
    env: Record<string, string>;
  } | null;
  unavailableReason?: string;
  handoffFile?: string;
}

const OPENCODE_ASK_CONFIGURATION = JSON.stringify({
  $schema: "https://opencode.ai/config.json",
  permission: { edit: "ask", bash: "ask", external_directory: "ask" },
});

function launchArguments(runtime: HandoffRuntime, root: string, prompt: string): { args: string[]; env: Record<string, string> } | null {
  switch (runtime) {
    case "codex": return { args: ["--sandbox", "read-only", "--cd", root, prompt], env: {} };
    case "claude": return { args: ["--permission-mode", "plan", "--add-dir", root, prompt], env: {} };
    case "opencode": return { args: [root, "--prompt", prompt], env: { OPENCODE_CONFIG_CONTENT: OPENCODE_ASK_CONFIGURATION } };
    case "pi": return { args: ["--tools", "read,grep,find,ls", prompt], env: {} };
    case "openclaw": return null;
  }
}

export function parseHandoffRuntime(raw: string): HandoffRuntime {
  const value = raw.trim().toLowerCase();
  if (!(HANDOFF_RUNTIMES as readonly string[]).includes(value)) {
    throw new Error(`--handoff must be one of: ${HANDOFF_RUNTIMES.join(", ")}`);
  }
  return value as HandoffRuntime;
}

/** Use an agent profile's default runtime when no runtime is named. */
export function runtimeForAgentProfile(corpusRoot: string, agentRef: string): HandoffRuntime {
  const profile = loadAgentProfileSnapshot(corpusRoot, agentRef).value;
  if (!profile.defaultRuntime) throw new Error(`agent profile ${agentRef} has no default runtime; pass --handoff RUNTIME`);
  return parseHandoffRuntime(profile.defaultRuntime);
}

export function buildDoctorHandoff(options: {
  corpusRoot: string;
  runtime: HandoffRuntime;
  agentRef?: string;
  playbookId?: string;
  env?: NodeJS.ProcessEnv;
  now?: Date;
}): DoctorHandoff {
  const root = path.resolve(options.corpusRoot);
  const env = options.env ?? process.env;
  const playbook = findAgentPlaybook(options.playbookId ?? "troubleshoot");
  if (!playbook) throw new Error(`unknown playbook: ${options.playbookId}`);
  const evidence = collectMachineEvidence(root, env);
  const spec = RUNTIME_SPECS[options.runtime];
  const executable = resolveRuntimeExecutable(options.runtime, env);
  const prompt = [
    "Celorga troubleshooting handoff.",
    `Corpus root: ${root}`,
    options.agentRef ? `Selected agent profile: ${options.agentRef}` : undefined,
    "The person asked for help diagnosing Celorga. The Celorga app may not be open; use the celorga CLI.",
    "",
    renderAgentPlaybookPrompt(playbook),
    "",
    "Evidence (celorga:doctor-machine-evidence:v1):",
    JSON.stringify(evidence, null, 2),
  ].filter((line) => line !== undefined).join("\n");
  const launch = spec.launchSupported ? launchArguments(options.runtime, root, prompt) : null;
  let unavailableReason: string | undefined;
  if (!spec.launchSupported) unavailableReason = `${spec.name} has no supported interactive CLI launch; deliver the prompt to the selected agent instead.`;
  else if (!executable) unavailableReason = `${spec.executableName} was not found on PATH or in ${spec.executableEnv}.`;
  return {
    $schema: CELORGA_DOCTOR_HANDOFF_SCHEMA,
    createdAt: (options.now ?? new Date()).toISOString(),
    playbook: { id: playbook.id, version: playbook.version, title: playbook.title },
    runtime: { id: options.runtime, name: spec.name, found: executable !== null, launchSupported: spec.launchSupported, permissionPosture: spec.permissionPosture },
    ...(options.agentRef ? { agentRef: options.agentRef } : {}),
    recurring: false,
    evidence,
    prompt,
    launch: launch ? { argv: [spec.executableName, ...launch.args], cwd: root, env: launch.env } : null,
    ...(unavailableReason ? { unavailableReason } : {}),
  };
}

/** Corpus-relative review-zone path for a written handoff packet. */
export function doctorHandoffPath(handoff: DoctorHandoff): string {
  const stamp = handoff.createdAt.replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  return path.join("views", "diagnostics", "handoffs", `${stamp}-${handoff.runtime.id}.json`);
}

/**
 * Write the packet into the review zone. JSON keeps it out of Org projections.
 * The stored copy is corpus-relative: the absolute corpus root is replaced by
 * "." so a synced packet carries no machine-local path. The returned handoff
 * keeps absolute paths for an immediate local launch.
 */
export function writeDoctorHandoff(corpusRoot: string, handoff: DoctorHandoff): DoctorHandoff {
  const root = path.resolve(corpusRoot);
  const relative = doctorHandoffPath(handoff);
  const absolute = path.join(root, relative);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  const written = { ...handoff, handoffFile: relative };
  const escapedRoot = JSON.stringify(root).slice(1, -1);
  const portable = JSON.stringify(written, null, 2).split(escapedRoot).join(".");
  guardedWriteFile(absolute, `${portable}\n`, { expectedRevision: null });
  return written;
}

/**
 * Start the selected runtime once, in the foreground, attached to this
 * terminal. Returns the child's exit status. Never detaches or schedules.
 */
export function launchDoctorHandoff(handoff: DoctorHandoff, env: NodeJS.ProcessEnv = process.env): number {
  if (!handoff.launch) throw new Error(handoff.unavailableReason ?? "this runtime cannot be launched from the CLI");
  const executable = resolveRuntimeExecutable(handoff.runtime.id, env);
  if (!executable) throw new Error(handoff.unavailableReason ?? `${handoff.runtime.name} executable not found`);
  const result = spawnSync(executable.path, handoff.launch.argv.slice(1), {
    cwd: handoff.launch.cwd,
    env: { ...env, ...handoff.launch.env },
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

export function renderDoctorHandoff(handoff: DoctorHandoff, mode: { applied: boolean; launching: boolean }): string {
  const lines = [
    `Troubleshooting handoff: ${handoff.playbook.title} -> ${handoff.runtime.name}${handoff.agentRef ? ` (${handoff.agentRef})` : ""}`,
    `Permission posture: ${handoff.runtime.permissionPosture}`,
    "",
    renderMachineEvidence(handoff.evidence),
    "",
  ];
  if (handoff.handoffFile) lines.push(`Packet written: ${handoff.handoffFile}`);
  else if (!mode.applied) lines.push(`Preview only. Pass --apply to write the packet to ${doctorHandoffPath(handoff)}.`);
  if (handoff.unavailableReason) lines.push(`Launch unavailable: ${handoff.unavailableReason}`);
  else if (!mode.launching) lines.push(`Pass --launch to start ${handoff.runtime.name} once in this terminal, or run: ${handoff.launch!.argv[0]} … (see --json for full argv).`);
  lines.push("No recurring job is created.");
  return lines.join("\n");
}
