# 21. Whisper's Core ML ANE encoder is an optional install; Metal stays the default

Status: Accepted
Date: 2026-07-28

## Context

The vendored whisper.framework is built with Core ML support: on every model
load it looks for a companion `ggml-large-v3-turbo-encoder.mlmodelc` that
runs the encoder — the bulk of whisper's compute — on the Neural Engine. The
file was never shipped or downloaded, so every launch logged "failed to load
Core ML model" at error level (57 times in the investigated log) and fell
back to the GGML Metal encoder on the GPU — the same GPU WindowServer uses
to composite external displays, while the live-preview loop re-transcribes
up to a 12 s tail throughout a recording. (The measured latency regression
was primarily caused by the preview loop itself; monitor contention is an
aggravator, addressed separately by an adaptive preview cadence in the same
working tree.)

## Decision

`scripts/setup.sh` downloads the Core ML encoder (1.1 GB, from the upstream
whisper.cpp Hugging Face repo) as an optional step: if the download fails,
setup prints "Metal fallback works fine" and continues. The install is
atomic — the download resumes via a `.part` file, and the zip is unpacked
into a hidden staging directory then atomically renamed into place, so the
`.mlmodelc` either exists complete or not at all. Metal remains the
default, fully supported path — nothing requires the mlmodelc. With it
installed, the encoder leaves the GPU that composites external displays and
runs on the ANE instead. `WhisperEngine` distinguishes the two failure
shapes: "not installed" is demoted from whisper's per-launch "failed to
load Core ML model" error to a one-time INFO hint pointing at
`scripts/setup.sh` (a missing optional install is setup guidance, not a
failure), while "present but failed to load" — a corrupt or partial
install — logs a one-time ERROR pointing at deleting it and re-running
`setup.sh`.

## Alternatives considered

- Ship the mlmodelc in the repo — a 1.1 GB binary blob in git, on top of the
  already-vendored xcframework.
- Make the ANE encoder required — breaks installs without it and adds a hard
  network dependency to first run; the Metal path demonstrably works.
- Stay Metal-only — leaves avoidable GPU contention on exactly the
  multi-monitor setups where zeldaFlow struggled.
- Generate locally via whisper.cpp's `generate-coreml-model.sh` — requires a
  Core ML toolchain the machine may not have; downloading is simpler.

## Consequences

**Good**

- Machines that run `setup.sh` get the encoder off the shared GPU; dictation
  stays fast under display-compositing load.
- Setup degrades gracefully offline, and the log no longer cries wolf on
  every launch.

**Bad**

- Two performance profiles (ANE vs Metal encoder) now exist in the field.
- An extra 1.1 GB download on top of the existing models.
- The decoder still runs on Metal either way — the ANE covers the encoder
  only, so GPU contention is reduced, not eliminated.

Evidence: working-tree diff of `scripts/setup.sh` and
`Sources/zeldaFlow/STT/WhisperEngine.swift`; verified GPU-contention finding of
2026-07-28.
