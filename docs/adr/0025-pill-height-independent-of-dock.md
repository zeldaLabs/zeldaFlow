# 25. The pill's resting height must not depend on where the Dock is

Status: Accepted
Date: 2026-08-02

## Context

The pill anchored itself 20 pt above `visibleFrame.minY` — the top of the
Dock when the Dock is on that display, the bottom of the glass when it
isn't. The Dock lives on one display at a time and migrates as the pointer
moves, so the same app rested ~110 pt up on the Dock's display and 20 pt up
on every other. On the user's external monitor (frame origin y = −98) that
put the pill at y = −78, visually jammed into the bottom edge — reported as
"the pill sits where the dock was".

Instrumenting the real two-display setup ruled out the plausible suspects
first: AppKit does not constrain a borderless panel on `orderFront`/
`makeKey` (verified on the negative-origin display), the type bar grows
symmetrically about its centre, and ADR 18's display-stickiness and
recovery paths all measure correct. Only the height rule was wrong.

## Decision

`PillPanel.bottomY(for:)` computes the resting height from the *screen*
frame, not the visible frame alone: clear the Dock when the Dock is there
(`dockInset + 20`), and otherwise hold a constant 90 pt resting height —
chosen to match what a standard Dock produces, so the pill sits at the
same visual height whichever display it is on. All positioning paths and
the eval share this one function.

## Alternatives considered

- **Keep `visibleFrame + 20` everywhere** — correct Dock avoidance,
  wrong resting height on every Dock-less display; the reported bug.
- **Constant offset from the screen bottom, ignore the Dock** — consistent,
  but a bottom Dock overlaps the pill; the pill must never sit under UI.
- **Track the Dock's live position and animate** — the
  `didChangeScreenParameters` debounce (ADR 18) already re-anchors after
  Dock moves; per-frame tracking buys nothing further.

## Consequences

**Good**

- Height spread across displays drops from 90 pt to 20 pt; on the external
  monitor the pill rises from 20 pt to 90 pt off the glass.
- `--evalpill` measures resting height on every attached display and fails
  if any display leaves the pill under 40 pt or the spread exceeds 40 pt.

**Bad**

- 90 pt of reserved visual space on Dock-less displays is opinion, not
  arithmetic; a user with a huge Dock still sees a (smaller) height jump
  when the Dock migrates onto the pill's display.

Evidence: `Sources/zeldaFlow/UI/PillPanel.swift` (`bottomY(for:)`),
`Sources/zeldaFlow/Support/PillEvals.swift`; measured on the reporting
user's 1512×982 + 1920×1080 (y = −98) arrangement, 2026-08-02. Extends
ADR 4 and 18.
