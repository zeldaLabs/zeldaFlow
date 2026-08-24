# 27. Automatic meeting capture: record on detection, consent by visibility

Status: Accepted
Date: 2026-08-08

## Context

zeldaFlow already owned most of what a meeting notetaker needs — a mic
pipeline hardened by ADR 26, a resident local Whisper context, a local
LLM. It lacked the other side of the call, and a policy for *when* to
record.

The implementation this feature ports from (OpenWhispr) detects a meeting
and then **prompts**. The user decision here is to diverge: prompts get
dismissed, and the meeting you most wanted notes from is the one where you
were too busy talking to click Record. Detection starts the recording;
there is no prompt.

Recording without asking creates two duties the prompt used to cover:

1. **Nothing that is not a meeting may trigger.** A false start records a
   private moment, so corroboration must be *stricter* than the source's,
   not looser.
2. **A recording must be impossible to miss.** Silent capture is the one
   behavior auto-record must never produce.

Two platform facts also constrain the design: macOS has **no TCC query
API** for system-audio capture (the only way to learn the verdict is to
try), and the Mac has one microphone pipeline, which dictation also needs
mid-meeting.

## Decision

**Consent by visibility.** Four surfaces, none optional:

- An ambient **pill chip** (level bars, elapsed time, Stop/Discard) shows
  for the whole meeting and **overrides the idle-pill-off preference** —
  the `PillController.layout` invariant says consent visibility outranks
  that setting. Meeting transitions always use `.keep` placement (ADR 18):
  a meeting starting must never move the pill to another display.
- A **"Recording this meeting" banner** (plus a quiet Pop) at start; a
  saved/finished banner at end. Banners queue behind a live dictation
  rather than fight it for the surface.
- The **menu-bar icon becomes `record.circle`** at rest for the duration.
- **One-click Discard** in the menu bar, the banner, and the detail view —
  discard keeps nothing, and the whole meeting folder is deleted.

**Trigger = who is holding the microphone.** Per-process mic attribution
(CoreAudio process objects, `kAudioProcessPropertyIsRunningInput`,
macOS 14.4+) is the primary sensor: only a *known meeting app* (Zoom,
Teams ×2 bundle IDs, Webex) actually **holding the mic** for a sustained
2 s can start a meeting. Merely running never triggers — launch events are
context only, exactly to avoid the FaceTime-in-the-background false
positive the source hit. Refinements:

- **Browsers corroborate via a window-title probe**: a mic-holding browser
  might be dictation, so a meeting starts only when an AX walk finds a
  window titled like Meet/Zoom/Teams/Webex (re-probed every 5 s for up to
  120 s, then the holder is latched out until it releases the mic).
  Browser identity, not pid, names a browser call — Chrome helper pids
  churn mid-call.
- **FaceTime is opt-in, default off** — a personal call is not usually a
  meeting anyone wants notes of.
- **Tier-2 fallback** when per-process attribution is unavailable (the
  HAL lies on some betas): device-level mic activity corroborated by a
  known native app running or a browser-probe hit. This tier knowingly
  accepts the Teams-idle false positive; it is the degraded path, never
  the default.
- Never while dictating, and not for 2.5 s after (the dictation teardown
  itself looks like mic activity); zeldaFlow's own pid is excluded at the
  sensor so the hotkey can never start a meeting.
- Detection arms only when the feature is on **and** both mic and
  system-audio permissions are granted — no surprise half-recordings.

**Auto-stop by mic evidence, with honest thresholds.**

- **Mic idle 30 s** — not instant, because brief releases happen on route
  changes: an AirPods reconnect mid-call drops and re-acquires the app's
  mic hold (observed 3–10 s gap), and stopping there would split one
  meeting in two. A blip inside 30 s resumes the *same* meeting with its
  original start time.
- **App quit accelerates to 5 s** — a dead process cannot rejoin the same
  call; the 5 s only covers crash-then-instant-relaunch.
- **4 h cap**, **sleep = end** (a closed lid is leaving the meeting), and
  a **500 MB free-disk floor** (a 4 h dual capture spools ~920 MB).
- Captures **under 30 s are auto-discarded** — mic-test blips and misfires
  that slipped through corroboration; a "meeting" nobody would keep.
- Manual stop = 5 min cooldown (a dismissal of *this* call); auto stop
  re-arms after 60 s.

**"Them" via a global-except-self CoreAudio process tap.** Everything the
Mac plays, minus zeldaFlow's own output (so dictation chimes are not
transcribed as a participant). Global rather than PID-scoped is a
fail-loud-vs-fail-silent choice: a PID-scoped tap aimed at the wrong
process — and browser audio routinely comes from a different helper than
the mic holder — records *silence*, and nobody notices until the notes are
half empty. A global tap at worst records too much, which is visible and
deletable. The accepted cost: music playing during a call bleeds into
"Them". Excluding known media apps from the tap is the v1.1 refinement.
A tap failure degrades to **mic-only with a visible banner** — half a
transcript beats none, and this is not ADR 26's fail-closed case (that is
about refusing an unsafe *device*, not a missing second stream).

