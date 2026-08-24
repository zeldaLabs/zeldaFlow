# 13. Screen-context biasing reads the frontmost window via the AX tree, not OCR

Status: Accepted
Date: 2026-07-19

## Context

Whisper misspells names, emails, and jargon that are sitting right there in
the window the user is dictating into. Any capture of screen content is
privacy-sensitive for a privacy-first app.

## Decision

`ScreenContext` walks the focused window's `AXUIElement` tree (bounded:
depth < 25, ≤ 1500 nodes, ≤ 6000 chars) collecting value/title/description
strings, then scores distinctive terms — emails weighted 4,
camelCase/technical tokens 2, and plain capitalized words must recur to beat
sentence-start noise, against a stopword list — and feeds the top ≤ 15 into
Whisper's initial prompt and the cleanup prompt. It is explicitly
"session-scoped and fully local — the extracted text is discarded when the
session ends; nothing ever leaves the Mac." zeldaFlow's own windows are
excluded, and the feature is toggleable via `settings.screenContext`.

## Alternatives considered

- Screenshot + Vision OCR — needs the Screen Recording permission (a much
  scarier grant, later reserved for opt-out agent mode) and is slower and
  noisier than structured AX text.
- Persisting extracted context across sessions — rejected for privacy; the
  persistent path is the separate user-approved dictionary (ADR 14).
- No biasing, dictionary only — misses one-off on-screen entities.

## Consequences

**Good**

- Names and jargon spell correctly with no new permission beyond the
  Accessibility grant zeldaFlow already requires; a hard privacy boundary
  (ephemeral, local).

**Bad**

- AX trees are empty or shallow in some apps (many Electron/web views).
- Tree walking costs time on huge windows despite the bounds — the harvest
  later needed hard timeouts and its own queue
  ([ADR 19](0019-bounded-single-flight-ax-harvests.md)).
- The biasing prompt itself created a new failure mode — the decoder echoing
  its glossary into the preview — which the prompt-echo filter (ADR 8) then
  had to counter.

Evidence: commit 395d513 (`Sources/zeldaFlow/STT/ScreenContext.swift`);
`carry_initial_prompt` from 0377f77.
