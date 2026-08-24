# 3. Fn/Globe key as the global hotkey via a suppressing CGEventTap

Status: Accepted
Date: 2026-07-19

## Context

Push-to-talk needs a key that works in every app, never types characters,
and matches the Wispr Flow convention. Fn produces only `.flagsChanged`
events (keyCode 63, `.maskSecondaryFn`), and macOS itself binds it to the
emoji picker/dictation — so it must be intercepted below the system.

## Decision

`FnKeyMonitor` installs a suppressing session CGEventTap; returning nil from
the tap swallows the event before HIToolbox sees it, so macOS's own globe
action never fires. A single Fn key multiplexes four gestures via a small
state machine: hold (push-to-talk), double-tap (hands-free), triple-tap
(command mode), and bare tap (confirmation approval). Timing is deliberately
forgiving — a comment records that the original 0.25/0.35 s windows "made
hands-free nearly impossible to arm at normal speed," widened to 0.3/0.6 s.
A self-healing watchdog re-enables a disabled tap, reinstalls a dead one, and
retries when Accessibility is granted late. Synthetic events carry the marker
`0x48524249` ("HRBI") so the tap ignores zeldaFlow's own Cmd-V. Fn+arrow and
Fn+delete dirty the session and pass through.

## Alternatives considered

- Carbon `RegisterEventHotKey` / NSEvent global monitors — cannot suppress
  the system globe action, and NSEvent monitors are observe-only.
- A modifier chord like Cmd+Shift+Space — conflicts with app shortcuts and
  loses the hold-to-talk ergonomics.
- Menu-bar click or on-screen button only — no hands-free flow.

## Consequences

**Good**

- Works in any app, including full-screen; one key covers four gestures; the
  watchdog survives tap death and permission revocation.

**Bad**

- Hard requirement on the Accessibility permission.
- Ad-hoc-signed rebuilds silently kill the tap — the "emoji picker appears
  instead" failure mode documented in the README (see ADR 9).
- Tap-based gesture timing is inherently fiddly, and demo automation cannot
  synthesize Fn.

Evidence: commit 0377f77 (`Sources/zeldaFlow/Hotkey/FnKeyMonitor.swift`,
README Controls and Troubleshooting).
