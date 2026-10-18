# Celorga Agent Guide

**Celorga** is one brand for the app, runtime, and CLI (`celorga`). User-facing
text says Celorga. Some persisted and internal identifiers keep their earlier
spelling (bundle IDs, schema IDs, Keychain and preference keys, source
identifiers such as `Org2Workspace`); `docs/rename/celorga.org` lists them and
the name-compatibility rules. Check remaining user-facing names with
`node tools/celorga-rename-audit.mjs`.

This repository contains two closely related layers:

- **The Celorga app** is the user-facing macOS and iOS workspace.
- **The Celorga runtime** is the independently specified compiler/runtime and
  semantic profile for ordinary `.org` documents, plus the CLI, schemas,
  publishing system, plugin runtime, and editor tooling beneath the app.

These instructions are runtime-neutral. OpenClaw, Codex, Claude Code, and other
agents may work here, but no agent runtime, app cache, generated index, or model
memory is the source of truth.

## Start here

1. Read this file, inspect `git status --short --branch`, and check the current
   worktree before editing. Preserve unrelated work in a dirty checkout.
2. Decide whether the request changes this repository or a Celorga corpus. This
   file governs repository work. Corpus work also follows the nearest corpus
   `AGENTS.md` and `celorga.json`; the corpus's plain-text files remain
   canonical there.
3. In a fresh checkout, install the locked dependencies with `npm ci`. Reuse
   an existing `node_modules/` only when the lockfile has not changed.
4. Build before using the checkout's CLI, then ask the implementation what it
   supports:

   ```sh
   npm run build
   npm run celorga -- agent capabilities
   npm run celorga -- --help
   npm run celorga -- COMMAND --help
   ```

   Prefer `npm run celorga -- ...` or `node dist/cli.js ...` during
   development. A globally installed `celorga` may expose a different version.
5. Choose the smallest affected surface and its focused tests before making a
   broad change. Check documentation impact at the same time as code impact.

## Native Celorga tooling

Use Celorga's native CLI by default for Org operations such as search, agenda, TODOs, links, tables, export, and validation. Prefer exposed Celorga workspace/MCP tools for operations they support; client-required effective-text reads and reviewed writes take precedence over shell access. Discover commands with `celorga agent capabilities` and `celorga COMMAND --help` before choosing a workaround. Celorga is an independent runtime: a .org file does not imply GNU Org semantics or an Emacs dependency.

Do not invoke `emacs`, `emacsclient`, batch Emacs Lisp, or an Emacs Org exporter as an implicit fallback. Do not assume Emacs is installed, probe for it, or install it for ordinary Celorga work. Use Emacs only when the user explicitly requests an Emacs-specific task. This does not prohibit other tools for work outside Celorga's scope.

If a native operation appears missing or broken, check the installed version, capabilities, and relevant help first. Distinguish a missing executable, permission restriction, or unavailable tool from a confirmed Celorga capability gap; do not bypass access or review boundaries. State the exact limitation and use a small, supported, reviewable alternative when available. Never silently substitute GNU Org behavior or execute preserved unsupported formulas or source blocks. If this is authorized Celorga development with repository access, reproduce and fix the shortcoming and add a focused regression test. Otherwise, suggest opening an issue at https://github.com/aviaviavi/celorga/issues and prepare a sanitized report with the version, command/tool, minimal input, expected and actual behavior, and workaround. Do not publish an issue or private corpus content without the user's authorization. If shell execution is unavailable, use the exposed tools and explain any remaining limitation rather than inventing command results.

## Source of truth and safety

- Treat inspectable plain text as canonical. Derived indexes, compiled context,
  reports, app state, generated pages, and runtime state must be disposable or
  reconstructible.
- Preserve source ranges, stable IDs, file/line citations, provenance, hashes,
  and review state across compiler and agent workflows.
- Most Celorga mutations preview by default and require `--apply`. Inspect the
  preview or JSON envelope before applying it.
- Keep generated or uncertain corpus work in reviewable zones such as `views/`
  or `compiled/`; promotion into canonical `notes/` is an explicit action.
  Keep immutable imports and provider payloads in `raw/`.
- Never put credentials, tokens, cookies, private keys, model credentials, or
  machine-local bindings in source, fixtures, corpora, runs, plugins, generated
  artifacts, or documentation examples.
- Keep private corpus context out of public material. Release notes, commit
  messages, changelogs, code comments, and test fixtures must use fictional names
  and synthetic data, not a user's private agent names, customer details, real
  workflow content, or machine-specific paths. Check the complete staged diff and
  publication text before pushing or publishing.
- Multi-corpus reads require explicit mounts. A corpus visible in the Celorga app is not
  implicit agent authority, and writes remain scoped to one active corpus.
- Do not perform external side effects such as sending messages, creating
  tickets, publishing, installing plugins, restarting services, or changing a
  user's daily app unless the user explicitly authorizes that action.