**"You" through AudioRecorder's streaming mode.** The meeting mic is the
same `AudioRecorder`, so every ADR 26 invariant is inherited: never open a
Bluetooth mic (enforced, throwing), verify-after-start, minimum ducking.
Meetings force voice-processing AEC on regardless of the dictation setting
— the far side plays through the speakers and would otherwise land in
"You" wholesale — while ADR 26's own gates still skip VPIO on Bluetooth.
A mid-meeting device swap restarts the engine in place (~100 ms gap)
instead of ending the session; if no safe mic remains, the meeting ends
rather than record half a call.

**Dictation borrows the meeting's mic.** Both features need the one
microphone; a second `AVAudioEngine` on the same device means double-VPIO
or an un-cancelled stream. So mid-meeting dictation takes a `MicLoan` —
the meeting's already-converted, already-AEC'd stream from the same tap
point — and AppState's snapshot/preview/final path works unchanged. Side
effect the user wants anyway: dictation starts instantly off the hot
engine.

**Permission by probe-and-cache.** With no TCC query API, status is
inferred: a probe tap that delivers frames ⇒ granted;
`kAudioHardwareIllegalOperationError` ('nope') at any step ⇒ denied; a
timeout proves nothing and persists nothing. Every real tap start
reconciles the cache in both directions. The first-ever probe is what
makes macOS show the consent dialog, so the probe timeout is really "how
long the user gets to click Allow" (60 s).

**The WAVs are a spool, not an archive.** Both channels spool to Int16
WAV (115 MB/h/stream) purely so a crash is recoverable; once the
transcript is finalized they are deleted. They hold nothing the transcript
doesn't — except replayable audio of *other people*, which the all-local
privacy story is better off without. (`NSAudioCaptureUsageDescription`
states the same promise: everything stays on this Mac.)

## Alternatives considered

- **Detect-then-prompt** (the source's shape) — rejected by explicit user
  decision; the failure mode is the missed meeting, and the prompt's
  consent role is replaced by visibility plus one-click discard.
- **PID-scoped process tap** — fails silently on helper-process audio
  routing; rejected for the global-except-self tap (see above).
- **App-launch triggers** — a backgrounded FaceTime/Teams would start
  recordings of nothing; launches are context, only mic possession
  triggers.
- **A second capture engine for mid-meeting dictation** — double-VPIO has
  undefined interference and the non-VPIO variant un-cancels the meeting's
  echo; the mic loan replaces it.
- **Prompting TCC status via a fake query** — no such API exists; the
  probe-and-cache inference (the same one the source ships) is the honest
  option.

## Consequences

**Good**

- Meetings are captured without anyone remembering to press anything, and
  a recording is visible from across the room — chip, banner, and menu
  icon all at once, whatever the idle-pill preference.
- Strict tier-1 triggering: an unknown app holding the mic (Voice Memos,
  a dictation site) can never start a recording.
- Tap loss, device swaps, low disk, sleep, and crashes all end or degrade
  the meeting *visibly*, never silently.

**Bad — the v1 cuts, recorded honestly**

- **No calendar integration**: nothing pre-announces a meeting; detection
  is purely acoustic/process-based.
- **No diarization**: "You"/"Them" channel labels are the only speaker
  separation (ADR 29); everyone remote is one voice. *(Reversed by ADR 31:
  post-meeting speaker diarization of the system channel.)*
- **No manual-notes editor tab** in the detail view — notes are generated,
  renameable, exportable, but not editable in place. *(Reversed by ADR 32:
  edit mode with debounced autosave.)*
- **Back-to-back meetings merge** if the mic never idles for 30 s — the
  same hysteresis that survives an AirPods reconnect cannot tell one call
  ending from the next beginning.
- **Background-tab browser meetings go undetected** (a window's AX title
  is its *active* tab); manual start covers them.
- Tier-2's Teams-idle false positive; music bleed into "Them" until the
  v1.1 media-app exclusion.

Evidence: `Sources/zeldaFlow/Meeting/MeetingCenter.swift`,
`MeetingDetectionEngine.swift`, `MicActivityMonitor.swift`,
`MeetingApps.swift`, `BrowserMeetingProbe.swift`,
`MeetingProcessMonitor.swift`, `MeetingRecorder.swift` (mic loan, spools,
disk floor), `SystemAudioTap.swift` (tap + permission probe);
`Sources/zeldaFlow/UI/PillPanel.swift` (`PillController.layout`
invariant); `Sources/zeldaFlow/Support/Permissions.swift` (systemAudio);
`Sources/zeldaFlow/AppState.swift` (mic-loan session plumbing);
`Resources/Info.plist` (`NSAudioCaptureUsageDescription`). Extends
ADR 26; the transcription and notes policies are ADR 29 and ADR 30.
