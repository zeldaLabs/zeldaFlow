# Architecture decision records

Why zeldaFlow — zeldaLabs' local-first voice dictation and voice-command app for
macOS — is built the way it is. Each record captures one decision: the
constraints at the time, the option chosen, what was rejected, and the
consequences (the bad ones too).

Records 1–17 were mined from the commit history and in-code rationale
comments. Records 18–21 were made on 2026-07-28 while fixing a verified
multi-monitor failure (stranded pill panel, wrong-screen feedback,
cooperative-pool starvation, event-tap stalls, GPU contention). Records
27 and 29–30 were made on 2026-08-08 for the meeting notetaker.

An iPhone keyboard was prototyped and kept on a private `ios` branch that
is **not part of this repository** — zeldaFlow is macOS-only, and that
branch was never published. It carried its own copy of this index and
numbered its records independently, which is why record 27 here is
"Automatic meeting capture" and not the iOS record of the same number in
older internal references. Within this repository the numbering is simply
1–36, no branch qualifier needed.

| # | Title | Status | Summary |
|---|-------|--------|---------|
| 1 | [Fully local STT with whisper.cpp](0001-fully-local-stt-with-whisper-cpp.md) | Accepted | In-process whisper.cpp large-v3-turbo on Metal, greedy decoding for bounded latency, never cloud. |
| 2 | [Local LLM via llama-server running Gemma](0002-local-llm-via-llama-server-gemma.md) | Accepted | A supervised llama-server child serves Gemma 4 E2B for cleanup and command parsing; cleanup never blocks dictation. |
| 3 | [Fn key hotkey via suppressing CGEventTap](0003-fn-key-hotkey-via-suppressing-event-tap.md) | Accepted | One suppressing event tap multiplexes hold, double-tap, triple-tap, and bare-tap on the Fn key, with a self-healing watchdog. |
| 4 | [Pill HUD as a non-activating NSPanel](0004-pill-hud-as-non-activating-panel.md) | Accepted | A borderless, non-activating panel shows feedback everywhere without stealing focus from the paste target. |
| 5 | [Clipboard save/restore + synthetic Cmd-V insertion](0005-clipboard-paste-text-insertion.md) | Accepted | Paste, not keystroke synthesis — works in native apps, Electron, and terminals alike; clipboard restored after. |
| 6 | [Deterministic fast path before the LLM](0006-deterministic-fast-path-before-llm.md) | Accepted | A hand-written parser handles common commands from the user's exact words; the LLM is only the fallback. |
| 7 | [LLM fills JSON actions, never code](0007-llm-fills-json-actions-never-code.md) | Accepted | The model fills typed parameters into hand-written AppleScript templates; no shell, and outbound comms need an Fn-tap. |
| 8 | [Anti-hallucination: VAD + layered scrubber](0008-anti-hallucination-vad-and-filter.md) | Accepted | Silero VAD plus an asymmetric text filter — aggressive on the preview, conservative on the final transcript. |
| 9 | [Stable self-signed "zeldaFlow Dev" certificate](0009-stable-self-signed-dev-certificate.md) | Accepted | A stable signing identity so TCC permission grants survive rebuilds without a paid Developer ID. |
| 10 | [Direct swiftc build script, no Xcode project](0010-swiftc-build-script-not-swift-build.md) | Accepted | `swift build` is broken on the beta CLT; one scripted swiftc call builds, bundles, and signs the app. |
| 11 | [Always-on pill with click-to-type command bar](0011-always-on-pill-with-type-bar.md) | Accepted | The idle nub stays on screen and opens a Spotlight-style type bar that takes key without activating zeldaFlow. |
| 12 | [Speak-to-Edit via clipboard round-trip](0012-speak-to-edit-clipboard-roundtrip.md) | Accepted | Copy the selection with Cmd-C, rewrite it with the local LLM, paste the result back over it — in any app. |
| 13 | [Screen context via the AX tree, not OCR](0013-screen-context-via-ax-not-ocr.md) | Accepted | Bias Whisper with terms read from the focused window's accessibility tree; session-scoped, discarded after. |
| 14 | [Learned words: auto-suggest, human-approve](0014-learned-words-human-approved.md) | Accepted | Recurring distinctive words become suggestions in the Hub; a human approves every dictionary entry, and the pill is never interrupted. |
| 15 | [Cinematic onboarding, no personal seed data](0015-cinematic-onboarding-clean-seed.md) | Accepted | An animated first run asks the user's name; every install starts with a clean dictionary and learns its own user. |
| 16 | [Apple Maps navigation via maps:// URL](0016-apple-maps-url-scheme-navigation.md) | Accepted | One deep link computes the route and opens turn-by-turn directions — no UI scripting of Maps. |
| 17 | [Bounded network exceptions to "fully local"](0017-bounded-network-exceptions.md) | Accepted | Anonymous iTunes catalog lookup, and an opt-out Claude agent mode gated by a mandatory Fn-tap per task. |
| 18 | [Re-anchor windows on display changes; sticky pill](0018-reanchor-windows-on-display-changes.md) | Accepted | The pill remembers its display and moves only at recording start (to the frontmost window's screen, via the window server, never AX) or when its display disappears; everything re-anchors in place on screen-configuration changes. |
| 19 | [Bounded, single-flight AX harvests](0019-bounded-single-flight-ax-harvests.md) | Accepted | A 0.25 s per-element AX messaging cap, a 0.4 s harvest budget, and a dedicated serial queue so AX can never starve the cooperative pool. |
| 20 | [Fully async text insertion](0020-fully-async-text-insertion.md) | Accepted | Suspending sleeps instead of Thread.sleep — the Fn event tap shares the main run loop, and macOS disables unserviced taps. |
| 21 | [Optional Core ML ANE encoder](0021-optional-coreml-ane-encoder.md) | Accepted | setup.sh downloads the Neural Engine encoder so whisper leaves the GPU that composites external displays; Metal stays the default. |
| 22 | [Prompt echo filtered from the final transcript](0022-prompt-echo-filtered-from-final-transcript.md) | Accepted | Under heavy background speech the decoder recited its own prompt, which would paste the user's dictionary and name into their document; `scrubFinal` now recognizes self-recitation without dropping genuine dictation. |
| 23 | [App control through app-declared UI](0023-app-control-through-app-declared-ui.md) | Accepted | Any app is driven through the menu commands and window controls it declares via Accessibility — deterministic match first, LLM chooses only from what exists, gates key off labels, nothing ever clicks a coordinate. |
| 24 | [Task loop: constrained selection](0024-task-loop-constrained-selection.md) | Accepted | Multi-step tasks run as observe→act with the local model reduced to picking an index from a pruned, pre-validated option list; completion and termination are decided in code, because the model measurably cannot. |
| 25 | [Pill height independent of the Dock](0025-pill-height-independent-of-dock.md) | Accepted | The pill rests at the same visual height on every display — clearing the Dock where it is, holding a matching constant where it isn't — instead of hugging the glass on Dock-less monitors. |
| 26 | [Seamless audio: no BT mic, no duck](0026-seamless-audio-no-bt-mic-no-duck.md) | Accepted | Dictation never opens a Bluetooth microphone and skips voice processing entirely on Bluetooth headphones, so starting to speak no longer pauses, ducks, or delays whatever is playing. |
| 27 | [Automatic meeting capture](0027-automatic-meeting-capture.md) | Accepted | Detection starts recording with no prompt; consent is enforced by visibility (always-on chip, banner, menu icon, one-click discard). Only a known meeting app *holding* the mic triggers; stops on 30 s mic-idle, app-quit, sleep, or the 4 h cap. |
| 28 | [Hotkey tap on its own thread, non-blocking callback](0028-hotkey-tap-on-its-own-thread.md) | Accepted | The press used to run an 845 ms cold CoreAudio start inside the event-tap callback on the main run loop, stalling every key on the machine and dropping the second press; the tap now has its own thread and answers in microseconds. |
| 29 | [Dual-channel transcription + text dedup](0029-dual-channel-transcription-text-dedup.md) | Accepted | The mic and system-tap channels ARE the speaker labels ("You"/"Them"); a 5 s chunk scheduler shares the single Whisper context and yields to dictation; residual echo is dropped only on a text match — audio evidence may only delay. |
| 30 | [Local map-reduce notes in the 4k context](0030-local-map-reduce-notes-4k-context.md) | Accepted | 45–60 k-char transcripts vs a measured ~4,500-char budget: grammar-constrained JSON maps, deterministic merge and renderer — the model never controls the format; failure is a visible state with the transcript intact, never partial notes. |
| 31 | [Post-meeting speaker diarization](0031-post-meeting-speaker-diarization.md) | Accepted | Vendored FluidAudio (pyannote community-1 on the ANE) diarizes `system.wav` after stop; "You" is untouchable ground truth, unattributable stays "Them", one cluster = no labels, and the notes-staleness hash provably never flips. |
| 32 | [Editable meeting notes](0032-editable-meeting-notes.md) | Accepted | Raw-markdown edit mode with ~800 ms debounced autosave and a deinit flush (navigation destroys the view with no willDisappear); `notesEditedAt` makes Regenerate warn before clobbering hand-edited notes. |
| 33 | [WhatsApp call capture](0033-whatsapp-call-capture.md) | Accepted | Opt-in (default OFF) behind a generalized personal-call gate; a call is mic input AND audio output on `net.whatsapp.WhatsApp` sustained ~10–15 s, so voice notes are structurally incapable of triggering; tier-2 never trusts WhatsApp. |
| 34 | [Utterance chunking, not fixed windows](0034-utterance-chunking-not-fixed-windows.md) | Accepted | The first real call came back half-transcribed with mangled boundary words and the decode prompt recited as speech; meeting audio is now cut inside pauses (8-24 s utterances), the far side is decoded with no prompt at all, and every drop-gate measures the loudest second instead of the whole-chunk average. |
| 35 | [Meeting feedback is captured, not trained on](0035-meeting-feedback-is-captured-not-trained-on.md) | Accepted | Thumbs up/down on the transcript and the notes, asked once on open and changeable from the toolbar; the audio is deleted and a thumb is one bit, so nothing retrains — the ratings are a regression corpus, and the app says so instead of implying otherwise. |
| 36 | [Answers become a clickable pill that expands into a chat note](0036-answer-pill-expands-into-chat-note.md) | Accepted | Screen analyses and instant answers now land as a clickable `.answer` pill that grows into a 640×460 chat note (`.chat`) with a composer; follow-ups render the thread to the Claude CLI with no tools, fall back to Gemma, and never silently re-capture the screen — the first answer's text is the record. |

## Format

Each record follows the same shape: **Status**, **Date**, **Context**,
**Decision**, **Alternatives considered**, and **Consequences** — good and
bad. New records take the next number, named `NNNN-kebab-title.md`.
