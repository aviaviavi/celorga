# Changelog

All notable changes to the Celorga VS Code extension (formerly Org2) are documented in this file. Entries below the Unreleased section keep the names in use when they were released.

## Unreleased

## 0.9.1 - 2026-10-15

## Fixes

Fixes a launch crash on Macs other than the machine used to build Celorga (#589). The Mac app now bundles all workspace resources and resolves them from its own application bundle.

Includes regression coverage for resource lookup and release packaging.

## 0.9.0 - 2026-10-09

# Celorga 0.9.0

OpenOrg and Org2 are now Celorga: one name for the app, CLI, and workspace runtime.

- Renamed app, website, CLI, and agent-facing instructions to Celorga. Install the CLI with `npm i -g celorga`; `org2` remains supported.
- Added compatibility for Celorga configuration, state, properties, tools, editor commands, and plugin names while preserving existing Org2 workspaces. No automatic corpus migration is performed.
- Improved shared AI conversations, agent hand-offs, and single-agent message delivery across hosts.
- Fixed server drain/restart recovery and excluded Skill Workshop background reviews from Agent Work runs.
- Renamed the Vim integration directory to `editors/vim-celorga`; existing Vim users should update their runtime path.

Apple Silicon and Intel Mac installers require macOS 14 or later and are Developer ID signed and Apple notarized. The iPhone build is distributed through TestFlight as version 0.9.0, build 46.

- Renamed the extension to Celorga. The display name, command palette titles (`Celorga: …`), Explorer views, settings section, messages, and documentation now use the Celorga name; the language mode is labeled "Celorga Org".
- The extension now runs the `celorga` CLI when it is on `PATH` and `celorga.agenda.command` (or the legacy `org2.agenda.command`) is not set explicitly, and falls back to `org2`, which remains a permanent compatibility alias.
- The default workspace export index title is now "Celorga Export Index".
- Commands are now `celorga.*` (for example `celorga.openAgenda`). Every `org2.*` command ID is still registered as a hidden alias, so existing keybindings and scripts keep working.
- Settings are now `celorga.*` (for example `celorga.agenda.dir`). Existing `org2.*` settings are still read when the matching `celorga.*` setting is not set, and are marked deprecated in the Settings editor. The agenda status-filter picker updates whichever spelling you already use.
- Power-keymap and VSCodeVim keybindings now use the `celorga.keymap.power` and `celorga.vim.visibleLineNavigation` context keys, which follow the same `celorga.*`-then-`org2.*` rule.
- Compatibility: the marketplace ID (`AviPress.org2-vscode`), the `org2` language ID, view IDs, and `.org`/`.org2` file associations are unchanged.

## 0.8.8 - 2026-10-07

## OpenOrg 0.8.8

- Browse web links and HTML files directly in the workspace, with find, zoom, copy-link, and expand controls.
- See interactive charts in AI chat and documents, with updated styling, tooltips, and series controls.
- Configure Slack, Notion, and IMAP email sources from a single setup form.
- Understand running work through Activity status explanations, host visibility, and clearer Reply & Resume progress.
- Start agent work from TODOs, settle completed chats, and keep active turns recoverable across app and server upgrades.
- Enjoy collapsible sidebar sections, consistent theme surfaces, document @ file suggestions, and syntax highlighting for more than 60 formats.
- Fix stuck chats, stale synced turns, navigation delays during source sync, and OpenClaw steering compatibility.
- On iOS, improve shared chart rendering and syntax highlighting in documents.

Install the Apple Silicon or Intel DMG for your Mac. Both builds require macOS 14 or later and are Developer ID signed and Apple notarized. The iOS build is distributed separately through TestFlight.

Full changelog: https://github.com/aviaviavi/org2/compare/0.8.7...0.8.8

## 0.8.7 - 2026-10-03

## Highlights

- Write in the new macOS Prose mode: keep alternate wording, ghost and revive text, and park fragments in Overflow while retaining ordinary Org source.
- Reply to a specific AI chat message, share threads as live local links, and use server-hosted shared chats.
- Improve chat recovery and synchronization across Mac, iPhone, and remote agents, including queued replies, early steers, and notification deduplication.
- Create files from the sidebar or File menu with Command-Shift-N, and use configured daily-note paths.
- Render linked images inline, insert image links with the source editor's /image command, and highlight code in rendered documents.
- Extend saved views with date variables, date comparisons, and regular expressions; expose experimental Canvases navigation.
- Improve agenda edits, checked-list rendering, chat layout, and settings navigation.

## Installation

macOS 14 or later. Choose OpenOrg.dmg for Apple Silicon or OpenOrg-Intel.dmg for Intel. Both installers are Developer ID signed, notarized by Apple, and stapled. The iOS client is distributed separately through TestFlight as version 0.8.7, build 43.

## Validation

The coordinated release validates the shared runtime, documentation, Node suite, VS Code extension, and macOS Swift suite before publication. Artifact checksums and the complete changelog are included below.

## 0.8.6 - 2026-09-30

## Highlights

- Choose light and dark themes inspired by familiar editors; rendered notes and AI chat follow the active theme.
- Complete date mentions such as `@today` and `@july 10` in chat and editors.
- Preview images and videos in the native file view, and open a thread’s outputs directly from its chat header.
- Improve tab switching, document link cues, file properties, and background refresh stability.
- Keep remote OpenCode turns controllable across restarts and handle prompts beginning with dashes correctly.
- Fix Google Drive republishing with guarded ETags and improve inline DOCX styling.
- Find agent CLIs from Finder-launched OpenOrg and refresh Codex model options.
- Route automatic update downloads through Scarf and add minimal, opt-out desktop launch telemetry.

## Installation

The Apple Silicon and Intel Mac installers are Developer ID signed and notarized. Download the installer matching your Mac. iOS version 0.8.6 is distributed separately through TestFlight.

## Validation

The release pipeline validates the shared runtime, documentation, Node integration suite, VS Code extension, and macOS Swift suite before publication.

## 0.8.5 - 2026-09-26

## Highlights

- Keep AI chat history and active status consistent across the Mac app, headless server, and iPhone, including recovery after interruptions and cross-host sync.
- Add Pi and OpenCode as agent destinations, with model discovery, startup progress, and clearer steering.
- Improve iPhone chat rendering for inline images and formatted replies, and make new threads start faster.
- Fix stale notifications, background PDF refresh errors, source-import validation, and link highlighting.

This release includes the changes since 0.8.4. The macOS downloads are signed and notarized for Apple Silicon and Intel; the iPhone build is distributed separately through TestFlight.

## 0.8.4 - 2026-09-24

# OpenOrg 0.8.4

OpenOrg 0.8.4 makes AI chats started from iPhone full workspace clients of the configured agent machine. Codex can now search authorized Org2 files and prior AI chats, read bounded chat history, edit active-corpus files through reviewed local tools, and—when a remote Codex destination is configured—work directly in that machine's writable corpus checkout with the selected filesystem sandbox.

This release also improves chat reliability and polish: delayed replies remain chronologically visible, stopped turns no longer appear active, remote activity ownership is reported correctly, transport initialization can recover cleanly, the assistant/provider picker works at narrow widths, and direct Anthropic destinations load their model catalogs.

Agenda completions no longer reappear after an older refresh finishes. Large approval collections, including Revenue Scout reviews, now switch and render without mounting every large body at once.

## Highlights

- Full configured machine and Org2 corpus access for iOS-originated Codex chats.
- Search across authorized corpus files and prior AI-chat history.
- Direct writable-checkout support for managed remote Codex destinations.
- Reliable chat recovery, reply ordering, and host-owned activity state.
- Responsive large approval navigation and durable Agenda completion.
- Improved compact assistant/model controls and provider model discovery.

## Installation

macOS 14 or later is required. The downloadable Mac applications are Developer ID signed, hardened, notarized by Apple, and distributed as separate Apple Silicon and Intel DMGs.

## 0.8.3 - 2026-09-21

OpenOrg 0.8.3 focuses on reliable long-running AI work, sturdier workspace refreshes, and several everyday editing fixes.

- Managed Codex conversations now survive Mac sleep and reconnect cleanly without double-resuming a transport. AI context budgeting is tighter and covered by explicit regression fixtures, reducing prompt overhead while preserving the context a turn needs.
- Project state now loads during headless server startup and refreshes resiliently when individual project records are malformed or temporarily unavailable.
- Interrupted meetings can recover captured system audio, and headless OpenClaw operation now preserves device identity and sends valid workflow cron payloads.
- Checkbox progress updates are atomic across the shared runtime and OpenOrg. A new preview-first repair command can resolve stale checkbox progress cookies at the correct heading scope.
- Daily-note creation can be enabled when needed, sidebar trees remain stable during refreshes, heading tags highlight correctly, and agent-run titles stay concise.
- VS Code source blocks now embed the correct grammar for all supported languages and aliases, including C++.

The Mac release includes signed and notarized installers for Apple Silicon and Intel. macOS 14 or newer is required.

The coordinated iOS release is OpenOrg 0.8.3 build 36 for TestFlight.

Full changelog: https://github.com/aviaviavi/org2/compare/0.8.2...0.8.3

## 0.8.2 - 2026-09-17

OpenOrg 0.8.2 makes the local workspace faster, more expressive, and easier to operate across Mac, iPhone, and always-on hosts.

- Documents and AI chats now open dramatically faster through persistent rendering, concurrent parsing, incremental transcript loading, and in-place updates for rendered checkboxes.
- Projects now organize notes and active chats together. iPhone project views can create chats and manage project membership, while settled chats stay out of the active project list.
- New local knowledge tools include editable property views, JSON Canvas workspaces, graph neighborhoods, unlinked mentions, live note and heading embeds, and browser article or selection capture.
- Mac tabs keep their own navigation, filters, selections, editor drafts, cursor positions, view modes, and scroll state. Review navigation and approval handling are more reliable, including an explicit Repair & Retry path for safe run-source reconciliation.
- Automations can pin their destination, model, and reasoning effort; scheduling uses populated model pickers and preserves those choices independently of interactive chats.
- iPhone adds an editable phone-call transcript import flow using Apple transcripts or saved audio, plus more capable project-aware chat navigation.
- PDF previews refresh after file changes, screenshot attachments render inline again, and chat reasoning updates no longer flicker between plain and rich rendering.
- Local Mac builds, workspace refreshes, document rendering, and chat loading received substantial performance improvements.

The Mac release includes signed and notarized installers for Apple Silicon and Intel. macOS 14 or newer is required.

The coordinated iOS release is OpenOrg 0.8.2 build 35 for TestFlight.

Full changelog: https://github.com/aviaviavi/org2/compare/0.8.1...0.8.2

## 0.8.1 - 2026-09-10

OpenOrg 0.8.1 improves chat reliability, document export, and everyday workspace controls.

- Chat selection stays aligned with text across messages and agent rounds. Copying tables includes rich HTML for email and aligned Org text.
- Wrapped tables, narrow chat controls, elapsed-time labels, and Settle/Reopen buttons retain their layout. Read badges stay cleared, and image-only replies render inline.
- Exported PDFs omit heading stars and outline guides while preserving document content and heading styles.
- Quitting during active work shows a normal confirmation; repeating Quit exits. Build-and-restart workflows can retry Quit automatically.
- Chat-history recovery preserves verified history from incomplete syncs, provides Retry, and protects recently synced artifacts from premature cleanup.
- Headless-server credential access and Node executable upgrades no longer stall or crash the app in the previously identified cases.
- Custom TODO workflows can be configured for the corpus, and native checkbox cycling is available through the CLI and LSP.
- An optional bundled foreground agent is available behind Experimental settings; existing chat destinations retain their behavior.

The Mac release includes signed and notarized installers for Apple Silicon and Intel. macOS 14 or newer is required.

No new iOS build is included: TestFlight 0.8.0 build 30 already contains the latest iOS changes.

Full changelog: https://github.com/aviaviavi/org2/compare/0.8.0...0.8.1

## 0.8.0 - 2026-09-06

OpenOrg 0.8.0 keeps iPhone AI chat and scheduled work available through a dedicated Mac, even when your laptop is asleep or away.

- Run the chat relay and automation scheduler without a desktop window using `org2 server`. Pair, inspect, revoke devices, assign the scheduler host, and install a login service from the CLI.
- Reuse existing corpus chat history. The Mac now refreshes conversations and messages arriving through corpus synchronization while preserving selection and unfinished drafts.
- Give scheduled automations one explicit host. Updated Mac and server schedulers enforce that owner and suppress duplicate occurrences. Automatic failover across replicated copies is not enabled.
- Save multiple hosts in the iOS app and choose which host handles chat. Each host retains its own protected pairing credential.
- Improve LSP compatibility with strict clients: notifications receive no response, and split Unicode messages use correct UTF-8 byte framing.
- Fix chat code/table scrolling, refresh stale Codex model catalogs, and keep the headless supervisor alive through temporary nonblocking input reads.
- Make release retries reuse verified artifacts, install native dependencies separately for each Mac architecture, avoid repeated runtime builds, and stabilize the tests that delayed the previous release.

macOS downloads support macOS 14 or later and include the local dictation runtime. Both Apple Silicon and Intel DMGs require Developer ID signing and Apple notarization before publication. iOS 0.8.0 build 28 is distributed separately through TestFlight, subject to Apple's processing and beta review.

For a synchronized corpus, continue a conversation from one execution host at a time. The desktop refreshes replicated history; it does not yet relay desktop messages through the headless server.

## 0.7.2 - 2026-09-03

# OpenOrg 0.7.2

OpenOrg 0.7.2 improves workspace navigation, AI chat, meeting recording reliability, automation management, and everyday document work.

## Highlights

- Added a dedicated Skills manager for workspace-authored agent procedures, available from the sidebar and with Command-Shift-K. The built-in Org2 operating guidance remains ambient and hidden from the user-managed skill list.
- Made tabs represent the full workspace state, preserving the active surface, document selection, pane focus, and pane layout independently across tabs.
- Added a Daily “Choose Date…” action and Command-Shift-7 shortcut for opening or creating the daily note for any date.
- Added workspace filtering and file-tree navigation improvements, plus richer agent handoff metadata.
- Made the document toolbar adapt cleanly from wide to narrow panes and unified the native toolbar and workspace tab-strip appearance.

## AI chat

- Text selection now spans paragraphs, bullets, links, and consecutive messages, with standard Command-C and Edit → Copy behavior.
- Selection highlights align with the rendered typography, wrapping, links, and indentation.
- Tightened corpus-switch persistence so chat state cannot leak across workspaces during rapid transitions.

## Meetings and reliability

- Meeting recordings now retain the original ScreenCaptureKit interruption error and surface system-audio failures immediately.
- Interrupted system-audio recordings are finalized when possible, and non-empty partial artifacts are preserved for recovery instead of being deleted.
- Stabilized editor saves, sidebar navigation, and macOS CI timing-sensitive coverage.

## Distribution

- Apple Silicon and Intel Mac disk images are Developer ID signed, notarized, stapled, and verified with Gatekeeper.
- npm and the VS Code extension are published from the version tag through their normal release workflows.
- iOS build 27 is published to TestFlight for internal and external testing.

## 0.7.1 - 2026-09-02

# OpenOrg 0.7.1

OpenOrg 0.7.1 is a performance and reliability release focused on keeping large workspaces, long AI chats, editing, and background activity responsive.

## Highlights

- Reworked workspace data flow, file cataloging, document mutation, source indexing, and editor buffering to keep navigation and editing responsive as corpora grow.
- Sharded AI chat transcript storage and added a durable operation journal so long histories and background deliveries no longer require rewriting one large shared record.
- Reduced chat rendering, selection, layout, attachment-preview, and teardown work across local, Codex, Claude Code, and OpenClaw conversations.
- Moved expensive Mobile Remote work away from latency-sensitive UI paths and tightened synchronization with the desktop workspace.
- Added explicit performance budgets, representative large-corpus fixtures, native regression gates, and dedicated macOS performance CI.
- Made subprocess stdin and output handling resilient around EOF and process teardown.
- Corrected daily-note placement so invalid or missing configuration falls back to the corpus's `daily/` directory instead of the corpus root.

## Reliability

- Stabilized timing-sensitive macOS tests and performance workflows while preserving deterministic regression coverage.
- Removed redundant or timing-dependent integration cases that duplicated stronger behavioral checks.
- Updated the release procedure to preserve successful architecture artifacts, resume checkpoints, and use GitHub Trusted Publishing for npm without requiring a local npm token.

## Distribution

- Apple Silicon and Intel Mac disk images are Developer ID signed, notarized, stapled, and verified with Gatekeeper.
- npm and the VS Code extension are published from the version tag through GitHub Trusted Publishing and the Marketplace workflow.
- iOS is intentionally not included in this release.

## 0.7.0 - 2026-09-01

# OpenOrg 0.7.0

OpenOrg 0.7.0 makes ordinary `.org` files the default, formalizes the Org2 language contract, and adds a complete first pass at destination-neutral automations and portable agent tooling.

## Highlights

- New documents use `.org`, while existing `.org2` files remain fully supported. Markdown-style fences and inline backticks remain convenient input syntax and are saved canonically as Org syntax.
- The language standard now includes a normative EBNF surface grammar, contextual parsing rules, executable ambiguity cases, canonical AST schema, and conformance fixtures without replacing the optimized production parser.
- OpenOrg Automations can target Codex, Claude Code, OpenClaw, or direct providers; schedule controls cover intervals, daily, weekdays, weekly, monthly, timezone-aware times, and advanced cron expressions.
- Automations now surface creation and scheduler errors, can be deleted from the Mac UI with preserved run history, and expose a preview-first `org2 workflow delete` command.
- A portable Org2 agent skill now ships with npm and OpenOrg, alongside a dedicated MCP and agent-skills guide and a preview-first skill installer.
- Local web/PDF publication links persist across relaunch and now keep the same URL when the same document scope and format are republished.
- Charts support multiple series, and `.org` canonicalization is consistent across the Mac app, CLI, LSP, and VS Code.

## Reliability and polish

- Reduced source-editor typing lag by removing a highlight feedback loop.
- Improved large AI-chat performance, stale-task recovery, and transcript-wide text selection across paragraphs and messages.
- Improved live workspace tab dragging and stabilized timing-sensitive CI checks.
- Reduced duplicate validation in the coordinated release pipeline while preserving its independent publication gate.

## Compatibility

- Existing `.org2` documents and structured runtime records remain supported.
- This release updates the npm package, VS Code extension, and notarized Apple Silicon and Intel OpenOrg builds.
- iOS/TestFlight is intentionally not included in this release.

## 0.6.0 - 2026-08-30

## Highlights

- OpenOrg now keeps Google Drive publications linked to their source. The first publish records the Drive artifact and guarded version in the relevant `.org2` property drawer; publishing that scope and format again updates the same Doc, Slides deck, Sheet, or PDF instead of creating a duplicate.
- A green Google Drive badge in the document header makes linked artifacts easy to reopen or copy, and the publish sheet clearly distinguishes first-time publishing from updating an existing destination.
- Distributed Mac builds now include OpenOrg's registered Google OAuth desktop client, so most users can connect Google Drive directly while custom clients remain available for self-built deployments.
- The workspace's Context pane and source-cited Brief experience are now represented throughout the product guidance, demo corpus, and generated site.
- Release packaging now verifies the Google OAuth configuration before producing distributable Mac artifacts.

## Stability and polish

- Preserves guarded Google Drive replacement semantics so remote changes or comments are not silently overwritten.
- Improves the getting-started guidance around runtime-neutral agent work, triggers, approvals, and durable corpus records.
- Refreshes the macOS product screenshots and feature presentation for the current workspace UI.

## 0.5.4 - 2026-08-30

## OpenOrg 0.5.4

- Adds signed automatic updates to the Mac app.
- Checks quietly at launch and every two hours by default.
- Adds a manual Check for Updates command and settings to disable checks or install downloaded updates on quit.
- Supports Install, Remind Later, and Skip This Version through the standard macOS update flow.
- Publishes architecture-specific, cryptographically signed update feeds for Apple Silicon and Intel.
- Adds independent workspace tabs with mouse selection, close controls, right-click actions, drag-and-drop reordering, and keyboard navigation.

## 0.5.3 - 2026-08-30

## Highlights

- Add Local Claude Code as an optional OpenOrg AI destination using the installed Claude Code CLI and the user's existing Anthropic sign-in.
- Stream replies, resume Claude sessions, pass explicit attachments and corpus context, and expose Claude Code through shared rooms and Mobile Remote.
- Map OpenOrg local-agent permissions to Claude Code Plan, Accept Edits, and Bypass Permissions modes while preserving the participants in existing rooms.

## 0.5.2 - 2026-08-28

- Coordinated the extension with the OpenOrg 0.5.2 alpha release and current Org2 runtime.
- Added format-on-save defaults and pane-aware list selection shortcuts.
- Included the latest approval-state, source-sync, AI chat rendering, and local Codex recovery fixes.

## 0.5.1 - 2026-08-27

- Coordinated the extension with the OpenOrg 0.5.1 alpha release and current Org2 runtime.
- Improved node actions, search routing, and approval workflows shared with the OpenOrg apps.
- Included the latest parser, editor responsiveness, remote-agent, and generated-site reliability fixes.

## 0.5.0 - 2026-08-24

- Coordinated the extension with the OpenOrg 0.5.0 product launch while preserving the Org2 developer-tooling name and extension identifier.
- Added corpus-aware node actions, richer AI review workflows, and compatibility with the redesigned OpenOrg desktop and mobile clients.
- Improved agenda ordering, editor reliability, formatter commands, and the shared Org2 runtime integration.

## 0.4.2 - 2026-08-19

- Coordinated the Marketplace package version with the Org2 CLI and macOS workspace 0.4.2 release.
- Prioritized overdue agenda items by Org priority while preserving configurable agenda ordering.
- Expanded status-filter normalization and kept editor commands aligned with the current Org2 runtime.

## 0.4.1 - 2026-08-02

- Coordinated the Marketplace package version with the Org2 CLI and macOS workspace 0.4.1 release.
- Kept extension behavior compatible with the current Org2 language runtime; this patch contains no extension-specific command or UI changes.

## 0.4.0 - 2026-07-19

- Added syntax highlighting for checkbox progress cookies (`[n/m]`, `[p%]`).
- Agenda property filters now follow Org2 effective property inheritance from file and ancestor heading drawers.
- Added syntax coverage tests for Org timestamp repeaters and warning offsets.
- Agenda rows now surface CLI habit metadata with a compact streak-ish `habit ×N` cue and tooltip details.

## 0.1.0 - 2026-05-24

Minor release for the expanded editor workflow surface.

Highlights:

- New-node creation now pre-fills the title from selected/highlighted text.
- Added graph audit and AI review/status commands to the command palette.
- Added power-keymap bindings for graph audit, AI draft lifecycle status, and subtree promote/demote/move commands.
- Documented the new editor commands and shortcuts.

## 0.0.2 - 2026-03-26

Patch release for Marketplace publishing.

## 0.0.1 - 2026-02-22

Initial Marketplace preview release.

Highlights:

- Org/Org2 language support (syntax highlighting, folding, clickable links)
- Agenda view powered by `org2` CLI
- TODO/planning edit commands
- Capture, archive, and refile commands
- Roam workflows (IDs, backlinks, dailies, node creation, link insertion)
- HTML export commands
- Org-crypt subtree encrypt/decrypt commands
- Power keymap with Org-focused command chords
