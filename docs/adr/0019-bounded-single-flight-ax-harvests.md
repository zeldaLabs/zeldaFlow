# 19. Bound screen-context AX messaging and run harvests single-flight off the cooperative pool

Status: Accepted
Date: 2026-07-28

## Context

Every Fn press ran `ScreenContext.glossaryTerms()` in a `Task.detached` on
the Swift cooperative thread pool. The harvest is a synchronous AX walk — up
to 1500 elements × up to 4 blocking mach-IPC calls (~6000 round trips) —
with no messaging timeout (macOS default: ~6 s per call to a busy app), no
deadline, and no cancellation. One harvest against a slow app could pin a
pool thread for minutes, and retry presses spawned fresh harvests with no
single-flight guard, stacking blocked threads until the fixed-width pool
starved. Then no nonisolated async code could run: transcription, cleanup,
and command interpretation all hung while the UI looked alive — the verified
"not recording, nothing works, blank" failure.

## Decision

Three bounds, applied together:

- **Per-element AX cap:** `ScreenContext` sets
  `AXUIElementSetMessagingTimeout(el, 0.25)` on each element it queries (the
  timeout doesn't transfer between refs), so no single AX call in the
  harvest can block for the ~6 s default. Deliberately scoped per element,
  not on the systemwide element: `MusicUIDriver` and every other AX consumer
  in the process keep macOS's default.
- **Wall-clock budget:** each harvest gets a 0.4 s deadline checked inside
  `collect()` alongside the depth/node/char caps, so a harvest never
  outlives the session it's biasing.
- **Single-flight on a dedicated queue:** harvests run on the serial
  `zeldaflow.screen-context` DispatchQueue — never the cooperative pool — and
  an in-flight flag skips spawning while one is running; that session simply
  goes without biasing terms.

## Alternatives considered

- Store and cancel the previous harvest's Task — blocking mach IPC never
  observes cancellation; the thread stays pinned anyway.
- Per-element timeouts only — still unbounded total wall clock across ~6000
  calls.
- Keep `Task.detached` and rely on pool width — the pool is fixed at the
  core count and never over-subscribes; it starves by design.
- Disable screen context by default — throws away the accuracy win (ADR 13)
  to fix a bounded-work bug.

## Consequences

**Good**

- A slow harvest costs at most one thread on its own queue for ~0.4 s; the
  cooperative pool that transcription and every async task depends on can no
  longer be starved by AX, and Fn retries no longer compound a stall.

**Bad**

- Slow apps yield fewer or no biasing terms for that session (silent quality
  degradation).
- A slow app can still cost one 0.25 s timeout per element inside the
  harvest — the 0.4 s wall-clock budget, not the per-call cap, is what
  bounds the total.
- Single-flight means one wedged harvest disables biasing until it returns.

Evidence: working-tree diff of `Sources/zeldaFlow/STT/ScreenContext.swift` and
`Sources/zeldaFlow/AppState.swift`; verified pool-starvation findings of
2026-07-28.
