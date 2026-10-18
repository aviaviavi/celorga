# Celorga for OpenClaw

This directory contains the native OpenClaw runtime integration for Celorga Run Center.
It is deliberately maintained in the Celorga repository so lifecycle schema and CLI
changes can be tested with the bridge that consumes them.

The plugin tracks substantial main-agent turns, subagent executions, and cron
executions. Internal runtime maintenance, including Skill Workshop background
reviews in `internal-session-effects` sessions, does not create durable runs;
explicitly requested skill work is still tracked. Celorga's destination-neutral scheduler is the portable default for
plain prompt automations. As an optional runtime-native adapter, this plugin can
also prepare manual Celorga workflow runs before agent execution, reconcile active
schedule triggers from visible workflow files under `workflows/` into OpenClaw cron, and
continue any correlated existing run in its chat session
after its complete current approval boundary returns the run to `running`.
Continuation does not require a reusable workflow and is keyed to the exact
approval boundary so a repeated request does not enqueue the action twice. A revision request must carry
concrete feedback; for an eligible revision-only boundary, the plugin resumes
the correlated session with that durable decision note and instructs the agent
to produce replacement review material on the same run without performing the
protected action. Provider-backed approvals keep an exact
`Provider draft: PROVIDER:TOOL:DRAFT_ID` line. OpenClaw discovers pending
`decisionKeys` from `celorga approvals --format json` and resolves the canonical
pending or decided authority through `celorga run approval-resolve --decision-key
KEY --json`; the CLI owns idempotent request and decision reconciliation, so the
adapter must not create a parallel review run for the same provider action.
Scheduled executions retain one
logical workflow identity while each cron firing has a distinct attempt. When a
schedule declares a Celorga event/fresh-work gate, the adapter asks the CLI to
create the attempt and stops workflow work when the gate returns a skip instead
of inventing an empty durable run. Successful turns record a reviewer-facing
outcome summary; approval and clarification boundaries remain open instead of
being mistaken for completion. Available provider, model, token, and
elapsed-time metadata is copied into the durable run.

A Celorga AI chat prompt can carry =CELORGA_AI_CHAT_THREAD_ID=. When a parent
explicitly delegates asynchronous reporting, it should copy that exact marker,
the active corpus root, readable author identity, source/run reference, and a
stable idempotency key into the subagent or cron prompt. Lifecycle-generated
workflow and continuation prompts teach workers to use =celorga thread post ...
--apply= only after the reported run state or artifact is durable. The plugin
does not automatically mirror every completion into chat: foreground turns
already have a normal reply path, and automatic mirroring would create
duplicates. Agents using the Celorga MCP surface discover the equivalent
=celorga_thread_post= tool through =tools/list=.

After requesting a run approval, leave the run in `waiting-approval`; do not
also create a writable approval heading or block the run with another phrasing
of the same decision. The CLI rejects that block transition. A genuinely
independent clarification or operational condition requires
`run block --separate-from-approval`, and approval-shaped reasons remain
invalid even with the override.

The Mac app's **Reply & Resume** action uses the plugin's
`celorga.run.replyAndResume` gateway method. The method records the exact response,
resumes the blocked run, and returns a continuation prompt for the correlated
OpenClaw session. Cron mappings retain their agent-scoped session key for this
purpose. A legacy or otherwise uncorrelated run still returns the same durable
continuation prompt without inventing a session; the Mac app starts a
deterministic run-scoped OpenClaw thread carrying the existing run ID. If the
app cannot attach or dispatch the continuation, it durably blocks the same run
with a retry instruction instead of leaving a misleading `running` status.

OpenClaw is the runtime adapter, not the portable worker identity. Before it
creates or attaches a run, the plugin derives the configured OpenClaw agent ID
from the hook/session identity and calls `celorga agent-profile resolve --runtime
openclaw --runtime-agent-id ID`. A matching active profile contributes its
stable `agentRef` and optional primary `goalRef` to the run or workflow. The
correlation comment retains the non-secret OpenClaw agent ID and resolved refs
for inspection. An unbound identity remains unprofiled; ambiguous bindings or
a missing primary goal fail instead of silently attributing work to the wrong
agent. Credentials, session IDs, provider/model selection, and tokens do not
belong in `agent-profiles/`.

