# 20. Text insertion is fully async with suspending sleeps

Status: Accepted
Date: 2026-07-28

## Context

`TextInserter` ran synchronously on the main thread (both call paths — the
dictation finish pipeline and the @MainActor action executor — are
main-actor). Each insert blocked for a fixed ~168 ms (`Thread.sleep(0.12)`
for Electron clipboard settling plus 4 × 12 ms around the synthetic key
events), plus markdown RTF/HTML rendering. The Fn event tap's run-loop
source lives on the same main run loop, and it is an active filtering tap on
all keyDown/flagsChanged events: while the main thread sleeps, the window
server holds every keystroke system-wide, and macOS disables a tap whose
callback goes unserviced past the timeout (~1 s) — after which Fn does
nothing until the watchdog recovers it. The new header comment: "a
Thread.sleep here while pasting was enough to kill the hotkey under load."

## Decision

Make the whole insertion path async with suspending sleeps:
`insert(_:expectedFrontmost:)`, `copySelection()`, `postCmdV()`,
`postCmdKey()`, and the new `pressKey()` are `async`, and every
`Thread.sleep` became `try? await Task.sleep`. Call sites `await` them, so
the main thread keeps servicing its run loop — including the event tap —
while the paste sequence's delays elapse. Synthetic events keep the "HRBI"
marker so the tap passes them through.

All `TextInserter` entry points additionally serialize on an operation
chain — a MainActor-guarded task chain that each `insert()`,
`copySelection()`, and `pressKey()` links onto behind the previous
operation. The async conversion alone made overlapping calls reachable (an
agent flow typing while a fresh dictation finishes, a menu re-paste
mid-pipeline), which would have interleaved clipboard writes and synthetic
Cmd-V. The deferred 0.6 s clipboard restore is a link on the same chain, so
a following insert can never snapshot the transient text as the user's
clipboard.

## Alternatives considered

- Move the event tap to a dedicated thread/run loop — a larger change
  entangled with the tap's watchdog and gesture timing; the sleeps were the
  actual offender.
- Delete the sleeps — the 0.12 s clipboard-settle delay exists because slow
  Electron apps otherwise paste the previous clipboard.
- Keep the API synchronous and hop to a background queue at call sites —
  every caller is already async on the main actor; suspending is the natural
  shape and keeps the pasteboard/CGEvent calls' ordering explicit.

## Consequences

**Good**

- The main thread is never blocked during a paste, so the Fn tap stays
  serviced and system-wide keyboard delivery no longer stalls per insert.
- The same suspending path now backs other synthetic-keystroke features
  (`pressKey` for Return / Cmd-N).

**Bad**

- Insertion now interleaves with other main-actor work; correctness of the
  snapshot → paste → restore sequence relies on await discipline rather than
  a single blocking critical section.
- The underlying timing heuristics (fixed delays, `changeCount` checks)
  remain racy — they are just no longer blocking.

Evidence: working-tree diff of `Sources/zeldaFlow/Insert/TextInserter.swift`
and its call sites in `Sources/zeldaFlow/AppState.swift`; verified
tap-starvation finding of 2026-07-28.
