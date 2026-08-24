# Changelog

All notable changes to zeldaFlow are recorded here. The *why* behind each
load-bearing decision lives in [`docs/adr/`](docs/adr/).

This project follows [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-08-24

First public release. zeldaFlow was built and used privately before this;
1.0.0 is the point it became something other people can build on, not the
point the code started.

### Dictation

- Hold **Fn** to dictate, double-tap for hands-free, triple-tap for command
  mode. Text lands at your cursor in any app.
- whisper.cpp large-v3-turbo in-process on Metal, with an optional Core ML
  Neural Engine encoder. A 3 s clip transcribes in ~0.9–1.0 s on an M4 Pro,
  a 48 s clip in ~1.5 s.
- Silero VAD pre-filter plus a prompt-echo scrubber, so silence doesn't
  become phantom text (ADR 8, ADR 22).
- Optional local Gemma cleanup: fillers removed, self-corrections applied,
  punctuation added (ADR 2).
- Clipboard-based insertion that saves and restores what was there (ADR 5).
- Learned-words dictionary, human-approved (ADR 14). On-screen context
  biasing via the accessibility tree, not OCR (ADR 13).

### Voice commands

- Deterministic fast path before the model, so exact-word commands can never
  be substituted (ADR 6). The model fills a JSON schema and never writes
  code (ADR 7).
- App control through each app's own declared menus and controls (ADR 23),
  file and folder actions confined to your home directory, multi-step task
  loops with bounded selection (ADR 24), Apple Maps navigation, music.
- Confirmation gates on anything that leaves this Mac. `agent_task` is gated
  unconditionally, with no setting to turn it off.

### Meeting notes

- Automatic capture when a meeting app takes the mic — Zoom, Teams, Webex,
  and the Meet/Zoom/Teams/Webex web clients in seven browsers. No prompt;
  consent is by visible recording chip instead (ADR 27).
- FaceTime and WhatsApp are opt-in and off by default. WhatsApp additionally
  requires sustained mic *and* output on the same process, so a voice note
  doesn't read as a call (ADR 33).
- Dual-channel transcription: the channels are the speaker labels, and echo
  is judged on text rather than waveform (ADR 29). Utterance chunking aligned
  to pauses rather than blind 5 s cuts (ADR 34).
- Post-meeting speaker diarization of the far side on the Neural Engine —
  an hour in ~30–60 s, renameable speakers (ADR 31).
- Notes by local map-reduce inside Gemma's 4,096-token context, schema-
  constrained (ADR 30). Editable as raw markdown with debounced autosave
  (ADR 32). Export as Markdown, txt, SRT, or JSON.
- **Meeting audio is deleted once the transcript is finalized.**

### Agent mode

- Optional bridge to the Claude Code CLI for screen questions and background
  tasks — the single deliberate exception to fully-local, opt-out, and gated
  behind an explicit keypress every time (ADR 17).

### Interface

- Non-activating pill HUD, centred and stable across displays, Spaces, and
  display reconfiguration (ADR 4, ADR 18, ADR 25).
- Answer pill expands into a chat note (ADR 36).
- Menu-bar app with history, settings, and a meetings page.

### Verification

- Twelve headless harnesses covering command grammar, hotkey latency,
  meetings, pill geometry, audio topology, files, UI control, and live
  actions — see [docs/TESTING.md](docs/TESTING.md).
- 36 architecture decision records, including one that exists purely to
  record an experiment that failed.

### Known limitations

- Apple Silicon and macOS 15+ only.
- Builds are self-signed from source; there is no notarized distribution yet.
- Meeting detection depends on bundle IDs and window-title fragments, so an
  upstream rename can silently stop capture.
- Diarization separates speakers; it never identifies them.
- Note feedback is captured, not trained on — the audio is deleted and a
  thumb carries one bit (ADR 35).

[1.0.0]: https://github.com/zeldaLabs/zeldaFlow/releases/tag/v1.0.0