- Durable run and workflow writes are guarded and atomic. Carry
  `--if-revision` when state crosses requests; never hand-edit machine-state
  blocks in the corpus state directory's run files.

## Working in a concurrent repository

- Existing modifications and untracked files belong to the user or another
  worker unless you know otherwise. Never discard, stage, format, or commit them
  as a side effect of your task.
- If the primary checkout is dirty or behind `origin/main`, use a clean,
  isolated worktree based on the current remote tip. Fetch and rebase again
  immediately before pushing because this repository changes frequently.
- Keep commits single-purpose. Do not mix generated output, release metadata, or
  another worker's feature into a convenient commit.
- Do not commit, push, tag, publish, or open a pull request unless the user
  requested that external action. A request to push a scoped change authorizes
  the normal commit and push needed for that change, not unrelated work.
- Avoid destructive Git commands. Resolve exact targets first, and prefer a
  recoverable or isolated workflow when a checkout contains work in progress.

## Product and architecture

- The TypeScript compiler/runtime under `src/` owns parsing, semantics, source
  ranges, IDs, links, agenda behavior, corpus operations, agent interfaces,
  publishing, plugin contracts, and LSP behavior. Build output goes to `dist/`.
- Apps and editor integrations consume shared semantics. Do not create a second
  parser, a private canonical database, or app-only language behavior.
- `apps/macos/Org2Workspace/` is the native Celorga app workspace. It supports
  local and explicitly mounted corpora, reading/editing, capture, meetings,
  publishing, data views, plugins, durable agent work, and per-thread AI chat
  through configured runtimes such as OpenClaw and Codex.
- `apps/ios/Org2Mobile/` is the source-distributed mobile capture, corpus, chat,
  and approval client. Its inbox flows are transport boundaries, not new
  language semantics.
- `integrations/openclaw/` contains the optional Celorga Lifecycle adapter
  (plugin ID `org2-lifecycle`).
  OpenClaw is a native integration, not the owner of runs, workflows, approvals,
  or corpus state.
- The plugin runtime installs content-addressed Git packages, pins exact commits
  and SHA-256 contents in the corpus lock, and requires machine-local trust
  before contributed commands or sandboxed renderers execute. The CLI and the
  app use the same renderer contribution; there is no separate app-only plugin ABI.
- Prefer one coherent Celorga standard over bug-for-bug GNU Org compatibility.
  Keep AI/provider behavior optional above deterministic compiler output.

## Agent runtimes and durable work

- Goals are portable goal records and named workers are agent-profile
  records. OpenClaw, Codex, Claude Code, model names,
  and session IDs are execution details, not `AGENT_REF` values.
- Resolve the current runtime binding with `celorga agent-profile resolve` before
  creating delegated work. Preserve an existing `AGENT_REF` or `GOAL_REF`;
  if no binding resolves, leave the refs unset rather than guessing.
- Use `celorga run` for durable delegated work and `celorga workflow` for reusable
  recipes. Use the CLI lifecycle commands instead of rewriting run files.
- Treat approvals, clarifications, failed checks, and `review-required`
  artifacts as open boundaries. An agent turn succeeding does not by itself
  complete the durable run.
- Use `celorga approvals` for the unified decision queue and
  `celorga run approval-decide` for run-backed decisions. Preserve the exact run,
  approval, fingerprint, and provider decision-key identity; do not create a
  duplicate heading for the same decision.
- Blocking requires a specific question or next action. Completion requires a
  concise reviewer-facing outcome and no unresolved approval or artifact review.
  Only a person may confirm whole-run completion outside the workflow.
- To start another agent's turn, message it directly: `celorga thread send`
  (MCP `celorga_thread_send`) for a single-agent chat, or an @mention or
  `celorga thread post --request-turn` in a shared room. Do not create an
  automation or scheduled job just to trigger a turn.
- Otherwise use `celorga thread post` or the matching MCP tool only when an
  explicitly asynchronous worker must report into a named AI chat. Foreground
  agents reply normally and must not duplicate their response through the inbox.
- When changing the OpenClaw adapter, preserve its configured single-corpus
  boundary, portable corpus-ID validation, stable correlation/idempotency keys,
  approval continuation semantics, and runtime metadata without credentials.
  Read `integrations/openclaw/README.md` before modifying or installing it.

## Repository map

- `src/`: shared TypeScript compiler/runtime, CLI, corpus, publishing, plugin,
  workflow, agent, data, and LSP implementation.
- `test/`: Node integration and regression tests; `test/agent/` contains
  focused agent/context coverage.
- `spec/v0/`: language, schema, and conformance contracts.
- `apps/macos/Org2Workspace/`: Swift package for the Celorga app on macOS, support
  executables, and Swift tests.
- `apps/ios/Org2Mobile/`: iOS app, share extension, and mobile navigation
  contract.
