# 29. Dual-channel transcription: the channels are the speakers, text is the echo judge

Status: Accepted
Date: 2026-08-08

## Context

A meeting (ADR 27) produces two audio streams: the mic and the system
tap. Three problems follow:

1. **Attribution.** Who said what — without a diarization model.
2. **Contention.** Both streams must share the app's *single* Whisper
   context (ADR 1: one resident Metal context, one serial STT queue)
   without starving dictation, the interactive feature.
3. **Echo.** The far side plays through the speakers, leaks into the mic,
   and Whisper dutifully transcribes the same words twice. VPIO AEC
   upstream removes most of it, but AEC is imperfect exactly during
   double-talk — and the source project's field logs showed genuine local
   speech scoring waveform correlations of **0.73–0.81** during
   double-talk, above every audio gate. Audio evidence alone cannot
   safely condemn a mic segment.

## Decision

**The two channels ARE the speaker separation.** "You" is whatever the
mic carried; "Them" is whatever the Mac played. Attribution is physical,
so it is *exact* for the user's side and collapses everyone remote into
one voice — no model, no voice prints, no errors of the kind diarizers
make.

**A 5 s chunk scheduler that yields to dictation.** Every 5 s a tick
fires on the transcriber's own queue — never the STT queue. A tick is
skipped outright while the user dictates (audio keeps accumulating,
nothing is lost), so meeting work never even *enters* the STT queue
during dictation and a dictation final only ever waits behind at most one
already-in-flight meeting chunk. Measured on Apple Silicon
(large-v3-turbo-q8, ~10–20× realtime): a 5 s chunk is **0.3–0.6 s** of
context occupancy; a worst-case 30 s drain bite is **2–4 s**, which is
also the worst added latency a dictation final can see. Falling behind
(thermal throttling): ticks skip, backlog grows, and drains happen in
≤ 30 s bites — whisper's native window, so per-audio-second cost *drops*
with bigger chunks. No audio is ever dropped; the transcript just lags.
Chunk offsets derive from per-channel sample counters, never timers.
System drains before mic each pass — deliberate ported ordering, so the
system transcript lands in time to judge the same window's mic chunk.

**Per-channel scrub asymmetry.** "You" gets only `scrubFinal` — the same
ultra-conservative filter dictation finals get (ADR 8/22), because a
false drop of the user's own words is silent data loss. "Them" gets
`scrubMeetingSystem` with preview-junk aggression: it is other people's
audio, caption furniture there is near-certain hallucination, and a false
drop loses a sentence of someone else's speech that context usually
recovers.

**Echo control: AEC upstream, text-domain holdback downstream.** The
ported policy, kept verbatim as the load-bearing rule:

> a text match is the **only** condition that may drop a held-back
> segment. Audio-only echo evidence delays a segment, never discards it.

Mechanics:

- A mic chunk captured while the system channel was audible (RMS VAD,
  ±0.3 s tail) or inside the 1.5 s startup warmup is flagged **risky**.
- Risky finals are **held back 6 s** (chunk interval + 1 s: the hold must
  outlast one transcription cycle so a straddling remote utterance's
  *next-cycle* system transcript can still confirm buffered echo). At
  release they commit unless a system text matched them.
- A fresh system segment kills matching queued mic finals and **retracts
  already-committed** risky segments within a **4 s window**.
