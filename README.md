<img src="Resources/brand/zeldaflow_logo_on_white.png" alt="zeldaFlow" width="340">

# zeldaFlow — zeldaLabs

Hold **Fn**, speak, release — accurate text appears at your cursor, in any
app. A fully local, native-Swift alternative to Wispr Flow: no cloud, no
account, no subscription. Your voice never leaves your Mac.

That sentence is the design constraint, not a tagline. Dictation never
touches the network. Command mode has exactly two deliberate exceptions,
both documented below: the optional Claude agent bridge (opt-out, gated
behind an explicit keypress every time), and an anonymous Apple Music
catalog lookup when a requested song isn't in your local library.

## How it works

```
Fn key (CGEventTap) ─▶ mic capture (AVAudioEngine, 16 kHz)
                          │ release Fn
                          ▼
              whisper.cpp large-v3-turbo (Metal, in-process, ~1 GB resident)
                          │ + Silero VAD pre-filter (kills silence hallucinations)
                          ▼
              Gemma 4 E2B via llama-server (optional AI cleanup, ~0.4 s)
                fillers removed · "no wait, Wednesday" → "Wednesday" · punctuation
                          ▼
              clipboard + synthetic ⌘V (previous clipboard restored)
```

Measured on an M4 Pro: a 3 s command transcribes in ~0.9–1.0 s, a 20 s
dictation in ~1.1 s, a 48 s clip in ~1.5 s; cleanup adds ~0.2–0.7 s. Full
numbers and methodology: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Install

```bash
git clone https://github.com/zeldaLabs/zeldaFlow.git && cd zeldaFlow
scripts/install.sh   # first run also fetches models (~4.9 GB) + llama.cpp
```

Requirements: an Apple Silicon Mac, macOS 15+, ~5 GB disk for models.
Homebrew is needed only for the optional AI cleanup / voice-command model
(`llama.cpp`); dictation itself has zero dependencies beyond the repo.

First launch walks you through **Microphone** and **Accessibility**
permissions (Accessibility powers the Fn-key tap and the synthetic ⌘V).
Models live in `~/Library/Application Support/zeldaFlow/models/`; history and
logs live next to them. Model and framework licenses are listed in
[Vendor/README.md](Vendor/README.md); every model the setup script downloads
is MIT, Apache-2.0, or CC-BY-4.0.

## Controls

| Gesture | Action |
|---|---|
| **Hold Fn** | Push-to-talk: record while held, insert on release |
| **Double-tap Fn** | Hands-free mode: tap Fn again to stop and insert |
| **Triple-tap Fn** | Command mode: speak a command, tap Fn to run it |
| **Esc** (while recording) | Cancel, discard audio |
| Fn+arrow / Fn+delete | Passed through untouched (dictation cancels itself) |

Text pastes wherever your cursor is **when you stop** — so in hands-free you
can dictate, click into the target field, then tap Fn. The floating pill
shows a live preview of your words while you speak. Dictation language is
selectable (menu bar → Language): auto-detect transcribes each utterance in
the language you spoke, in its own script, never translated.

### Command mode (triple-tap, purple ✨ in the pill)

Speak a command instead of dictation; a deterministic parser handles common
phrasings from your exact words, and local Gemma interprets the rest into
**structured actions**, executed natively (the LLM fills parameters into
hand-written AppleScript templates — it never writes code, and there is no
shell path). One command can chain several actions in order.

| Say | What happens |
|---|---|
| "Open Spotify" · "switch to Chrome" | Launches / switches app — resolved against what's installed on *this* Mac; known services fall back to their web app |
| "Search for M4 Pro reviews" · "open github.com" | Opens the URL |
| "Write a PRD outline for a food delivery app" | Generates full content, types it at your cursor |
| "Play Blinding Lights by The Weeknd" · "play my gym playlist" · "play some jazz on Spotify" | Your music app — Apple Music or Spotify, whichever this Mac uses (or the one you name) |
| "Pause" · "next track" · "set volume to 30%" · "mute" | Playback (whichever player is playing) & system volume |
| "Remind me to call mom tomorrow at 5pm" | Reminders, with resolved dates |
| "Add a calendar event team sync Monday 10am for 30 min" | Calendar |
| "Make a note titled ideas: …" | Notes |
| "Email John saying I'll be late" | Mail — recipient resolved via Contacts |
| "Text Sarah I'm on my way" | iMessage — recipient resolved via Contacts |
| "Navigate to the airport" | Apple Maps directions from where you are |
| "Open Notes and play some jazz" | Runs both, in order |
| "What's on my screen?" · "explain this error" | 👁 Screenshot → Claude vision → answer in the pill |
| "Check my GitHub notifications" · "clean up my Downloads folder" | 🤖 Background agent (Claude Code CLI), Fn-confirmed |
| "Ask Claude to write a haiku about Fridays" | Opens the Claude desktop app, types the prompt and sends it |
| "Stop the agent" | Cancels the running background task |