- `integrations/openclaw/`: OpenClaw lifecycle plugin and tests.
- `editors/`: VS Code and Vim integrations.
- `tree-sitter-org2/`: grammar and editor queries.
- `docs/site/`: canonical public documentation sources.
- `site/`: generated website output; never hand-edit it.
- `examples/`: reviewable examples, plugin packages, and synthetic demo
  corpora.
- `tools/`: build, packaging, release, documentation, benchmark, screenshot,
  and maintenance scripts.
- `.codex/skills/`: repository-owned operational skills, including the release
  procedure.
- `.codex/org2-workspace-corpus/`: disposable corpus for the isolated macOS
  development app.

## Implementation rules

- Put shared language and automation semantics in TypeScript first. Swift,
  plugins, and editor extensions should consume shared output rather than
  reinterpret source.
- Keep changes small and preserve existing formatting, source ranges, and
  compatibility identifiers where possible.
- Treat JSON envelopes, schemas, CLI flags, MCP tools, plugin manifests, and
  renderer results as public contracts. Version or migrate them deliberately.
- Add or update a focused regression test for behavior changes. Prefer the
  narrowest useful test while iterating, then broaden validation according to
  risk.
- Keep deterministic behavior below optional AI integrations. Tests must not
  require live provider credentials or mutate a user's real corpus.
- Preserve compatibility across the CLI, the app, editors, and agent adapters
  when changing a shared capability.
- If a failure predates the change, record evidence and prove the change does
  not introduce a new failure.

## Validation matrix

Choose checks that cover the affected surfaces:

```sh
# TypeScript compile
npm run build

# Focused Node regression
node test/path-to-test.mjs

# Agent, corpus, OpenClaw, LSP, or publishing surfaces
npm run test:agentic
npm run test:corpus
npm run test:openclaw
npm run test:lsp
npm run test:publish-document

# Native macOS package
npm run test:macos

# Documentation and generated-artifact contracts
npm run docs:check
npm run check:generated

# Full repository suite
npm test
```

Use focused checks while iterating. Run the full suite for broad parser, CLI,
schema, publishing, plugin, or cross-client changes. An instruction-only change
does not require every runtime suite, but it must still pass the documentation
contract that reads this file.

## Documentation contract

- Treat documentation impact as part of every feature. Update canonical sources
  under `docs/site/`; do not hand-edit generated `site/` HTML.
- Run `npm run docs:check` when agent discovery, CLI/API behavior, workflows,
  safety boundaries, configuration, app surfaces, or product claims change.
- When public documentation changes, regenerate the checked-in site with the
  repository publish command and use `npm run check:generated` when the
  generated contract is in scope.
- When adding or removing a public capability, keep
  `celorga agent capabilities`, `docs/site/agent-quickstart.org`,
  `docs/site/llms.txt`, `docs/site/features.org`, and the relevant
  reference/editor page aligned.
- Keep public positioning provider-neutral. The homepage and features page may
  name supported harnesses and providers as compatibility examples, but must
  not imply any one runtime is required. Runtime-specific integration details
  belong in the agent quickstart, tooling reference, or integration docs rather
  than the product homepage.
- If no user-facing documentation change is needed, state why in the handoff.

## macOS development safety

The user's daily Celorga app is installed at
`/Users/avi/Applications/OpenOrg.app` with bundle
identifier `org.org2.workspace`. Do not quit, overwrite, re-sign, or relaunch
it unless the user explicitly asks to update the daily app.

Use the isolated development app:

```sh
npm run build:macos-app:codex
npm run open:macos-app:codex
```

These commands install `/Users/avi/Applications/OpenOrg Preview.app` with
bundle identifier `org.org2.workspace.codex` and use the disposable
`.codex/org2-workspace-corpus`. Do not point the preview at a personal corpus
without explicit permission. If the build guard reports that the preview is
running, quit only the preview app (shown as **Celorga Preview**) before
rebuilding.

Use `npm run build:macos-app` only when the user asks to promote a validated
build to the daily app. Release packaging uses isolated staging and must not
replace or launch the daily bundle. For UI changes, combine focused Swift tests
with an isolated build and proportionate visual verification.

## Coordinated releases

Use the repository-owned `.codex/skills/org2-release/SKILL.md` workflow when
cutting, repairing, or auditing a release. The canonical
`npm run release:openorg -- ...` command is preview-first and coordinates npm,
VS Code, macOS DMGs, iOS/TestFlight, GitHub Releases, and Scarf-backed download
surfaces.

Do not reconstruct a coordinated release manually unless repairing one
explicitly scoped channel. Require a clean, synchronized `main`, inspect the
plan before `--execute`, retain checkpoint state, and verify every published
surface before reporting completion.

## Before handing off

1. Re-read the complete diff and confirm only intended files changed.
2. Run the smallest complete validation set for every affected surface.
3. Check `git status --short --branch` and remote divergence again.
4. Report the behavior or guidance changed, validation run, documentation
   impact, remaining risks, and any external actions performed.
5. If a commit or push was requested, report the exact commit and destination.
