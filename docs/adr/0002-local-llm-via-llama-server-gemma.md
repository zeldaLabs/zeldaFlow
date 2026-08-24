# 2. Local LLM via a supervised llama-server child running Gemma

Status: Accepted
Date: 2026-07-19

## Context

Transcripts need optional AI cleanup (fillers, self-corrections, punctuation)
and command mode needs natural-language-to-action interpretation — both
without the cloud. llama.cpp's server is the practical way to keep a
quantized model resident.

## Decision

`CleanupService` supervises a resident llama-server (Homebrew llama.cpp)
running Gemma 4 E2B Q4_0 on 127.0.0.1 as a child process: launch on demand,
poll `/health` for up to 120 s, send a warm-up request, restart up to 3 times
with backoff, and keep a pidfile to reap orphans across app crashes
(verifying via `proc_pidpath` before killing, against PID reuse). An
already-running server on the port is adopted, never killed. Cleanup has a
hard 8 s timeout and always falls back to the raw transcript; sanity checks
reject empty output and runaway rewrites (> 3x the input + 80 chars).

## Alternatives considered

- Cloud LLM (OpenAI/Anthropic API) — rejected for dictation privacy; later
  allowed only as the explicit opt-out agent-mode exception (ADR 17).
- Linking llama.cpp in-process like whisper — a server child isolates crashes
  of the much larger model and allows sharing one server across runs.
- Core ML / MLX or Apple Foundation Models — less controllable, no drop-in
  GGUF support.
- A larger local model — Gemma E2B chosen for ~0.4–0.5 s cleanup latency and
  ~100 tok/s generation.

## Consequences

**Good**

- Cleanup never blocks dictation ("cleanup must never block dictation" is a
  stated design rule); every failure degrades honestly — without llama.cpp
  installed, raw transcripts still insert.

**Bad**

- Homebrew llama.cpp becomes an optional external dependency, with a ~2.8 GB
  model mmap on first start.
- Process-supervision complexity: generation counters, pidfiles, port
  adoption.
- Command-mode quality is capped at a 2B-class model.
- The server's 4096-token context bounds cleanup: transcripts past ~4,500
  characters (roughly five spoken minutes) skip Gemma and take the
  deterministic light-cleanup path instead, and any cleanup output that
  shrinks below a third of its input is rejected as truncation. Both guards
  added 2026-07-28 after the 12-minute dictation stress test showed the
  model silently returning only the first chunk of an over-context
  transcript.

Evidence: commit 0377f77 (`Sources/zeldaFlow/Cleanup/CleanupService.swift`,
README troubleshooting section).
