# Celorga for iOS

This is the Celorga iOS app for phone-side review of Org documents:

- reads a Files-accessible Celorga corpus folder;
- fuzzy-searches pages, headings, and entry text locally, with rendered entries and an Open full note action;
- shows scheduled/deadline TODOs in a basic agenda;
- reads the canonical agenda and approvals from the paired Mac when Mobile Remote is configured;
- falls back to corpus-local agenda and approval discovery only when no Mac is paired;
- queues new notes in `mobile-inbox.org` so desktop sync can merge/refile them safely;
- lets new notes become scheduled TODOs with Today, Tomorrow, Next Week, Next Month, or a picked date;
- installs a Share extension named "Capture to Celorga" for OS-level capture from apps such as X;
- imports traditional iPhone calls from New Note → Import Phone Call: paste the transcript created by Apple's iOS 18.1+ Call Recording feature, or transcribe a saved audio recording with iOS Speech as a fallback;
- appends approval/discussion actions to `mobile-inbox.org` in the selected corpus;
- opens a WhatsApp share URL for approval discussion fallback.
- pairs directly with Celorga on a Mac over Tailscale for live AI chat control.

New-note capture remains a durable outbound request that can sync back to a desktop agent or OpenClaw workflow. When a Mac is paired, approval decisions and TODO state changes execute directly through the Mac's shared Celorga runtime and update the phone only after canonical state is returned.

For a cellular call, first make sure everyone is willing to be recorded, then use the Phone app's built-in Call Recording control. iOS announces the recording to every participant and saves the recording and, where supported, its speaker-labeled transcript in Notes. Copy that transcript, open **New Note → Import Phone Call** in Celorga, and use the native **Paste** control. Verify the transcript before saving it. If Notes did not produce one, save the audio to Files and choose **Choose Audio Recording** instead. Call recording and transcription availability varies by region, language, device, and OS version. Celorga cannot and does not tap another app's live call audio.

## Sync Shape

Recommended first setup:

1. Sync the corpus into an iOS Files-visible folder with Möbius Sync or another Syncthing-compatible app.
2. Open Celorga and select that folder.
3. Capture notes and approval/discussion actions into `mobile-inbox.org` in the synced corpus root.
4. Let the desktop side consume queued headings and apply review status changes.
5. Refile mobile notes into daily files after sync has settled.

Tailscale can help devices see each other, but iOS does not provide reliable always-on Syncthing-style background daemon behavior. Treat phone sync as opportunistic: open the sync app before reviewing if the corpus has to be current.

## Mobile Remote

Mobile Remote is independent of corpus file sync. It keeps the Mac app as the AI runtime while the iOS AI sidebar lists chats, creates or forks a chat using any enabled Mac destination, including Codex, Claude Code, and OpenClaw, pins and settles or reopens threads, and links to read-only External Threads. Corpus-backed Projects appear as collapsible groups with active member chats; settled members stay out of those groups and remain available under Settled. A project menu can create a chat directly inside that project, and each thread's context menu can add or remove its project memberships. These mutations update the canonical project note on the host before the phone accepts them. Thread screens choose a model and supported reasoning level, dictate into the composer, attach up to four photos, send messages, follow the live connection and work phase, stream replies, copy any message, and stop a live turn. They are presented outside the workspace tab container, so the chat composer is the only bottom control bar while reading a conversation. While a response is active, Send becomes Steer when the selected destination supports live steering; long-pressing it offers Queue as Follow-up instead. Mention completion is available in the composer. Mentioning another destination in a single-agent chat automatically forks the transcript into a new shared room, navigates to it, and sends the message to that harness while leaving the source thread unchanged. The External Threads entry separately lists the same recency-ordered, paginated native Codex catalog exposed by the paired Mac, filters every loaded title, preview, workspace path, and source, loads a full transcript only when opened, and never resumes or mutates the external task. **Fork into Celorga** saves a provenance-marked snapshot under `views/external-threads/` and creates a new local Codex chat with that file staged as context. While a turn is running, meaningful tool activity appears in the same grouped presentation used by the Mac app; low-signal lifecycle events are filtered so an empty activity panel is never shown. Scrolling above the latest content reveals a floating jump-to-bottom control; new streaming content follows automatically only while the reader remains near the bottom. Cited links use Celorga's compact accent treatment instead of displaying transport syntax; cited Org links first open the complete local synced file and scroll to the cited line, falling back to the paired Mac only when the local copy is unavailable. The reader preserves long source lines and scrolls both horizontally and vertically. The dedicated **Files** tab indexes readable text files in the selected corpus and searches note titles, headings, and entry text on-device while the user types. Queries such as `pour over`, `pourover`, or `por over` find a “Pour over” heading, with heading matches ranked above body mentions; `coffee` finds entries mentioning coffee. Results show their parent note and a short preview. Tapping an Org result opens the rendered page or heading subtree, with **Open full note** and **Source** available. Search uses all visible Org files, independent of agenda-file selection, respects corpus ignores, refreshes from synced source, and caches its index for reopening. The bundled shared Celorga parser and HTML renderer run locally; opening a result never requires the Mac or Tailscale. The local rendered reader disables scripts and remote embedded resources; non-Org text files and chat citations retain the source reader. In the thread list, swipe right to pin or unpin and swipe left to settle or reopen. A message sent from iOS uses the same thread continuation envelope as the Mac composer: a bounded excerpt of the local transcript plus the thread's cited Org file references, supplementing the runtime session cache. It does not inherit whichever page happens to be open on the Mac; only a message composed on the Mac may additionally include that visible selection. Dictation is handled by iOS and its audio is not sent to the Mac. The recorder validates that iOS has a usable microphone input before installing an audio tap and presents a recoverable error when another audio session temporarily owns the input. Photos are resized before they cross the tailnet.

