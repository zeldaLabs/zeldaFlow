# 33. WhatsApp call capture: opt-in, corroborated by input+output dwell

**Status**: Accepted
**Date**: 2026-08-09

## Context

WhatsApp Desktop is where a lot of real calls happen, and the notetaker
couldn't see them. Facts established before building (researched and locally
verified 2026-08-09 against WhatsApp v26.29.73):

- The macOS client is a **Mac Catalyst app**, bundle ID
  `net.whatsapp.WhatsApp` — and **call audio plays in the main process**:
  the WebRTC/libopus stack lives in `SharedModules.framework`, loaded by the
  main executable. No Safari-style helper-process attribution is needed;
  exact bundle-ID equality also excludes the persistent `.Intents` /
  `.ServiceExtension` appexes and Sparkle XPCs.
- Core Audio process taps capture WhatsApp calls without special-casing
  (Audio Hijack lists it among its supported voice-chat apps, no caveats).
  The output stream is echo-cancelled — remote party only — so the existing
  dual-channel You/Them pipeline works unchanged, including diarization
  (ADR 31) on the far side.
- **Mic-in-use is NOT a call signal for WhatsApp**: its microphone also
  records voice notes and camera videos. The reliable call signature is the
  process showing **mic input AND audio output concurrently, sustained** —
  a voice-note recording is input-only, playback is output-only, a call
  (voice or video) is both, starting with ringback.
- `kAudioProcessPropertyIsRunningOutput` reflects IO registration and its
  listeners are reported flaky — so the state is **polled** (the mic
  monitor's 5 s heartbeat), never trusted to its own listener.
- Consent: ~12 US states require all-party consent; India permits
  participant recording for personal use. Same posture as FaceTime
  (ADR 27's opt-in precedent): default OFF, settings copy carries a
  consent reminder, the violet pill stays the visible-recording guarantee.

## Decision

**Generalize the FaceTime gate and corroborate WhatsApp by output dwell.**

- `MeetingApps.personalCall = {FaceTime, WhatsApp}` — each behind its own
  default-OFF toggle. The engine's gate closure is now
  `enabledPersonalCallApps() -> Set<String>`, closure-read per decision so
  toggles apply instantly. The old `detectFaceTime` Bool and — fixed en
  route — the `facetime.contains(bundleID)` **substring** test (a latent
  String.contains bug) are gone; membership is set equality.
- `MeetingApps.outputCorroboration = {WhatsApp}`: holders in this set enter
  pending **uncorroborated** and corroborate only after
  `personalCallOutputDwell` (default 10 s; the 5 s heartbeat makes the
  effective trigger ~10–15 s) of concurrent input+output on the same
  process. An output blip resets the clock — notification sounds never
  accumulate into a "call". FaceTime is deliberately NOT in this set: its
  mic use is only ever a call, and its shipped path must not change.
- `MicActivityMonitor.MicUser` gains `runningOutput`, read by poll in the
  tier-1 recompute. Voice-note recording (input-only) therefore rides the
  existing corroboration-window machinery: never corroborates → holder
  latches out until it releases the mic. Playback (output-only) never
  enters pending at all. Sub-30 s misfires are additionally auto-discarded
  by the existing floor in MeetingCenter.
- **Tier-2 never trusts WhatsApp**: the degraded (unattributed) tier's
  corroboration set is `native ∪ (enabled personal-call apps ∖
  outputCorroboration)` — an all-day chat app merely running is not
  evidence of a call. WhatsApp detection is simply unavailable when
  attribution is lost. Browser probes also never corroborate an
  output-dwell holder (a Meet tab open somewhere must not bless a voice
  note).
- Stop/quit behavior needs nothing new: main-process attribution means
  `.micIdle` and the `.appQuit` accelerator (process monitor now watches
  `native ∪ personalCall`) work as for any native app.

## The canary

Meta already regressed WhatsApp on Windows to a WebView2 wrapper
(Nov 2025). If the Mac app follows, call audio moves into a helper process
and detection quietly stops. No code for a hypothetical: the existing
`MicActivityMonitor: mic holders ->` log line names the exact bundle ID
holding the mic (now with `+out` markers) — one field report identifies the
new process, and `browserFor`-style prefix attribution is the known fix.

## Alternatives considered

- **Mic-in-use alone + short-capture auto-discard** — rejected: long voice
  notes exist, and recording even the first seconds of one is the exact
  privacy failure the opt-in posture promises away.
- **CXCallObserver (WhatsApp links CallKit)** — unverified on native macOS
  for third-party calls; left as a possible future crisp start/end signal,
  never a dependency.
- **A stored Set<String> setting** — rejected for two Bools; the FaceTime
  key stays untouched, zero migration.

## Consequences

- **Good**: WhatsApp calls (voice and video) become meetings with the full
  pipeline — dual-channel transcript, diarized far side, notes; voice notes
  are structurally incapable of triggering; FaceTime behavior is pinned
  unchanged by eval.
- **Bad**: call start is recognized ~10–15 s in (dwell + heartbeat
  quantization) — the opening seconds are not captured. Accepted: the
  alternative is voice-note false positives.
- **Bad**: if WhatsApp keeps an output unit registered while idle,
  IsRunningOutput could read true during a voice note and defeat the dwell.
  Field verification on a real call/voice note is the remaining manual
  check; backstops are the default-OFF toggle and the sub-30 s discard.

Evidence: `Sources/zeldaFlow/Meeting/MeetingApps.swift`,
`MeetingDetectionEngine.swift` (output-dwell corroboration),
`MicActivityMonitor.swift` (`runningOutput`),
`Support/MeetingEvals.swift` (WhatsApp scenarios in `detectionSection`).
