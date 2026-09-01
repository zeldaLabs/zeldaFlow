# 31. Post-meeting speaker diarization of the system channel

**Status**: Accepted
**Date**: 2026-08-09

## Context

ADR 29 made the two capture channels the speaker labels: mic = "You", system
audio = "Them". That is exact for who is local, and blind past it — a
three-person call renders everyone remote as one voice. The ask: real speaker
sections ("Speaker 1/2/3", renameable), still fully on-device.

Facts that shaped the design (researched and verified 2026-08-09):

- **Apple ships no diarization.** SpeechAnalyzer (macOS 26) and the macOS 27
  beta have zero speaker-attribution API; the ecosystem pattern is Apple or
  Whisper ASR plus a pyannote-lineage CoreML diarizer.
- **FluidAudio v0.15.5** (Apache-2.0, Swift-6-only SPM package) runs the
  pyannote community-1 offline pipeline (powerset segmentation + WeSpeaker
  embeddings + VBx clustering) on the **ANE** at 65–122× realtime — a 1-hour
  meeting in ~30–60 s, with no contention against whisper.cpp (Metal) or
  Gemma (GPU). Models are CC-BY-4.0 and ungated (~100 MB).
- **No Package.swift compiles on this CLT** (ADR 10), so the dependency is
  **vendored**: `Vendor/FluidAudio/` (Diarizer/Shared/VAD subset, see
  VENDORED.md) built by build-app.sh as a separate `-swift-version 6` static
  module. Exactly ONE app file imports it (`SpeakerDiarizer.swift`) — stub
  that file and the feature is gone with zero blast radius.
- **The spools are the input.** `system.wav`'s clock is the same per-channel
  frame counter that timestamps `.them` segments, so diarizer turns align
  with segment times exactly, no epoch correction.

## Decision

A **post-meeting, fail-closed diarization pass over `system.wav` only**,
inserted between stop and spool cleanup (the pass moved `cleanupSpools`
after itself; a nil result still cleans up and never blocks polish/notes).

- **Channel split stays ground truth.** "You" is never touched. Diarization
  only refines `.them` segments to a `speaker: Int?` cluster index —
  0-based by first speech time, so "Speaker 1" is whoever talked first.
- **Alignment** is summed-temporal-overlap voting per segment (Whisper
  timestamps drift ±0.5–1 s and a 5 s chunk can span turns), falling back to
  midpoint containment, then nearest-edge within 1 s, then nil —
  **unattributable stays generic "Them"**, the aligner never guesses.
- **The single-speaker rule**: one cluster found ⇒ no rewrite, no labels; a
  1:1 call keeps today's exact rendering.
- **Storage**: `speaker` is an optional field on `MeetingSegment`, written
  through the one sanctioned `rewriteTranscript` path (polish carries it).
  Old JSONL decodes unchanged; old builds ignore the key. `MeetingMeta`
  gains `speakerCount`/`speakerNames`/`diarizedAt`; schemaVersion stays 1
  (optional-only additions).
- **Hash stability is a hard invariant**, pinned by eval:
  `orderedTranscriptText()` still emits "You:/Them:" — the notes pipeline,
  the `owner` grammar, and `notesHash` staleness are untouched by ADR 31.
  Speaker-aware *notes* are an explicit v2 — shipped as
  [ADR 38](0038-speaker-attributed-notes-with-inferred-names.md), which
  keeps this hash invariant intact via a separate LLM-facing builder.
- **Renaming** ("Speaker 1" → a real name) lives in `meta.speakerNames`,
  per meeting, and flows into transcript UI and exports — never into the
  transcript file or its hash.
- **UI**: the two-sided chat keeps its channel geometry; a speaker change
  inside Them starts a new group with a colored dot + label (right-click to
  rename). A new `MeetingStore.transcriptRewrites` subject refreshes an
  open detail view when the rewrite lands (this also fixed the pre-existing
  gap where polish rewrites were invisible until reopen).
- **Models via setup.sh** (ADR 17: the app never fetches) —
  `ModelHub.offlineMode = true` at runtime turns a missing model into a
  clean skip, and Settings says how to install.

## Alternatives considered

- **Argmax SpeakerKit** (MIT, same pyannote lineage, built-in transcript
  fusion) — kept as fallback; drags a second Whisper runtime into an app
  that embeds whisper.cpp.
- **sherpa-onnx** — CPU-only via onnxruntime + C bridging; FluidAudio is its
  ANE-native successor and credits it.
- **whisper.cpp tinydiarize** — speaker-turn tokens only, no clustering, no
  "Speaker N" identity; adds nothing over the channel split.
- **Streaming/live diarization** — offline batch posts materially better DER
  and the product moment ("sections in the finished transcript") doesn't
  need live labels.

## Consequences

- **Good**: multi-speaker meetings finally read as a conversation; all
  local; ANE-resident so the Gemma passes are undisturbed; every alignment
  decision is pure and eval-pinned.
- **Bad**: ~100 MB more models, a vendored tree to maintain (VENDORED.md
  documents the upgrade path), and VoIP-compressed far-end audio may cluster
  worse than the published benchmarks — the confidence floor and
  single-speaker rule bound the damage to "fewer labels", never wrong
  channels.
- **Cut, recorded honestly**: crash-recovered meetings skip diarization in
  v1; cross-meeting speaker identity ("same client next week") needs an
  embedding store the offline pipeline doesn't ship yet.

Evidence: `Sources/zeldaFlow/Meeting/SpeakerDiarizer.swift`,
`Sources/zeldaFlow/Meeting/MeetingCenter.swift` (stop path),
`Vendor/FluidAudio/VENDORED.md`, `scripts/build-app.sh`, `scripts/setup.sh`,
`Support/MeetingEvals.swift` (`diarizationSection`).