A thread that edited or linked files shows an Outputs chip in its toolbar, the counterpart of the Mac chat header chip. The host derives the outputs with the same shared code (`GET /v1/threads/ID/outputs`, advertised by `supportsThreadOutputs` in `/v1/status`) and returns corpus-relative paths. The sheet lists the working folder, outputs grouped with their published formats, stale formats, and everything else the thread touched. Text files open in the corpus reader, synced copy first with host fallback; synced PDFs and other binary formats open in Quick Look; the jump control pages the transcript to the reply that last touched the file. Older hosts are not queried.

Long conversations render a bounded page of messages on the phone. Earlier/newer controls navigate the complete history without growing the view indefinitely. Chat text renders Org headings, emphasis, links, source and quote blocks, lists, and horizontally scrollable tables with header styling. Large messages, streaming replies, and reasoning show a bounded preview with **Read full message** opening a selectable, scrolling text reader. Copy preserves the complete message.

The paired Mac also owns the phone's canonical Agenda and Approvals views. Pulling to refresh asks the Mac to rebuild each projection through the shared CLI. TODO transitions and approval decisions are applied on the Mac before the refreshed result is returned; the phone no longer hides a pending approval while merely queuing an inbox instruction. Run-backed approvals support approve, reject, and request-changes boundaries. Workflow controls are intentionally omitted from the mobile navigation for now. If the paired Mac is sleeping, unreachable, or too old to expose these endpoints, the app keeps its last canonical snapshot and labels the connection problem instead of substituting independently parsed state.

The AI sidebar's **Settings → Reply Notifications** option registers the paired phone for Apple Push Notification service (APNs). When the Mac receives a new assistant reply, it sends a quiet banner immediately through APNs; tapping it opens the matching thread. Reply alerts are not stored by APNs when the phone is unavailable, so a stale response cannot appear hours later as a replay. While the app is foregrounded it refreshes the paired host's thread list every few seconds whether or not reply notifications are enabled; best-effort iOS background refresh remains a notification fallback that alerts only while real-time push is unavailable. The phone remembers the recent replies it has seen in each thread, so a reply alerts at most once even when the Mac temporarily reports an idle thread without its transcript and later reports the same reply again. The host reconciles newly synced immutable chat commits before answering the phone, including divergent Syncthing branches. **Send Test Notification** exercises the real Mac-to-APNs-to-phone path instead of showing a local test banner. The Mac must be awake with Celorga running to originate a push, but the phone does not need the Celorga app open or Tailscale active when APNs delivers it.

1. Install and sign into Tailscale on the Mac and iPhone with access to the same tailnet.
2. In Celorga on the Mac, open **Settings → Mobile Remote**.
3. Turn on Mobile Remote, select the detected `100.x.y.z` Tailscale address, and create a one-time pairing code.
4. In Celorga, open the AI sidebar, choose **Settings → Connect a Mac**, and scan the QR code. Manual URL and code entry is also available.
5. For real-time reply notifications, add the Apple Developer Team ID and APNs key ID under **Settings → Mobile Remote → Real-time Reply Notifications**, then import the downloaded `.p8` APNs authentication key. Celorga stores the private key only in the Mac Keychain; it is never written into the corpus or sent to the phone.

