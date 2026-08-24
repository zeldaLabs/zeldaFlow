# 4. Pill HUD as a non-activating borderless NSPanel, not a regular window

Status: Accepted
Date: 2026-07-19

## Context

The recording/preview HUD must appear over any app, on any Space and in
full-screen, without stealing keyboard focus from the field the user is about
to paste into.

## Decision

`PillPanel` is an NSPanel with `[.borderless, .nonactivatingPanel]`, level
`.screenSaver`, collection behavior `[.canJoinAllSpaces,
.fullScreenAuxiliary, .stationary, .ignoresCycle]`, `canBecomeKey`/`Main`
false, and `ignoresMouseEvents` true — a pure indicator. Positioning
originally used the screen under the mouse rather than `NSScreen.main`, with
a comment explaining that `NSScreen.main` follows the key window, which a
background accessory app never has. The app itself runs as an `LSUIElement`
accessory (no Dock icon) with a menu-bar status item.

## Alternatives considered

- A normal NSWindow — would activate zeldaFlow and move focus away from the
  paste target.
- Notification Center banners — too slow and ephemeral for a live waveform
  plus preview.
- Menu-bar-only feedback — no glanceable state while speaking.

## Consequences

**Good**

- The target app keeps focus for the synthetic Cmd-V; the pill is visible
  everywhere, including over full-screen video.

**Bad**

- Non-activating panels have sharp edges: the later type-bar feature had to
  fight "first mouse" click handling and conditional key-window status
  (ADR 11).
- Screen positioning needed the mouse-location workaround — a heuristic that
  later proved wrong on multi-monitor setups and was replaced by the
  focused-window screen with display-reconfiguration re-anchoring
  ([ADR 18](0018-reanchor-windows-on-display-changes.md)).

Evidence: commit 0377f77 (`Sources/zeldaFlow/UI/PillPanel.swift`,
`Sources/zeldaFlow/main.swift` accessory activation policy,
`Resources/Info.plist` LSUIElement).
