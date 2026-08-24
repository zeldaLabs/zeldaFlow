# 18. Re-anchor windows on display reconfiguration; sticky pill that changes screens only at recording start

Status: Accepted
Date: 2026-07-28

## Context

Verified multi-monitor failures: nothing observed display reconfiguration,
and the pill's frame was recomputed only on phase transitions. Rearranging
or unplugging monitors rebases global Cocoa coordinates, and a borderless
panel is exempt from AppKit's constrain pass — so the idle nub could sit in
dead coordinate space until the next phase change. Worse, positioning picked
the screen under the mouse pointer, but dictation is keyboard-driven into
the focused window: with 2–3 monitors the pointer often rests on another
display, so recording feedback rendered where the user wasn't looking
("nothing happens when I dictate"). The Hub window had the sibling bug —
created once, centered once, retained across close — so reopened after its
display disconnected, it ordered in off-screen: "History & Settings…"
appeared to do nothing.

## Decision

- The pill is **sticky**: it remembers its display (`CGDirectDisplayID`) and
  changes screens in exactly two cases — a recording starts while the
  frontmost window is on a different display (`Placement.follow`; feedback
  belongs where the user is dictating), or its own display disappears. Every
  other transition — idle, the type bar opening, processing/notice/success,
  an unrelated monitor plugged or unplugged — re-anchors in place
  (`Placement.keep`). First shipped as "re-target on every phase change",
  which made the pill roam between screens during normal use; user-reported
  the same day and tightened to this rule.
- `PillController` observes `NSApplication.didChangeScreenParametersNotification`
  and re-runs `positionBottomCenter(placement: .keep)`, debounced 300 ms
  (the notification fires several times per dock/undock): same display if it
  survived (coordinates recomputed for the rebased arrangement), nearest
  live screen only if it didn't.
- The frontmost window's screen is resolved via the window server
  (`CGWindowListCopyWindowInfo` — the frontmost app's topmost layer-0
  window), never AX: the window server cannot block on a busy app, so a
  beachballing target can't stall the main thread that also services the Fn
  event tap. Fallbacks: the remembered display, the mouse screen, then
  `NSScreen.main` / first.
- The origin is clamped inside the target screen's `visibleFrame`, and an
  empty screen list (docking handshake) schedules a one-shot 1 s retry — a
  cancellable `DispatchWorkItem` that any newer positioning supersedes —
  instead of stranding the panel.
- `MainWindowController.show()` re-centers whenever the stored frame
  intersects no live screen.

## Alternatives considered

- Keep the mouse-screen heuristic — the verified failure mode on
  multi-monitor setups.
- `frameAutosaveName` for the Hub — AppKit restores autosaved frames without
  cross-screen validation, so it would not fix the stale-frame reopen.
- Rely on macOS's automatic window migration — it only moves windows on
  screen at disconnect time, and does not reliably rescue override-level
  `.stationary` panels or ordered-out windows.
- Mirror recording state only in the menu-bar icon — easily missed.

## Consequences

**Good**

- Recording feedback appears where dictated text will actually land; the
  pill otherwise stays parked where the user last saw it; the app's main
  visible surface survives docking, undocking, and rearranging displays; and
  the Hub always opens somewhere visible.

**Bad**

- A recording-start reposition costs a `CGWindowListCopyWindowInfo` query —
  cheap and non-blocking, but it enumerates every on-screen window.
- More placement machinery: the keep/follow distinction, the remembered
  display ID, plus the clamp, debounce, and retry paths.

Evidence: working-tree diff of `Sources/zeldaFlow/UI/PillPanel.swift`
(`frontmostWindowScreen()` via `CGWindowListCopyWindowInfo`),
`Sources/zeldaFlow/UI/MainWindow.swift`; verified multi-monitor findings of
2026-07-28.