The Mac listener binds only to its Tailscale IPv4 address on port `48922`; it is not exposed on Wi-Fi or the public internet. Tailscale encrypts the transport. Pairing issues a per-device bearer credential, stored in Keychain on both devices, which can be revoked from Mac settings. Pairing codes expire after ten minutes and work once. The Mac must be awake, Celorga must be running, and the selected AI runtime must already be configured there.

Photo attachments and remote model selection require Mobile Remote protocol v2. Update both the Mac and iOS apps together; the apps reject a mismatched protocol instead of silently dropping attachments.

Notification taps are retained until the root navigator accepts them, including cold launches and background resumes. Reply taps open the conversation without waiting for the host's thread list; if pairing is needed, Settings opens and the tap is retained until pairing completes. Due-today taps open Agenda, including notifications scheduled by earlier app versions. Dismissed notifications never navigate. The latest tap wins, and an accepted tap does not replay on the next activation.

The app and share extension use the `group.org.org2.mobile` app group so the extension can reuse the selected corpus bookmark. Enable that App Group for both targets in the Apple developer portal before device signing.

## Audio approvals

Walkie-talkie approvals read agents' run approvals to you on a headset and take a spoken reply. They are off by default. Turn them on in **Settings → Audio approvals**, then tap **Join approvals channel** while the app is in the foreground; iOS requires that explicit join. The paired Mac stays the only decision authority: the phone decides nothing on its own and sends every decision through the Mac's approval queue.

- **Prompts.** When a run waits on an approval, the Mac sends an Apple Push to Talk notification carrying only the exact run, approval, and fingerprint. The phone checks that identity against the Mac before anything plays. A push that is no longer pending is ignored. The prompt names the requesting agent and the action. The Mac pushes each pending approval once per phone, approvals requested with `--priority urgent` first and then oldest first. It leaves 30 seconds after a push before sending the next one. A prompt that was heard but left unanswered stays pending in **Approvals** but no longer blocks newer prompts. The Mac rereads canonical run approvals before choosing a prompt, after every decision, and every minute while a phone is enrolled.
- **Headset only.** Speech plays only while iOS has activated the Push to Talk audio session and every output is a headset (wired, Bluetooth, or USB). It never plays on the speaker or receiver. A call, other media, quiet mode, or a missing headset holds the prompt on the Mac. Disconnecting the headset stops the prompt or reply immediately; nothing moves to the speaker and nothing is decided.
- **Replies.** Press the system Push to Talk button or the headset button, then say *yes*, *no*, *why*, *read it to me*, or *later*. You do not have to wait for a long prompt to finish: pressing Talk while it is being read stops the readout and answers that prompt (the approvals channel is full duplex so iOS keeps Talk available). Only whole, unambiguous phrases count, and only for a prompt you heard in full or interrupted within the last two minutes. Transmissions the app did not receive from you and partial or mixed speech decide nothing. A new prompt never interrupts an answer in progress: it waits while a prompt plays, while you reply, while a decision is being sent, and for 20 seconds after a prompt finishes, then replaces a prompt you left unanswered. Every press ends with a spoken and on-screen result after you release the button: the decision and how the agent continues, "Not applied", "Nothing to answer", an expired prompt, a reply that was not captured or understood, or an interruption. *Why* and *read it to me* add detail; *later* snoozes that one prompt for 30 minutes on the Mac.
- **Receipts.** The decision carries the exact identity and a receipt key that is recorded on the approval. The Mac refuses a changed or already-decided approval and answers a replay of the same receipt with the original result. The phone then speaks the Mac's receipt, for example "Approved. The agent is continuing." or "Approved, but the agent could not be resumed. The run is blocked; check the Mac."
- **Quiet and snooze.** **Quiet or snooze** holds prompts for 30 minutes, 1 hour, 4 hours, or until you resume. The setting is also sent to the Mac, which stops sending pushes until it ends.

Device setup: the app declares the `com.apple.developer.push-to-talk` entitlement and both the `push-to-talk` and `audio` background modes. Push to Talk pushes can arrive without `audio`, but the audio session cannot activate in the background. Device signing needs a provisioning profile with the Push to Talk and Push Notifications capabilities. The Mac sends pushes with the same APNs key as reply notifications (topic `org.org2.mobile.voip-ptt`).