Delegated prompts may attach a worker to an existing run with an
`CELORGA_RUN_ID:` marker. If a tracked OpenClaw session ends without delivering a
terminal agent event, the adapter fails that still-active run as interrupted
instead of leaving it indefinitely `running`. Runs deliberately paused for an
approval, clarification, or artifact review remain open.

The plugin also enforces approval continuity for external-message drafts. After
a supported connector or CLI creates or updates an unsent draft, the plugin
creates one dedicated Celorga run per provider draft, requests a readable approval
containing its recipients, subject, and body, and records the provider draft
identity in its private lifecycle state. A later send of that draft is blocked
by =before_tool_call= until the exact Celorga approval is approved. Successful
sends reconcile and complete the draft run. Material draft updates supersede a
pending approval and request a fresh decision.

Draft approval runs also carry structured recipient and provider-draft context.
The exact readable message is stored as the approval note as well as its action,
so safety-conscious clients can distinguish attached review material from an
opaque action label.
The approval is role-gated to the run owner, but deliberately does not set a
named `requestedFrom` assignee: the macOS client records decisions as the
Mac app's workspace actor (`Org2Workspace`). Approval clients use these machine-readable fields to
determine that the item is actionable; readable prose in the approval action is
necessary for review but is not sufficient by itself.

For =gog= Gmail automation, draft safety is enforced before the approval
boundary. Direct =gog gmail drafts create= and =update= tool calls are blocked
by default. Agents must use =bin/gmail-draft-safe.mjs=, which creates a
=multipart/alternative= message with fluid HTML and a plain-text fallback,
rejects hard-wrapped prose, anchors replies to a surviving non-draft message,
and reads the provider draft back before returning success. This keeps a draft
that looked normal in Gmail's narrow composer from becoming a fixed-width
plain-text message after send. Set =enforceSafeGmailDrafts: false= only for an
integration that supplies an equivalent provider-side invariant.

The draft helper loads its private recipient-salutation validator from
`CELORGA_GMAIL_PREFLIGHT_MODULE`, or from
`~/.config/celorga/gmail-recipient-preflight.mjs` when unset. The module must export
`validateRecipientSalutation`. Keep that local binding and validator outside the
public repository. A missing validator fails closed before any draft mutation.

The built-in effect recognizers cover direct tools whose operation names
contain =draft= plus =create/save/update/upsert= or =send/deliver=, and the
configured Google Workspace CLI form (=gog gmail drafts create/send=).
Connectors should expose stable provider draft IDs for deterministic matching.

The adapter remains pinned to one configured `corpusDir` for writes. Mac
workflow requests include the selected portable corpus ID, and the plugin
rejects a mismatch before creating, syncing, or continuing work. Stable
OpenClaw keys are persisted for correlation and deduplication. Ordinary
conversation and personal TODOs are not promoted into runs.

The plugin also registers the safe-by-default macOS node policy for
`celorga.workspace.read`, `celorga.workspace.patch.preview`, and
`celorga.workspace.patch.apply`. Those
commands are implemented by the paired Celorga Mac app, not by the Gateway
plugin. They provide an optional local edit
transport with active-turn IDs, SHA-256 preconditions, preview tokens, and
active-corpus path confinement; they do not expose `system.run`. Enabling the
Mac setting requires a separate node-role pairing, and the selected agent must
have its `nodes` tool enabled.

Local development:

```sh
cd integrations/openclaw
npm test
openclaw plugins install --link .
openclaw plugins inspect org2-lifecycle --runtime --json
```

OpenClaw configuration must explicitly enable `org2-lifecycle`, allow its typed
conversation hooks, and set `corpusDir` to the target Celorga corpus.

## Identifiers

- The plugin ID is `org2-lifecycle`, and its private state file is
  `~/.openclaw/org2-lifecycle/state.json`.
- Gateway methods are `celorga.workflow.*`, `celorga.draft.resume`, and
  `celorga.run.*`. Prompt markers use the `CELORGA_X:` form (for example
  `CELORGA_RUN_ID`, `CELORGA_WORKFLOW_ID`, `CELORGA_SELECTED_AGENT_REF`).
- The plugin runs the `celorga` executable. It does not read environment
  variables, `celorga.json`, or the corpus state directory itself; it goes
  through the CLI.