**Sending is gated.** Before any email or message goes out, the pill shows
the recipient and waits — **tap Fn to send, Esc to cancel** (toggle in
Settings → Voice commands). Unresolvable email recipients open a visible
draft instead of sending blind. Humans sit at the approval gates, not in the
loop — that's the whole zeldaLabs thesis, running on a Mac.

**Music app:** automatic — whichever player this Mac is actually using
(Spotify when installed and active, Apple Music otherwise), naming one in
the command always wins, and there's a pin in Settings → Voice commands.

**Permissions:** the first time zeldaFlow controls Music / Mail / Messages /
Reminders / Calendar / Contacts, macOS shows a one-time "zeldaFlow wants to
control …" prompt — click OK (or manage later under Privacy & Security →
Automation). Command mode starts the Gemma server on demand even if AI
cleanup is off.

Command quality is Gemma 4 E2B — great for structured actions and
short/medium content; longer documents type in a few seconds (~100 tok/s).

### Agent mode — the one non-local capability (opt-out in menu → Agent)

Screen analysis and background tasks run through the **Claude Code CLI** if
it's on your Mac (`claude -p`, headless). This is the single deliberate
exception to "fully local", used only when you explicitly ask for work the
local models can't do:

- **"What's on my screen?"** — zeldaFlow takes a screenshot (Screen Recording
  permission, asked on first use + relaunch), Claude answers in the pill;
  the full answer is available via *Paste Last Transcript*. The screenshot
  is deleted immediately after.
- **Background tasks** — "check my GitHub PRs", "organize my Downloads".
  The agent gets terminal access, so every task **requires a Fn-tap
  confirmation** before it starts — always, with no setting to turn that
  off. It runs detached: keep dictating, the pill pings when it's done; the
  menu bar shows progress and offers *Cancel Agent Task*. Full session log:
  `agent.log` next to `zeldaflow.log`.