Checks without a phone (`npm run test:audio-approvals`): the iOS policy compiled and run on macOS, the TypeScript broker, the cross-layer contract, and a Mac end-to-end test. That test pairs a phone over the Mobile Remote API, registers a Push to Talk token, and decides a demo approval (no external action) in a temporary corpus through the real CLI, including a wrong-fingerprint refusal, a duplicate replay, the next agent's push, snooze, and quiet. In a Debug build, **Simulator demo** under Audio approvals runs the same state machine against a real paired Mac with a simulated headset; prompts appear as text and the typed reply goes through the exact-identity decision path. Push to Talk delivery, AirPods routing, lock-screen behavior, and headset-button replies still need a physical iPhone.

The phone end-to-end run (`npm run test:audio-approvals:e2e`) drives the shipped controller against a host with file-based credentials, as a headless Celorga server uses, and covers a reply that interrupts a long readout. A physical pass covers what simulation cannot. For each host the phone is paired with (a Celorga server and the Celorga Mac app), check:

1. App in the foreground, then backgrounded, then the phone locked: a fresh approval plays on the headset.
2. A podcast playing: the prompt interrupts it and the podcast can resume.
3. Talk during a long readout: speech stops, *no* rejects that approval, and the Mac shows the rejection.
4. Talk after the prompt finishes: *yes* approves, and the spoken receipt names how the agent continues.
5. No headset connected: nothing plays and the approval stays pending.

The host's `GET /v1/audio-approvals/diagnostics` lists each delivery's stages (`push-received`, `playback-started`, `decision-confirmed`), which shows where a failed check stopped.

## Headless host pairing

Mobile Remote also connects to `celorga server` on a dedicated Mac. Settings → Host Connection saves a separate Keychain credential for each host and selects one host at a time. Existing Mac pairings migrate automatically. Hosts serve the chat history persisted in their configured corpus; selecting another host does not copy history or agent runtime sessions. Simultaneous desktop/server chat editing against synced corpus copies is not coordinated. See [headless server setup](../../../docs/site/headless-server.org).

## Local document runtime

Run `npm run build:mobile-document` after shared parser/renderer changes and before an iOS build. The checked-in JavaScriptCore resource is verified by `npm run check:mobile-document` and `node test/test-ios-mobile-navigation.mjs`. The bridge supplies file and corpus TODO definitions explicitly and provides no filesystem APIs to JavaScript.

The Files view warms one background document renderer unless Low Power Mode is active. Note opens reuse that engine and at most one rendered result, with a 2 MiB source/HTML budget. The cache key includes the full source, selected entry, path, corpus, and TODO definitions; source reads still happen on each open. The engine and result are released after 60 seconds idle, on memory pressure, and when the app enters the background. Corpus-cache encoding and atomic writes run on a separate actor, with generation ordering to prevent a delayed save from replacing a newer snapshot. Reopening Files reuses an already loaded snapshot rather than rehydrating the disk cache.

`node test/test-ios-transcript.mjs` exercises renderer reuse, source/workflow invalidation, cancellation, resource release, ordered cache persistence, and long-prose performance through the actual JavaScriptCore bridge.

Chat renders labeled and bare Org entry links as tappable links. Stable `id:` links resolve within the selected synced corpus; `file:note.org::*Heading`, `::#CUSTOM_ID`, and `::42` select the entry from freshly read source. Missing or ambiguous entries show an error instead of opening the wrong section. Entry views include Open full note and Source. Internal links in rendered notes use the same reader and resolve file paths relative to the source note; external web links remain external.

Spoken replies are visible directly in **Approvals → Reply and decision history** and in
Settings → Audio approvals. The phone keeps the latest 50 reply attempts, scoped to the
paired Mac, including recognized words, interpretation, and the host-confirmed result or
failure. Incomplete prompts cannot authorize a reply; that failure is visible too. The
history survives app relaunch and turning audio approvals off. Raw microphone audio is
not retained. Canonical decisions supplied by an updated host show their actor and reason,
so cancellations by an agent are not presented as the user's spoken decisions. Older hosts
remain compatible but do not return the canonical decision-history section.

Speech is synthesized into PCM buffers and played through an AVAudioEngine in the
system-owned Push to Talk session. Receive mode ends only after the final audio buffer
has played. Canceled playback callbacks cannot finish a newer prompt. Bluetooth uses HFP
for both listening and replying; the app never activates or deactivates a PTT session.
