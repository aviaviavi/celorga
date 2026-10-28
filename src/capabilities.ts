export interface Org2CapabilityWorkflow {
  id: string;
  purpose: string;
  commands: string[];
  writes: "read-only" | "preview-by-default" | "mixed";
}

export interface Org2CapabilityManifest {
  $schema: "org2:capabilities:v1";
  product: string;
  summary: string;
  sourceOfTruth: string;
  discovery: string[];
  safety: string[];
  workflows: Org2CapabilityWorkflow[];
  clients: Array<{ id: string; role: string }>;
  docs: Array<{ id: string; url: string }>;
}

export function buildOrg2CapabilityManifest(): Org2CapabilityManifest {
  return {
    $schema: "org2:capabilities:v1",
    product: "Celorga",
    summary: "A local-first knowledge compiler and runtime for Org-shaped plain-text workspaces.",
    sourceOfTruth: "Ordinary .org files remain canonical; compiled indexes, views, reports, and app state are derived.",
    discovery: [
      "Run `celorga agent capabilities` for this machine-readable manifest.",
      "Use the Celorga CLI by default for Org operations; prefer exposed Celorga workspace/MCP tools where supported, and honor client-required effective-text reads and reviewed writes.",
      "Celorga is independent of Emacs. Do not assume Emacs is installed or invoke emacs, emacsclient, batch Emacs Lisp, or Org exporters as an implicit fallback. Use Emacs only for an explicitly requested Emacs-specific task.",
      "Before declaring a capability gap, check the installed version, capabilities, and command help. Distinguish missing executables, permissions, and unavailable tools from missing features. Use a supported reviewable alternative without bypassing access or review boundaries; never silently execute unsupported formulas or source blocks through GNU Org.",
      "For a confirmed gap, reproduce and fix it with a regression test when authorized to develop Celorga in its repository. Otherwise suggest https://github.com/aviaviavi/celorga/issues and prepare a sanitized version, command/tool, minimal input, expected/actual behavior, and workaround report. Do not publish issues or private corpus content without user authorization.",
      "The CLI is `celorga`. Corpus configuration lives in celorga.json.",
      "Run `celorga --help` for command families and `celorga COMMAND --help` for current flags.",
      "Run `celorga version` or `celorga --version` to inspect the installed package version.",
      "Prefer JSON output for integrations (`--format json` or `--json` where supported).",
      "Use `celorga agent context|search|fetch|bundle` for bounded, cited corpus retrieval.",
      "Use `celorga run --help` for durable delegated work, `celorga workflow` for reusable recipes, and `celorga mcp serve` for local MCP discovery. A headless Celorga server can expose the same retrieval tools through read-only Streamable HTTP MCP.",
      "Use `celorga workflow create` for a plain prompt automation with optional file-owned model and reasoning effort, `celorga workflow due` for destination-neutral schedule checks, and preview-first `celorga workflow delete` to remove a definition without erasing run history; the Celorga app can dispatch due attempts to any configured AI destination.",
      "Use `celorga goal` for durable outcomes and `celorga agent-profile` for portable named workers plus runtime bindings; resolve a runtime agent ID before creating delegated work.",
      "Use `celorga workflow trigger-set ID --trigger T --type todo-state|pull-request ...` for event-triggered automations: todo-state fires when a heading enters a TODO keyword (optional tag, path-glob, and property filters); pull-request fires on GitHub review, comment, commit, merged, closed, or opened activity through the user's existing `gh` login. Preview-first `celorga workflow observe` and `celorga workflow poll --source github` record deterministic signals with `--apply`, and `coalesce` combines nearby signals into one attempt listed by `celorga workflow due`.",
      "Use read-only `celorga doctor --dir CORPUS --json` to find contradictory run, approval, workflow-attempt, and projected headline state before an agent acts.",
      "When Celorga misbehaves or the app will not open, use `celorga doctor --machine --json` for bounded machine evidence and `celorga doctor --handoff codex|claude|opencode|pi|openclaw [--agent-ref ID] [--apply] [--launch]` to hand that evidence and the troubleshoot playbook to the selected agent. It previews by default, launches at most once in the foreground in the runtime's most restrictive interactive posture, and never schedules a job.",
      "Use `celorga run show ID --with-revision --json` when a client needs a revision token for a later guarded mutation.",
      "Celorga renders completed HTML source blocks as live previews in AI chat and the reader with expandable source: inline JavaScript runs and may load HTTPS libraries and data inside an opaque-origin sandbox that cannot reach the chat, corpus, local files, or app, and the frame sizes to its content unless `:height N` is given. Use one for interactive boards, simulations, calculators, or diagrams, and a `chart` source block (bar, line, histogram) after an Org table for native charts. Reviewed workspace edits accept .html, .htm, and .xhtml files for standalone interactive pages, retaining SHA-bound previews and stale-write protection.",
      "To hand work to another agent, message it directly instead of creating an automation, workflow, or scheduled job just to trigger a turn: preview-first `celorga thread send THREAD_ID --message TEXT --idempotency-key KEY --apply` (MCP `celorga_thread_send`) starts a single-agent chat's turn, and `celorga thread list --json` (MCP `celorga_thread_list`) finds thread IDs. Use `celorga thread post THREAD_ID ... --apply` or the MCP tool `celorga_thread_post` when an explicitly asynchronous worker must report into a named AI chat; a post is context only unless `--request-turn AGENT` (MCP `requestTurn`) asks shared-room agents to respond. Single-agent chats reject that flag; use preview-first `celorga thread send THREAD_ID --message TEXT --idempotency-key KEY --apply` to enqueue a user turn through the existing destination queue (a follow-up while busy). This requires a consumer supporting send-message:v1; older consumers retain the request as unsupported. Delivery status and turn status are separate: queuing or delivering a request does not confirm a started turn. Pass the target thread ID and a stable idempotency key into delegated work. In a shared room, an agent reply that @mentions another room agent starts that agent's turn; `celorga thread configure THREAD --agent-turn-limit N|default` caps back-to-back agent-requested turns (default 4, 0 turns hand-offs off) before a person must reply.",
      "Use `celorga activity explain --json` (optionally `--thread|--run|--workflow ID`) to learn why work is running or blocked before acting, `celorga activity trace --run ID --json` to explain why one run stopped (dispatch, executor, tools, result, and delivery evidence; verdict queued|running|waiting|failed|completed|completed-undelivered|canceled|unknown; whether a retry is safe) before retrying it, `celorga activity events --follow --json` for an NDJSON stream of run, approval, thread, workflow, and host transitions, and `celorga thread wait ID --until reply|needs-you|idle` or `celorga run wait ID --until approval|blocked|completed` for race-free coordination; waits check durable state first and exit 0 matched, 2 unreachable, 124 timed out.",
      "Use `celorga thread repair --dir CORPUS --json` on macOS to preview deterministic transcript reconciliation through the native OpenOrgServer worker; `--apply` commits a new repair head without changing original writer heads. `--watch --interval SECONDS --apply` runs without an LLM and skips unchanged chat storage. Build the worker with npm run build:server or supply --executable PATH. Desktop Settings and server chat-repair configure the background check interval; 0/off disables it.",
      "Never ask the user to paste credentials into chat. Use preview-first `celorga secret request NAME --reason TEXT --author NAME --apply` (MCP `celorga_secret_request`): the Celorga app asks in a secure sheet and stores the value GPG-encrypted in the corpus. Check `celorga secret status ID`, then run `celorga secret exec NAME [--env VAR] -- COMMAND`; no secret command prints a value.",
      "To find a file on this Mac outside the corpus (a downloaded PDF, a spreadsheet, a folder), use `celorga files search WORDS [--kind pdf|sheet|...] [--json]`. It searches names and folders under the machine-local indexed folders (home and cloud drives by default; `celorga files config` changes them), ranks recent documents first, and returns repeat downloads and copies as one result with `copies`. The index lives outside the corpus and never reads file contents.",
      "Use `celorga ledger` for stable per-account bookkeeping in recurring workflows; canonical accounts live under `notes/LEDGER/accounts/`.",
      "Use `celorga corpus show|validate|init` to inspect or establish portable corpus identity before team mounting.",
      "Use `celorga source list|doctor|status|bind|import|sync` to manage corpus-declared Slack and Notion crawler profiles and IMAP email profiles, add or update any profile type with `celorga source add PROFILE --source-json JSON` (or `celorga source add-email`), and stage review packets without storing credentials in the corpus; email sync is read-only and incremental.",
      "Use `celorga plugin actions --context note|heading|thread|run|approval` and `celorga plugin action run PLUGIN:ACTION` for context-aware plugin actions, and `celorga plugin hooks dispatch --apply` for lifecycle hooks (run.blocked, run.completed, approval.requested, thread.reply-received, ...). Both are sandboxed and only return proposals; review them with `celorga plugin proposals list|apply|dismiss` (preview by default, `--apply` to write).",
      "Use `celorga plugin list|doctor` to inspect corpus-declared extensions, `plugin sync` to reproduce the content-addressed lock, and `plugin update` to advance a Git ref deliberately.",
      "Use `celorga workspace agenda|search` only with explicitly granted `--mount` paths for read-only multi-corpus projections.",
      "Use `celorga publish document` to preview and publish a disclosure-safe document or subtree as a web bundle, Beamer PDF, Google Doc, Google Slides deck, Google Sheet, or Google Drive PDF.",
    ],
    safety: [
      "Treat corpus files as user-owned source code: make small, reviewable text changes.",
      "Mutating commands generally preview unless `--apply` is present; inspect previews before applying.",
      "Keep generated work in reviewable zones such as views/ or compiled/ before promotion into canonical notes/.",
      "Preserve file and line citations, IDs, provenance, source hashes, and review state when deriving artifacts.",
      "Never block a durable run without an actionable clarification; `celorga run block ID --reason TEXT` requires the specific question or next action. A run with a pending approval must stay waiting-approval unless an independent blocker is explicitly declared with `--separate-from-approval`; approval-shaped reasons are rejected even with that override.",
      "Never complete a durable run without a concise result for the reviewer; `celorga run complete ID --summary TEXT` requires a human-readable outcome and accepts repeatable highlights and next actions.",
      "A run with a pending approval cannot be completed normally; record the request, stop before the protected action, and resume only after the approval decision returns the run to running.",
      "Treat `celorga approvals` as the unified pending-decision queue: decide `kind=run` items by their exact runId/approvalId through `celorga run approval-decide`, and mutate `kind=headline` items only at their cited source heading. A headline carrying `ORG2_RUN_ID` that resolves to a canonical run approval is a derived projection and is not a second writable decision. Provider-backed items expose `decisionKeys`; preserve the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line so `approval-request` reuses the current durable decision and `approval-decide` closes older duplicate projections.",
      "Use `celorga run approval-resolve --decision-key KEY --json` when an execution guard needs the canonical pending or decided provider authority. Private adapter state is only a cache and must not override this CLI resolution.",
      "Snooze an approval instead of inventing a SNOOZED status: `celorga run approval-snooze RUN APPROVAL --until 2h|1d|1w|YYYY-MM-DD|ISO` (or `--wake`) for run approvals, or a future `SCHEDULED` date on a headline approval, as in Org. Snoozed approvals stay pending, are hidden from `celorga approvals` until the time passes, and are listed with `snoozedUntil` under `--include-snoozed`.",
      "Run approvals carry a SHA-256 fingerprint over immutable review material. Pass the queue item's fingerprint back to `run approval-decide --fingerprint` so stale or substituted actions fail closed across clients.",
      "A `run approval-decide --decision revised` request must include `--note \"Requested changes\"`; revision feedback is stored as the decision note and does not authorize the protected action.",
      "Approval decisions are item-scoped: rejecting or canceling one action leaves sibling approvals pending, and the run resumes only after the current boundary is fully decided, executing approved actions while excluding rejected or canceled ones. A client recording that one approval was completed elsewhere must cancel only that approval with an external receipt; it must not complete the containing run. Use `revised` with a concrete note when replacement material is required.",
      "Scheduled workflow runs use a stable logicalWorkId plus distinct numbered attempt records. A schedule with an event/fresh-path gate is skipped until `workflow signal` records matching work after the prior attempt.",
      "Event triggers are deterministic: Celorga records todo-state and pull-request signals from parsed headings and `gh` API results and never asks a model whether to start work. GitHub tokens stay in the user's `gh` configuration and are never copied into the corpus; a new or re-activated trigger's first detector pass is a baseline that fires nothing.",
      "Use `celorga server` for a standalone macOS relay, scheduler, and optional read-only Streamable HTTP MCP endpoint. Server configuration and MCP token hashes are machine-local; plaintext access tokens are shown once and must never enter the corpus. `server assign --host-ref HOST` writes only a symbolic automation owner to celorga.json. iOS selects one paired host at a time; independently synced corpus copies are not a distributed lock.",
      "The Celorga scheduler catches up only the latest missed occurrence and dispatches each occurrence once. By default it starts a new attempt even while earlier attempts are queued, running, approval-waiting, or blocked, so a hung attempt cannot stall the schedule; `workflow schedule --when-running wait` opts a schedule into single-instance execution, and `--when-blocked wait` makes it wait for blocked attempts. An unavailable explicit AI destination fails visibly; it must never silently reroute the prompt.",
      "Deleting a workflow is preview-first and removes only its canonical definition; preserve prior runs and never imply that deleting the definition cancels work already dispatched to a runtime.",
      "A run with a review-required artifact cannot be completed normally; after the human decision, use `celorga run artifact-review RUN_ID ARTIFACT_ID --status reviewed|rejected --actor NAME` to update both the durable run and linked Org artifact before completion.",
      "When a person confirms that an unfinished run's outcome was completed outside the workflow, `celorga run complete-external ID [--summary TEXT] --actor NAME` records that explicit resolution while preserving unresolved approvals and review metadata as history; agents must not infer this resolution on their own.",
      "Use `celorga run reopen-external ID --summary TEXT --actor NAME` only to repair a run mistakenly completed externally from `waiting-approval`; it restores the same run and retained approval identities to the pending queue.",
      "Record observable runtime metadata with `celorga run runtime ID` when provider, model, token usage, cost, or elapsed time is available; never put credentials in a run record.",
      "Treat OpenClaw, Codex, Claude Code, Pi, and OpenCode as runtimes, not agent identities. Store named workers under agent-profiles/, bind non-secret runtime agent IDs there, and preserve resolved agentRef/goalRef on runs, workflows, and delegated headings.",
      "Run targeted tests plus `celorga lint` around writes when practical; never put secrets in notes or generated artifacts.",
      "Never infer agent access from corpora remembered by a person's app; every federated CLI mount must be explicit.",
      "Single-document publishing strips private Org metadata and raw HTML before rendering every format. A static web bundle does not implement viewer authentication; its host must enforce any secret-link or per-person access policy, while Google Drive owns permissions for Docs, Slides, Sheets, and PDF files.",
      "Treat `celorga doctor` as a read-only consistency check. Review its evidence before repairing canonical state; the command never repairs files automatically. Only `doctor --handoff ... --apply` writes, and only a troubleshooting packet under views/diagnostics/handoffs/.",
      "Run and workflow mutations use atomic guarded writes. Pass `--if-revision sha256:...` when carrying run state across requests; a stale revision, concurrent writer, duplicate create, or out-of-band readable-state edit fails instead of silently overwriting newer source.",
      "Keep curated account identity, aliases, commercial context, and idempotent work history in a ledger account under notes/. Keep immutable imports and provider payloads under raw/, and link approvals to their canonical run instead of copying decision state.",
      "Resolve every available stable identity before creating recurring account work. Treat ambiguity or source drift as a blocker rather than guessing.",
      "Plugin Git sources are inert until their exact SHA-256 content hash is trusted on the current machine. Review a locked package before `celorga plugin trust --apply`; use `--revoke` to stop executing that hash.",
    ],
    workflows: [
      {
        id: "editable-property-views",
        purpose: "Draft portable saved table/card views in plain language, filter/sort/group shared note and heading properties without SQL, and preview revision-guarded local source property edits.",
        commands: ["celorga property-view list", "celorga property-view suggest", "celorga property-view query", "celorga property-view save", "celorga property-view edit"],
        writes: "preview-by-default",
      },
      {
        id: "interactive-workspace-views",
        purpose: "Save a refreshable daily-plan view with remembered choices and source-linked tasks; sandboxed controls request choice saves or previews, and the schedule action applies only with the preview fingerprint and source revision and can be undone while the source is unchanged.",
        commands: ["celorga view create", "celorga view refresh", "celorga view state", "celorga view action", "celorga view undo", "celorga view bridge"],
        writes: "preview-by-default",
      },
      {
        id: "live-embeds",
        purpose: "Resolve portable note and stable-ID heading embeds with source navigation, bounded live rendering, and reference-only exports.",
        commands: ["celorga embed resolve"],
        writes: "read-only",
      },
      {
        id: "cli-discovery",
        purpose: "Inspect the installed Celorga CLI version before relying on its command contract.",
        commands: ["celorga version", "celorga --version"],
        writes: "read-only",
      },
      {
        id: "corpus-identity-and-mounting",
        purpose: "Inspect, validate, or initialize portable personal, shared, and project corpus identities.",
        commands: ["celorga corpus"],
        writes: "preview-by-default",
      },
      {
        id: "federated-workspace-read",
        purpose: "Combine agenda or search output from explicitly named identified corpora while retaining corpus identity on every result.",
        commands: ["celorga workspace agenda", "celorga workspace search"],
        writes: "read-only",
      },
      {
        id: "workspace-agent-state",
        purpose: "Read projects, runs, workflows, goals, and agent profiles for one corpus in one process, with independent section errors and timings.",
        commands: ["celorga workspace agent-state"],
        writes: "read-only",
      },
      {
        id: "workspace-coordinator",
        purpose: "Review agent work across mounted corpora and every host publishing presence into them: what needs you, what is stuck, what is working, and what shipped, with run, task, artifact, and validation evidence. Offer continuation only when guards pass (open run, no pending approval, linked single-agent chat, no active turn or queued request, quiet period, live route to the last executor or a failover host); `workspace continue` re-derives the offer and delegates to an idempotent `thread send` or a revision-guarded `run retry`, preview-first, never claiming a turn started. MCP: `celorga_workspace_coordinate`, `celorga_workspace_continue`.",
        commands: ["celorga workspace coordinate", "celorga workspace continue"],
        writes: "preview-by-default",
      },
      {
        id: "attention-digest",
        purpose: "Deterministic digest of what needs the person now: pending approvals, blocked runs with a question, artifact reviews, chats awaiting a reply, failed runs, overdue deadlines, and today's deadlines and scheduled items, each with a stable fingerprint and file:line, run, or thread evidence. Filtered by the `attention` key in celorga.json (categories, tags, paths, quiet hours, morning brief, check interval). `interrupt` is true only for never-delivered fingerprints outside quiet hours; `--mark-delivered --apply` records delivery in the corpus state directory. No model calls or judgment.",
        commands: ["celorga workspace attention"],
        writes: "preview-by-default",
      },
      {
        id: "explainable-activity",
        purpose: "Explain why every chat thread, durable run, and workflow is working or needs attention (reporting host/runtime, last heartbeat or transition, live/cached/uncertain confidence, exact blocking approval or question), trace one run through dispatch, executor, tools, result, and delivery to distinguish a working executor from completed-but-undelivered work and unknown state, list multi-host presence with failover candidates, stream local activity events, and wait race-free on thread or run conditions.",
        commands: ["celorga activity explain", "celorga activity trace", "celorga activity hosts", "celorga activity events", "celorga thread wait", "celorga run wait"],
        writes: "read-only",
      },
      {
        id: "headless-server",
        purpose: "Host the Celorga chat relay, automation scheduler, and an optional bearer-authenticated read-only Streamable HTTP MCP endpoint without a desktop window on macOS.",
        commands: ["celorga server init", "celorga server start", "celorga server status", "celorga server pair", "celorga server permissions", "celorga server token", "celorga server mcp", "celorga server assign", "celorga server service", "celorga server stop", "celorga server drain", "celorga server resume", "celorga server restart", "celorga server revoke", "celorga server push-config"],
        writes: "mixed",
      },
      {
        id: "agentic-workspace",
        purpose: "Manage goals and portable agent identities, post idempotent background results into AI chat, settle chat history, create destination-neutral prompt automations, inspect durable run history, and package reusable workflows.",
        commands: ["celorga doctor", "celorga goal", "celorga agent-profile", "celorga thread", "celorga run", "celorga review", "celorga workflow", "celorga eval"],
        writes: "mixed",
      },
      {
        id: "project-notes",
        purpose: "Use one ordinary Org file as a project brief with actions, source links, color, and related chat IDs; adopt existing notes without moving their content.",
        commands: ["celorga project list", "celorga project show", "celorga project create", "celorga project adopt", "celorga project update"],
        writes: "preview-by-default",
      },
      {
        id: "work-ledger",
        purpose: "Maintain stable per-account identity and idempotent event history for high-volume recurring work without growing one monolithic agent note.",
        commands: ["celorga ledger list", "celorga ledger resolve", "celorga ledger show", "celorga ledger create", "celorga ledger update", "celorga ledger event", "celorga doctor"],
        writes: "preview-by-default",
      },
      {
        id: "external-source-sync",
        purpose: "Inspect and run corpus-declared external source mirrors through machine-local slacrawl/notcrawl bindings, validate optional interval/daily schedule intent, then stage bounded raw and review-required Celorga artifacts.",
        commands: ["celorga source list", "celorga source doctor", "celorga source status", "celorga source bind", "celorga source import", "celorga source sync"],
        writes: "mixed",
      },
      {
        id: "portable-runtime",
        purpose: "Track artifact dependencies, select eligible model runtimes by capability policy, expose bounded corpus search, fetch, and context through MCP, or snapshot external MCP integrations.",
        commands: ["celorga artifact", "celorga runtime", "celorga mcp", "celorga skill install"],
        writes: "mixed",
      },
      {
        id: "plugins",
        purpose: "Pin, reproduce, inspect, trust, and run content-addressed Git extensions that contribute CLI commands, templates, sandboxed document renderers, context-aware actions, and lifecycle hooks shared by CLI and app clients; actions and hooks return reviewable proposals instead of writing the corpus.",
        commands: ["celorga plugin", "celorga plugin actions", "celorga plugin action run", "celorga plugin proposals", "celorga plugin hooks"],
        writes: "preview-by-default",
      },
      {
        id: "planning",
        purpose: "Build agendas, inspect the unified run/headline approval queue, and mutate corpus-default and file-defined TODO workflows (active and terminal states), list checkboxes and their progress cookies, planning (including cancelling an entry's repeaters), effort, habit, and clock state.",
        commands: ["celorga agenda", "celorga todo", "celorga todo-config", "celorga daily-config", "celorga migrate-names", "celorga checkbox", "celorga approvals", "celorga plan", "celorga clock", "celorga query clocks"],
        writes: "mixed",
      },
      {
        id: "capture-and-organization",
        purpose: "Capture source material, import browser article/selection clips with immutable raw provenance and revision-guarded review notes, and move reviewable subtrees through archive/refile workflows.",
        commands: ["celorga capture", "celorga browser-clip", "celorga archive", "celorga refile"],
        writes: "preview-by-default",
      },
      {
        id: "knowledge-graph",
        purpose: "Create and resolve IDs, backlinks, nodes, links, entities, indexes, searches, graph reports, bounded local neighborhoods, and source-revision-guarded individual unlinked mentions.",
        commands: ["celorga id", "celorga backlinks", "celorga index", "celorga search", "celorga query", "celorga entity", "celorga roam", "celorga roam connections", "celorga roam mention-link"],
        writes: "mixed",
      },
      {
        id: "file-search",
        purpose: "Find files and folders anywhere under this Mac's indexed folders by name and folder, newest first, with repeat downloads and copies grouped; the index and folder config are machine-local, never in a corpus.",
        commands: ["celorga files search", "celorga files index", "celorga files status", "celorga files config"],
        writes: "preview-by-default",
      },
      {
        id: "agent-context",
        purpose: "Compile and retrieve bounded agent context with source ranges and citations, or render human briefings.",
        commands: ["celorga agent capabilities", "celorga agent context", "celorga agent search", "celorga agent fetch", "celorga agent bundle", "celorga context", "celorga brief", "celorga compile corpus"],
        writes: "mixed",
      },
      {
        id: "json-canvas",
        purpose: "Read, create, edit, import, and export portable JSON Canvas spatial boards with guarded file revisions, local resource previews, and stable Celorga source links.",
        commands: ["celorga canvas show", "celorga canvas targets", "celorga canvas create", "celorga canvas edit", "celorga canvas import", "celorga canvas export"],
        writes: "preview-by-default",
      },
      {
        id: "data-and-charts",
        purpose: "Recalculate safe spreadsheet formulas, inspect or materialize DuckDB-backed datasets, and render deterministic charts from note-local declarations.",
        commands: ["celorga table recalculate", "celorga query-data", "celorga render-chart"],
        writes: "mixed",
      },
      {
        id: "ai-review-lifecycle",
        purpose: "Validate AI jobs and create, review, suggest, and promote provenance-stamped generated artifacts.",
        commands: ["celorga ai"],
        writes: "preview-by-default",
      },
      {
        id: "publishing",
        purpose: "Publish a disclosure-safe document or subtree to a portable web bundle, safe Beamer PDF, Google Doc, Google Slides deck, Google Sheet, or Google Drive PDF; export ordinary documents and slide decks; or publish a multi-file HTML project.",
        commands: ["celorga publish document", "celorga export html", "celorga export beamer", "celorga publish"],
        writes: "preview-by-default",
      },
      {
        id: "maintenance",
        purpose: "Format source and audit corpus metadata, links, provenance, generated artifacts, and graph health.",
        commands: ["celorga fmt", "celorga lint", "celorga graph"],
        writes: "mixed",
      },
      {
        id: "encryption",
        purpose: "Encrypt, decrypt, or re-encrypt scoped :crypt: subtrees with GPG recipients; request credentials through the app's secure sheet instead of chat and use them without printing them.",
        commands: ["celorga crypt", "celorga secret request", "celorga secret status", "celorga secret list", "celorga secret exec"],
        writes: "preview-by-default",
      },
      {
        id: "editor-intelligence",
        purpose: "Expose shared semantic editor behavior through the language server.",
        commands: ["celorga lsp"],
        writes: "read-only",
      },
    ],
    clients: [
      { id: "cli", role: "Canonical automation and integration surface over the shared TypeScript compiler/runtime." },
      { id: "vscode", role: "Best-supported general editing workflow, backed by shared CLI/LSP semantics." },
      { id: "macos-workspace", role: "Native alpha workspace shell with personal/shared corpus mounts, corpus-qualified federated agenda/search, explicit write-corpus switching, capture, reading/editing, meetings, data notebooks, content-hash-trusted sandboxed document renderers, destination-neutral automation scheduling and history, workflow/run/review controls, agent handoffs, and named AI destinations including local or SSH-hosted Pi and OpenCode, Codex, Claude Code, OpenClaw, and direct providers backed by shared compiler semantics. With the default-off Experimental features setting enabled, the document Source editor offers local Paste as Org with editable preview and explicit insertion; direct providers can opt into a bundled foreground agent with bounded search, effective-text reads, and SHA-bound edits requiring native user review." },
      { id: "ios-mobile", role: "Source-distributed mobile corpus and approval client with on-device fuzzy note/heading/body search and rendered entry/full-note reading through the bundled shared parser/renderer; run decisions retain the native run, approval, and fingerprint identity when queued through the mobile inbox." },
      { id: "openclaw", role: "Optional deep agent-runtime adapter: Gateway chat plus a lifecycle plugin that maps substantial work into durable runs, prepares workflow attempts, event-gates scheduled work, and can reconcile generic workflow schedules into OpenClaw cron when that native clock is explicitly selected." },
    ],
    docs: [
      { id: "agent-quickstart", url: "https://celorga.io/agent-quickstart.html" },
      { id: "mcp-and-skills", url: "https://celorga.io/mcp-and-skills.html" },
      { id: "features", url: "https://celorga.io/features.html" },
      { id: "tooling-reference", url: "https://celorga.io/tooling-reference.html" },
      { id: "language-reference", url: "https://celorga.io/language-reference.html" },
      { id: "corpus-flow", url: "https://celorga.io/corpus-flow.html" },
      { id: "collaboration", url: "https://celorga.io/collaboration.html" },
      { id: "workflows", url: "https://celorga.io/workflows.html" },
      { id: "macos-workspace", url: "https://celorga.io/editors-macos.html" },
    ],
  };
}