- Model is selectable in the menu (Sonnet for speed, Opus for depth).
- No Claude CLI installed → the menu says so and everything else works.
  To enable it: install [Claude Code](https://claude.com/claude-code) and
  sign in once.

Dictation itself never touches the network, ever. The VAD-filtered live
preview plus a caption-junk scrubber kills the "phantom song credits while
dictating" class of Whisper hallucinations — including the decoder echoing
its own glossary prompt into the preview during pauses. If you dictate over
music from the Mac's own speakers, additionally try **Filter Background
Music** (menu → Agent, experimental echo cancellation; off by default
because Apple's voice-processing pipeline reshapes the mic input).

Menu bar (waveform icon): hands-free toggle, voice command, paste last
transcript, AI cleanup mode (Off / Light / Full), language, history &
settings, launch at login.

## Meeting notes (menu → Meetings)

When a meeting app takes the microphone, zeldaFlow starts recording. It does
not ask first — prompts get dismissed, and the meeting you most wanted notes
from is the one where you were too busy talking to click Record (ADR 27).
Consent is by visibility instead: the pill shows a recording chip the whole
time, with Stop and Discard one click away.

Detected automatically: **Zoom, Teams** (both bundle IDs), **Webex**, and the
**Meet / Zoom / Teams / Webex web clients** in Chrome, Safari, Arc, Edge,
Brave, Firefox, or Vivaldi. **FaceTime and WhatsApp are off by default** —
personal calls, opt-in per app in Settings. WhatsApp additionally requires
sustained mic *and* speaker activity on the same process, so a voice note
doesn't read as a call (ADR 33).

```
mic (you) ─────────┐
                   ├─▶ one Whisper context, dictation always wins the queue
system tap (them) ─┘        │
                            ▼
              dual-channel transcript, "You:" / "Them:"
              echo judged on text, not waveform (ADR 29)
                            │
                            ▼
              offline diarizer on the far side (ANE, 65–122× realtime)
              "Them" becomes Speaker 1/2/3, renameable (ADR 31)
                            │
                            ▼
              Gemma map-reduce → summary, decisions, action items (ADR 30)
```

The channels *are* the speaker labels, which is exact for who is local and
blind past it — so a post-meeting pass over the system channel splits the far
side into real speakers you can rename. An hour of meeting diarizes in
~30–60 s on the Neural Engine, with no contention against whisper.cpp (Metal)
or Gemma (GPU).

Notes are written by the same local Gemma behind `llama-server`. Its context
is 4,096 tokens and an hour of transcript is 45–60k characters — an order of
magnitude over budget — so notes are built by map-reduce over chunks rather
than one shot, with schema-constrained output because a 2B model given format
freedom invents labels (ADR 30). Generated notes are a starting point: the
detail view edits raw markdown with debounced autosave, and Regenerate is
always available (ADR 32).

| Setting | Default |
|---|---|
| Auto-record detected meetings | on |
| Write notes when a meeting ends | on |
| Polish the transcript with Gemma | on |
| Identify speakers | on |
| Also record FaceTime | **off** |
| Also record WhatsApp calls | **off** |
| Keep meetings for | forever (configurable in days) |

Export as Markdown, plain text, SRT, or JSON. Transcripts and notes live in
`~/Library/Application Support/zeldaFlow/meetings/`.

**The audio does not survive the meeting.** The mic and system WAVs are a
spool, not an archive — once the transcript is finalized they are deleted,
because they hold nothing the transcript doesn't except replayable audio of
other people. Nothing here touches the network at any point.

**Honest caveats.** Detection leans on bundle IDs and window-title fragments,
so a WhatsApp rewrite or a Google title change can silently stop capture —
that table is [one file](Sources/zeldaFlow/Meeting/MeetingApps.swift) precisely
so it's cheap to fix. Diarization is speaker *separation*, not identification:
it will tell you there were three voices, never who they were. And the thumbs
up/down on notes is captured, not trained on — the audio is deleted, a thumb
carries one bit, and pretending otherwise would be a lie about a local app
(ADR 35).

## Verify it yourself

```bash
say -o /tmp/t.aiff "Um, testing, uh, one two three."
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --selftest /tmp/t.aiff   # STT + cleanup + timings
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands           # command parser + gate pins
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalmeeting            # meeting detection, chunking, notes, diarizer
```

The selftest prints raw transcript, cleaned text, and per-stage timings
without touching the microphone or permissions. The evals pin the command
grammar and the confirmation gates — see [evals/commands.md](evals/commands.md).

## Signing & permissions

Run this **once, before your first build** and permissions will never bother
you again:

```bash
scripts/make-cert.sh   # creates a stable local signing identity
scripts/install.sh
```

Then grant Microphone and Accessibility when asked. That's it — the grants
survive every future rebuild.

<details>
<summary>Why this matters, and what goes wrong if you skip it</summary>

macOS ties permission grants to the app's **code signature**. Without a
certificate the build is *ad-hoc* signed, which produces a different
signature every single build — so after each rebuild macOS treats zeldaFlow
as a brand-new app and quietly stops honoring its Accessibility grant. The
Fn key does nothing, and the maddening part is that **System Settings still
shows zeldaFlow ticked**, because the stale entry is still listed.

If you hit that state, toggling the checkbox isn't enough — and there may be
several orphaned records stacked up, all invisible in the UI. Wipe them and
start clean:

```bash
tccutil reset Accessibility com.zeldalabs.zeldaflow
```

Then grant it once more when asked. (The manual equivalent: remove every
zeldaFlow row under Privacy & Security → Accessibility with **−**, then add
`/Applications/zeldaFlow.app` back with **+**.) No relaunch needed — the
running app picks the grant up within 5 seconds. zeldaFlow detects this
state and reports it in the menu bar and the pill rather than failing
silently.

`make-cert.sh` needs no Keychain Access trust step: `codesign` accepts a
self-signed identity even though the keychain reports it untrusted.
</details>

## Beta-toolchain notes (macOS 27 CLT, July 2026)

These apply to the beta Command Line Tools this was developed on; on a
stable toolchain `swift build` may simply work.

- `swift build` is broken on that beta: the CLT's PackageDescription
  swiftinterface and dylib disagree, so *any* `Package.swift` fails to
  compile. `scripts/build-app.sh` therefore invokes `swiftc` directly.
  `Package.swift` is kept for when Apple fixes the toolchain.
- SwiftUI's `@State` is a macro in this SDK but the CLT ships no
  SwiftUIMacros plugin; the UI uses small `@StateObject` models instead.

## Architecture

| Piece | File | Notes |
|---|---|---|
| Fn-key tap | `Sources/zeldaFlow/Hotkey/HotkeyMonitor.swift` | Suppressing session tap, keyCode 63 / `.maskSecondaryFn`; swallows the system globe action; self-healing watchdog |
| Audio | `Sources/zeldaFlow/Audio/AudioRecorder.swift` | AVAudioEngine tap → AVAudioConverter → 16 kHz mono Float32 + RMS levels |
| STT | `Sources/zeldaFlow/STT/WhisperEngine.swift` | whisper.cpp v1.9.1 XCFramework, greedy, no temperature fallback, VAD, dictionary via carried initial prompt |
| Anti-hallucination | `Sources/zeldaFlow/STT/HallucinationFilter.swift` | Energy gate + caption-junk scrubber + prompt-echo filter for preview & final text |
| Cleanup | `Sources/zeldaFlow/Cleanup/CleanupService.swift` | Supervised `llama-server` child (Homebrew llama.cpp), Gemma 4 E2B Q4_0, hard timeout → falls back to raw text |
| Insertion | `Sources/zeldaFlow/Insert/TextInserter.swift` | Clipboard save → transient write → ⌘V → restore; secure-input detection |
| Orchestration | `Sources/zeldaFlow/AppState.swift` | idle → recording → processing → success/notice state machine |
| Commands | `Sources/zeldaFlow/Command/*.swift` | Fast-path parser, LLM interpreter, per-device app + music-player resolution, AppleScript templates |
| Pill HUD | `Sources/zeldaFlow/UI/Pill*.swift` | Non-activating NSPanel, all Spaces, bottom-center waveform + live preview |
| Agent | `Sources/zeldaFlow/Agent/*.swift` | Claude Code CLI bridge (stream-json), screenshot capture, audit log |
| Meetings | `Sources/zeldaFlow/Meeting/*.swift` | Detection engine, Core Audio process tap, dual-channel transcription, map-reduce notes, offline diarizer, on-disk store |
| Meetings UI | `Sources/zeldaFlow/UI/Meeting*.swift` | Meetings list, detail view with editable markdown notes, transcript view, pill chip |

Every capability degrades honestly: no llama.cpp → raw transcripts still
insert; no Claude CLI → the Agent menu says so and stays disabled; unknown
app → the pill says so instead of guessing.

## Documentation

| Doc | What's in it |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | arc42/C4 architecture: goals, constraints, runtime views, cross-cutting concepts, measured quality numbers |
| [docs/adr/](docs/adr/) | 36 architecture decision records — why each load-bearing choice was made, alternatives and consequences included |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Measured latency and memory numbers, methodology, and how to reproduce them |
| [docs/TESTING.md](docs/TESTING.md) | All twelve built-in headless harnesses (`--selftest`, `--evalcommands`, `--evalmeeting`, `--evalpill`, …) and what is deliberately manual |
| [docs/UAT.md](docs/UAT.md) | ~20-minute manual release checklist for everything the harnesses can't reach |
| [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) | Every log file, what healthy sessions look like, and a table of failure signatures |
| [docs/EXTENDING.md](docs/EXTENDING.md) | Where this codebase can be cut, and where it can't yet — an honest map for anyone building on top of it |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setup, the build path, adding a voice command, and the two house rules |
| [SECURITY.md](SECURITY.md) | The privilege surface, the guarantees that are load-bearing, and how to report a vulnerability |

## Troubleshooting

- **Fn does nothing** → the menu bar's top line names the problem. If it
  mentions a stale Accessibility entry, remove zeldaFlow under Privacy &
  Security → Accessibility with **−** and add it back — see
  [Signing & permissions](#signing--permissions). Running
  `scripts/make-cert.sh` once stops it recurring.
- **Emoji picker appears instead** → the event tap is dead (see above), or
  set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.
- **"AI cleanup unavailable"** → `brew install llama.cpp`, check
  `~/Library/Application Support/zeldaFlow/llama-server.log`. Dictation still
  works — raw/light cleanup is the automatic fallback.
- Logs: `~/Library/Application Support/zeldaFlow/zeldaflow.log` — see
  [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) for what each line means
  and a table of failure signatures.

## Contributing

Maintained at zeldaLabs ([MAINTAINERS.md](MAINTAINERS.md)), and open to people
building on it. Fork it, extend it, ship things with it —
[CONTRIBUTING.md](CONTRIBUTING.md) has the
build path, the recipe for adding a voice command, and the two house rules
(every behaviour change brings an ADR and an eval pin). Run `--selftest` and
`--evalcommands` before sending a PR. No roadmap promises.

The one thing that will not be merged, ever: anything that puts dictation on
the network. That constraint is the product.

## License

Apache-2.0 © 2026 zeldaLabs FZ LLC — see [LICENSE](LICENSE) and
[NOTICE](NOTICE). You can fork it, modify it, and ship products built on it,
commercially and closed-source if you want.

The name and the three-wave mark are not covered by that grant (Apache-2.0
§6) — a modified fork needs its own name. [TRADEMARK.md](TRADEMARK.md) says
where the line sits in plain words; the answer is usually yes.

Third-party code and models — all under permissive licenses (MIT, Apache-2.0,
BSD-2-Clause, CC-BY-4.0) — are itemised in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

The dictation is local; the maintainers are reachable:
manu@zeldalabs.com, sahas@zeldalabs.com.
