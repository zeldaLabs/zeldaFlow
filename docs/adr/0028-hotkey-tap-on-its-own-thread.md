# 28. The hotkey tap gets its own thread and a non-blocking callback

Status: Accepted
Date: 2026-08-04

## Context

The hotkey lagged. Pressing Fn took a visible moment to bring the pill up,
a second press often did nothing at all, and the whole interaction felt
unreliable in a way that was hard to pin down because it only happened
*sometimes*.

Three facts, measured on this machine, explain all of it:

1. **The tap callback called the delegate synchronously.** Pressing Fn ran
   `AppState.hotkeySessionShouldBegin()` inline, which ran
   `AudioRecorder.start()` inline: **610 ms** to build the voice-processing
   graph plus **218 ms** for `engine.start()` — **845 ms cold**.
2. **A warm graph costs 64 ms.** VPIO is kept warm for two minutes after a
   dictation (ADR 26), so only the first press after a pause paid the cold
   start. That is the "sometimes".
3. **An active head-insert tap holds the system's entire keyboard stream
   while its callback runs**, and its run-loop source was on the **main**
   run loop — so the callback also could not start until whatever main was
   doing finished.

Together: a press stalled every key on the machine for up to ~850 ms, a
second press inside that window was lost, and a callback that overran the
OS timeout got the tap disabled outright (`.tapDisabledByTimeout`) until the
5 s watchdog noticed. ADR 20 had already worked around the symptom from the
other side — banning `Thread.sleep` from insertion because "the Fn event tap
shares the main run loop, and macOS disables unserviced taps." That
constraint is what this record removes.

## Decision

Two rules, and everything else follows from them:

1. **The tap lives on its own `.userInteractive` thread with its own run
   loop.** Nothing the main thread is doing can delay key handling, and the
   main thread is no longer on the critical path of a keystroke.
2. **The callback only walks the state machine and returns the swallow
   decision.** No delegate calls, no settings reads, no CoreAudio. Every
   delegate call is queued to the main actor *after* the event has already
   been answered.

Rule 2 forces three consequences:

- **The session start is optimistic.** The press arms the hold immediately
  and the main actor confirms afterwards; a start that fails unwinds the
  press that armed it. The pill goes up on the press, not 850 ms later.
- **`AudioRecorder` starts and stops on a serial engine queue.** `start` is
  fire-and-forget with a completion; `stop` returns the captured samples
  immediately and queues the graph teardown behind whatever start is still
  in flight. No caller ever waits on CoreAudio.
- **The main actor pushes state to the tap instead of answering it.** The
  two questions the callback must answer synchronously — *should this Esc be
  swallowed?* and *is a session really live?* — used to be round trips to
  the main actor. `AppState.phase` now mirrors into the monitor on every
  change, and a rebind is pushed rather than polled per event.

State shared between the tap thread and the main actor sits under one lock,
never held across a delegate call.

## Alternatives considered

- **Keep the tap on main, just make the delegate async.** Removes the
  stall inside the callback but not the wait *for* it: a busy main thread
  still delays the callback and can still time the tap out.
- **Pre-warm the audio graph so the cold start never happens.** Holding VPIO
  open indefinitely is exactly the system-wide voice mode ADR 26 exists to
  avoid — ducking, Bluetooth profile flips, the orange dot.
- **Raise the double-tap windows to paper over the lost presses.** Treats a
  dropped event as a timing problem; the event was never delivered.

## Consequences

**Good**

- The press is answered in **0.012 ms with the main thread blocked for
  500 ms** (0.007 ms free) — measured by `--evalhotkey`, which blocks main
  deliberately and times the callback anyway. Under the old design that
  measurement *was* the block duration, by construction.
- Sustained input stays microsecond-scale: 200 events, mean 0.001 ms,
  worst 0.009 ms.
- Double- and triple-tap became reliable, because no press is dropped.
- Tap timeouts should now be impossible; the watchdog is a backstop rather
  than the recovery path. A `.tapDisabledByTimeout` in the log is now a real
  signal and is logged as an error.
- ADR 20's constraint is lifted — though async insertion remains right on
  its own merits.

**Bad**

- Concurrency moved from "main actor owns everything" to a lock plus two
  mirrored flags. Mirrors can drift; `AppState.phase`'s `didSet` is the
  single writer that keeps them from doing so.
- A cold start still clips the first ~850 ms of audio. That is inherent to
  VPIO spin-up (ADR 26), not to this change, and it behaved identically
  before — the press simply used to wait for it.
- `--evalhotkey` drives the callback directly rather than through a real
  hardware Fn press; the hardware path is still UAT's job.

Evidence: `Sources/zeldaFlow/Hotkey/HotkeyMonitor.swift`,
`Sources/zeldaFlow/Support/HotkeyEvals.swift`,
`Sources/zeldaFlow/Audio/AudioRecorder.swift`. Amends ADR 3, relaxes ADR 20.