- **The committedAt race:** a held-back segment commits capture + ~11 s
  (one 5 s cycle + 6 s holdback), always beyond 4 s from any capture
  stamp — so the retract window races *both* clocks: capture-vs-capture
  for segments committed on arrival, and commit-time-vs-now (the system
  segment's arrival) for held-back releases. Without the second clause
  the retraction path for released segments is dead code.
- Matching is `TranscriptMatcher` — normalize, containment shortcut, then
  token coverage ≥ 0.6 OR token-LCS ratio ≥ 0.6 over the shorter side,
  minimum 3 tokens; candidates include every contiguous concatenation of
  up to 3 system chunks within ±6 s, so an echo straddling two chunks
  still matches the merged pair. The looser stopword-filtered matcher is
  ported but **unused**: the source only relaxes to it on waveform
  double-talk evidence v1 does not compute.
- Cheap gates run before Whisper ever sees a chunk: a silence gate on
  both channels, and a system-dominant mic gate (a quiet mic chunk while
  the far side speaks is speaker bleed, not the user).

**Ported constants, with provenance** (all from OpenWhispr):

| Constant | Value | Source (file:line) |
|---|---|---|
| Chunk interval | 5 s | ipcHandlers.js:5006 `LOCAL_MEETING_CHUNK_INTERVAL_MS` |
| Max chunk / drain bite | 30 s | whisper's native window |
| Risky holdback | 6 s | ipcHandlers.js:5006-5013 `LOCAL_RISKY_MIC_SEGMENT_HOLDBACK_MS` = chunk + 1000 |
| Retract window | 4 s | ipcHandlers.js `RACING_MIC_RETRACT_WINDOW_MS` |
| Dedup window | ±6 s | ipcHandlers.js:5006 `DUPLICATE_TRANSCRIPT_WINDOW_MS` |
| Merge limit | 3 chunks | ipcHandlers.js:5007 `DUPLICATE_TRANSCRIPT_MERGE_LIMIT` |
| Strict match | 0.6 / 0.6, ≥ 3 tokens | transcriptText.js:1-3 |
| Loose match (unused) | 0.55 / 0.55, ≥ 4 tokens | transcriptText.js:4-6 |
| Silence gate | RMS 0.0015, peak 0.05 | ipcHandlers.js:6146-6167 |
| Mic bleed gate | RMS 0.018, peak 0.07 | ipcHandlers.js `MEETING_MIC_BLEED_*` |
| Startup warmup | 1.5 s | ipcHandlers.js:5738-5741 `MEETING_STARTUP_WARMUP_MS` |
| System VAD floor | RMS 0.004 | meetingEchoLeakDetector.js:5 `MIN_SYSTEM_RMS` |
| VAD tail | 0.3 s | meetingEchoLeakDetector.js:23 `SYSTEM_VAD_TAIL_MS` |
| VAD history | 6 s | meetingEchoLeakDetector.js:2 `MAX_SYSTEM_HISTORY_MS` |

**Crash safety: per-segment appends, finalize-never-resume.** Every
commit is one JSONL append; retractions are tombstone appends, never
rewrites. Loss budget on a hard crash (no fsync, OS page flush): at most
**one chunk interval (5 s)** of system audio awaiting transcription, and
**chunk + holdback ≈ 11 s** of risky mic — both audio *not yet in the
file*; the write path adds nothing measurable, which is why fsync isn't
bought. At next launch an orphaned meeting is **finalized, never
resumed**: capture died with the process, and a rejoined call minutes
later is a new meeting. WAV headers are repaired so the spooled audio
stays recoverable.

## Alternatives considered

- **A diarization model** — heavy, error-prone, and the physical
  two-channel split already answers the only attribution question v1
  asks. "Them" stays undifferentiated; accepted.
- **Streaming transcription** (the source's other pipeline, with its 3 s
  holdback constant) — continuous decode occupies the shared context and
  starves dictation; the chunked pipeline is the one whose constants
  apply here.
- **The full 442-line waveform-correlation echo detector** — v1 ports
  only its binary "was the system audible?" question; correlation grading
  is what would justify the loose matcher, deferred together.
- **Dropping on audio evidence** — rejected by the ported field numbers
  (0.73–0.81 on genuine speech); audio may only delay.
- **A second Whisper context for meetings** — roughly another gigabyte
  resident plus Metal contention; the tick gate keeps one context fair.

## Consequences

**Good**

- A speaker-attributed transcript with the user's side exactly right, on
  hardware already running dictation, with dictation's worst-case added
  latency bounded at one 30 s bite (2–4 s).
- A hard crash loses ~11 s at most, and the loss is stated, not
  discovered.
- The matcher, holdback, retraction race, gates, and tracker are pure and
  clock-injected — `--evalmeeting` pins them deterministically.

**Bad**

- "Them" is everyone-else; no per-person attribution.
- Fixed 5 s windows can cut a word at a chunk boundary; VAD softens but
  does not remove this.
- Held-back segments commit up to ~11 s late and out of spoken order
  (the transcript view binary-inserts by start time).
- The text match cannot tell echo from *agreement*: if both sides say
  "sounds good" within 6 s, the user's copy may be dropped as echo. Rare,
  bounded by the risky flag, but real.
- On a throttled machine the live transcript lags (logged past 120 s of
  backlog); it catches up in 30 s bites, never drops.

Evidence: `Sources/zeldaFlow/Meeting/MeetingTranscriber.swift` (scheduler
+ duty-cycle numbers in its header), `MicHoldback.swift` (policy header,
committedAt remapping), `TranscriptMatcher.swift`,
`SystemActivityTracker.swift`, `MeetingSession.swift`,
`MeetingModels.swift`, `MeetingStore.swift` (loss budget at
`appendTranscriptLine`); `Sources/zeldaFlow/STT/HallucinationFilter.swift`
(`scrubMeetingSystem`). Extends ADR 1, ADR 8, ADR 22; capture policy in
ADR 27.
