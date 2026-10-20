/**
 * Product agent playbooks.
 *
 * A playbook is a repository-owned product asset that tells a user-selected
 * agent how to run a *variable* investigation on top of *dependable* Celorga
 * operations. The deterministic part (evidence gathering, run state,
 * approvals, review queues) stays in typed Celorga commands; the playbook only
 * describes the judgment the agent supplies and the boundaries it must keep.
 *
 * Playbooks are not runtime skills and are not tied to any single agent
 * runtime. A handoff packet carries the playbook prompt plus bounded evidence
 * to whichever supported runtime the user selected.
 */

export const CELORGA_AGENT_PLAYBOOK_SCHEMA = "celorga:agent-playbook:v1" as const;

export type AgentPlaybookStatus = "available" | "extension-point";

export interface AgentPlaybook {
  $schema: typeof CELORGA_AGENT_PLAYBOOK_SCHEMA;
  id: string;
  version: number;
  title: string;
  status: AgentPlaybookStatus;
  /** One-line purpose shown in capability listings. */
  summary: string;
  /** The deterministic Celorga commands the playbook composes. */
  operations: string[];
  /** Boundaries the agent must keep regardless of runtime. */
  boundaries: string[];
  /** Ordered investigation steps. Empty for extension points. */
  steps: string[];
  /** How the playbook is entered. Extension points name their intended entry. */
  entry: string;
}

const SHARED_BOUNDARIES = [
  "Treat ordinary .org files as canonical; never hand-edit machine-state blocks under the corpus state directory.",
  "Start read-only. Ask the person before any mutation, and use preview-first Celorga commands with --apply only after approval.",
  "Do not restart services, replace the installed app, delete files, or create recurring automations or scheduled jobs.",
  "Never print, store, or request secret values. Report missing credentials as a named binding, not a value.",
  "Cite evidence by command, corpus-relative path, and line where available.",
];

export const AGENT_PLAYBOOKS: readonly AgentPlaybook[] = [
  {
    $schema: CELORGA_AGENT_PLAYBOOK_SCHEMA,
    id: "troubleshoot",
    version: 1,
    title: "Troubleshoot this Celorga installation",
    status: "available",
    summary: "Diagnose why Celorga misbehaves or will not open, starting from doctor evidence, without the GUI.",
    entry: "celorga doctor --handoff RUNTIME [--apply] [--launch]",
    operations: [
      "celorga doctor --dir CORPUS --json",
      "celorga doctor --machine --dir CORPUS --json",
      "celorga --version",
      "celorga corpus validate --dir CORPUS",
      "celorga lint --dir CORPUS --recursive --format json",
      "celorga review list --dir CORPUS --json",
      "celorga run show RUN_ID --with-revision --json",
    ],
    boundaries: SHARED_BOUNDARIES,
    steps: [
      "Read the evidence packet below. It is bounded and may be stale; re-run the cited commands before relying on a finding.",
      "Classify the symptom: app will not launch, app hangs or is slow, corpus or run state is inconsistent, an agent runtime is unavailable, or a source/integration is failing.",
      "For launch failures, inspect the listed crash-report names and recent raw/diagnostics incidents, then confirm the CLI works independently of the app.",
      "For workspace contradictions, follow each doctor finding's suggestion and identify the canonical lifecycle command that would settle it; preview it rather than applying it.",
      "Propose the smallest fix with the exact command or edit, its risk, and how to verify it. Wait for the person's approval before any write.",
      "Summarize what you verified, what remains uncertain, and any issue worth reporting at https://github.com/aviaviavi/celorga/issues (sanitized, without private corpus content).",
    ],
  },
  {
    $schema: CELORGA_AGENT_PLAYBOOK_SCHEMA,
    id: "onboarding",
    version: 0,
    title: "Onboard a new corpus or machine",
    status: "extension-point",
    summary: "Walk a person through corpus identity, runtime selection, sources, and first workflows.",
    entry: "Planned: celorga corpus init/validate followed by a handoff with this playbook.",
    operations: [
      "celorga corpus show|validate|init --dir CORPUS",
      "celorga agent capabilities",
      "celorga agent-profile list|resolve --dir CORPUS --json",
      "celorga source list|doctor --dir CORPUS --json",
      "celorga doctor --machine --dir CORPUS --json",
    ],
    boundaries: SHARED_BOUNDARIES,
    steps: [],
  },
  {
    $schema: CELORGA_AGENT_PLAYBOOK_SCHEMA,
    id: "stalled-work-review",
    version: 0,
    title: "Review stalled delegated work",
    status: "extension-point",
    summary: "Find runs, approvals, and TODOs that stopped moving and propose a next action for each.",
    entry: "Planned: a handoff whose evidence is celorga review list plus doctor run findings.",
    operations: [
      "celorga review list --dir CORPUS --json",
      "celorga approvals --dir CORPUS --json",
      "celorga run list --dir CORPUS --json",
      "celorga doctor --dir CORPUS --json",
      "celorga run block|resume|cancel ID (preview, then apply after approval)",
    ],
    boundaries: SHARED_BOUNDARIES,
    steps: [],
  },
  {
    $schema: CELORGA_AGENT_PLAYBOOK_SCHEMA,
    id: "release-preparation",
    version: 0,
    title: "Prepare a release",
    status: "extension-point",
    summary: "Assemble release readiness evidence and a reviewable plan without publishing.",
    entry: "Planned: a handoff from the repository's preview-first release command plan.",
    operations: [
      "npm run release:openorg -- (preview only)",
      "npm test",
      "npm run docs:check",
      "npm run check:generated",
    ],
    boundaries: [
      ...SHARED_BOUNDARIES,
      "Never run the release with --execute; publishing is a separate approved action.",
    ],
    steps: [],
  },
];

export function findAgentPlaybook(id: string): AgentPlaybook | undefined {
  return AGENT_PLAYBOOKS.find((playbook) => playbook.id === id);
}

/** Render the instruction text an agent receives for one playbook. */
export function renderAgentPlaybookPrompt(playbook: AgentPlaybook): string {
  if (playbook.status !== "available") {
    throw new Error(`playbook ${playbook.id} is an extension point and cannot be handed off yet`);
  }
  return [
    `Playbook: ${playbook.title} (${playbook.id} v${playbook.version})`,
    "",
    "Dependable operations you may use:",
    ...playbook.operations.map((operation) => `- ${operation}`),
    "",
    "Boundaries:",
    ...playbook.boundaries.map((boundary) => `- ${boundary}`),
    "",
    "Steps:",
    ...playbook.steps.map((step, index) => `${index + 1}. ${step}`),
  ].join("\n");
}
