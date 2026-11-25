# Celorga meetings

The Celorga app records meetings as local corpus artifacts. The macOS app owns capture, local transcription, and durable file placement. OpenClaw or another agent owns later interpretation, summarization policy, and promotion into project/entity/task notes.

## Storage layout

By default the app writes under the selected corpus:

```text
meetings/
  2026-06-11-140000-scarf-reporting-sync.wav
  2026-06-11-140000-scarf-reporting-sync.org
  2026-06-11-140000-scarf-reporting-sync.transcript.org
```

Native recordings are mono 16 kHz WAV files so local providers can transcribe them directly. Imported audio keeps its original extension. The audio file stays inside the user-selected corpus. Celorga never sends meeting audio to a non-loopback endpoint.

## Meeting object

Each meeting note is a Celorga node with `:kind: meeting` and links to its audio and transcript artifacts:

```org
#+TITLE: Meeting: Scarf reporting sync
#+CELORGA_KIND: meeting

* Meeting: Scarf reporting sync
:PROPERTIES:
:ID: 8f7b3eb0-8f3f-4a4c-9e18-958c69f88201
:kind: meeting
:recorded_at: 2026-06-11T21:00:00.000Z
:duration_seconds: 1800.0
:audio_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.wav
:transcript_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.transcript.org
:transcription_engine: whisper.cpp
:transcription_status: complete
:END:

** Summary
- Not summarized yet.

** Decisions
- [ ] Review transcript and extract decisions.

** TODOs
- [ ] Review this meeting transcript.

** Transcript
[[file:meetings/2026-06-11-140000-scarf-reporting-sync.transcript.org][Open transcript artifact]]
```

The summary, decisions, and TODO sections are intentionally review placeholders in the first slice. Agents can use the transcript artifact to fill or promote them later.

## Transcript artifact

The transcript artifact is also an Org document so it is searchable and easy for agents to cite:

```org
#+TITLE: Transcript: Scarf reporting sync
#+CELORGA_KIND: meeting-transcript

* Transcript: Scarf reporting sync
:PROPERTIES:
:ID: 3be13af1-3509-4d48-b5a5-9960c726321d
:kind: meeting_transcript
:meeting_id: 8f7b3eb0-8f3f-4a4c-9e18-958c69f88201
:recorded_at: 2026-06-11T21:00:00.000Z
:audio_artifact: meetings/2026-06-11-140000-scarf-reporting-sync.wav
:transcription_engine: whisper.cpp
:transcription_status: complete
:END:

Transcript text...
```

## Local transcription

Transcription works without external setup. Release builds include a native
whisper.cpp v1.9.2 executable and the English `base.en` GGML model for the Mac's
architecture. The packaged executable and all of its non-system dynamic
libraries are signed and launch-tested while the app bundle is assembled.

The Mac app's **Settings → Meetings** tab selects and tests one of these providers:

1. **Automatic** uses local Whisper when it can actually launch, then macOS Speech. A fallback is recorded in `:transcription_error:` instead of being silently hidden.
2. **Local Whisper** uses the bundled or installed `whisper.cpp` runtime and does not change providers on failure. The model path and language can be overridden in the UI.
3. **Fluid Voice** calls its loopback-only Local API and uses the speech model selected in Fluid Voice. Selecting it makes Celorga detect the installed app, enable and briefly relaunch its Local API when needed, and verify `/v1/health`; an already healthy connection is left running. Celorga splits recordings into overlapping chunks below Fluid Voice's five-minute request ceiling.
4. **macOS Speech** uses Apple's built-in Speech recognizer directly.
5. **Custom Command** substitutes `{audio}` with the quoted local audio path, or appends the path, and reads transcript text from standard output.

The provider, endpoint, model path, language, and custom command are stored in
the Mac app's local preferences rather than the corpus. The Fluid Voice endpoint
is an advanced setting for installations using a non-default local port and is
restricted to `localhost`, `127.0.0.1`, or `::1`; long-audio chunks remain temporary
local files and are removed after transcription.

For headless launches, Automatic and Local Whisper also recognize environment
configuration:

1. `CELORGA_WORKSPACE_WHISPER_COMMAND`, a custom local command. If it contains `{audio}`, the app substitutes the quoted audio path; otherwise it appends the audio path.
2. The bundled `whisper-cli` and bundled `ggml-base.en.bin` model.
3. `whisper-cli` or `whisper-cpp` from another local installation, with `CELORGA_WORKSPACE_WHISPER_MODEL` or a common local model path.
4. `whisper`, the OpenAI Whisper CLI, with `CELORGA_WORKSPACE_WHISPER_MODEL` when set.
5. The built-in macOS Speech framework as an emergency fallback.

Homebrew, a separate model download, environment variables, and Speech Recognition permission are not required for normal Automatic transcription. If every configured local path is unavailable, the app still writes the audio, meeting note, and transcript artifact with the provider, `:transcription_status: failed` or `unavailable`, and the local error. That preserves provenance without silently uploading private audio itself.

## OpenClaw ingestion

Meetings live in normal corpus files under `meetings/`. The selected meeting note can be passed to OpenClaw Chat as workspace context, and OpenClaw can be configured separately to search, ingest, summarize, extract actions, or attach meeting outputs to daily notes, projects, entities, and agent threads.
