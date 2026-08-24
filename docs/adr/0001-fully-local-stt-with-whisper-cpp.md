# 1. Fully local on-device STT with whisper.cpp instead of any cloud service

Status: Accepted
Date: 2026-07-19

## Context

zeldaFlow is positioned explicitly as a fully local, native-Swift alternative to
Wispr Flow: no cloud, no account, no subscription — your voice never leaves
your Mac. The README calls that sentence "the design constraint, not a
tagline." Dictation must also be fast (sub-second after key release) and
private on Apple Silicon.

## Decision

Run whisper.cpp large-v3-turbo (q8_0) in-process via a vendored XCFramework,
Metal-accelerated, ~1 GB resident, with all inference serialized on one
dedicated queue (`zeldaflow.stt`). Decoding uses greedy sampling with
`temperature_inc = 0` — no fallback re-decodes, so latency is bounded — and
`translate = false`, so speech is transcribed in its own language and script,
never translated to English.

## Alternatives considered

- Cloud STT (Whisper API, Deepgram, Apple's server-side dictation) — rejected:
  violates the core privacy constraint.
- Apple's on-device `SFSpeechRecognizer` — weaker accuracy and vocabulary
  control, no initial-prompt biasing.
- Running whisper as a separate server process (like the Gemma sidecar) —
  in-process linking avoids IPC latency and a second daemon.
- Beam search / temperature-fallback decoding — rejected for unbounded
  latency.

## Consequences

**Good**

- Fast: measured 2026-07-28 on an M4 Pro (24 GB), a 3 s clip transcribes in
  ~0.9–1.0 s, a 20 s clip in ~1.1 s, and a 48 s stress clip in ~1.5 s, with
  ~1.1 GB peak RSS and ~750 ms model load + warm-up.
- Zero network dependency; dictionary biasing works via a carried
  `initial_prompt`.

**Bad**

- ~1 GB always-resident memory.
- A ~76k-line vendored `Vendor/whisper.xcframework` blob lives in git.
- Greedy decoding forgoes whisper's quality-recovery fallbacks.
- Whisper's caption-hallucination behavior had to be countered separately
  (see [ADR 8](0008-anti-hallucination-vad-and-filter.md)).

Evidence: commit 0377f77 (`Sources/zeldaFlow/STT/WhisperEngine.swift`,
`Vendor/whisper.xcframework`); `translate = false` added in 395d513.
