# 11. Always-on mini pill with a Spotlight-style click-to-type command bar

Status: Accepted
Date: 2026-07-19

## Context

After launch, the pill only appeared during sessions; Wispr-Flow-style
products keep a persistent affordance on screen, and some commands are easier
typed than spoken.

## Decision

The idle pill becomes a slim always-visible nub at bottom-center (toggleable
in Settings) that grows a waveform on hover and opens a type bar on click.
Typed commands reuse the exact same command pipeline as spoken ones, with the
transcription step skipped. To make typing work in a non-activating panel:

- A `FirstMouseHostingView` overrides `acceptsFirstMouse` (a non-activating
  panel never becomes key before a click, so AppKit drops the first click).
- `canBecomeKey` becomes conditional on an `allowsKey` flag set only while
  typing — the panel takes key without activating zeldaFlow, "exactly like
  Spotlight."
- The panel resizes per phase (small while idle so the hover zone doesn't
  swallow clicks), and `didResignKey` closes the bar (click-away dismissal).

The same commit switched `install.sh` from osascript-quit to `pkill`, because
a pending Automation permission prompt makes osascript hang indefinitely.

## Alternatives considered

- Keep the pill session-only — less discoverable; rejected but preserved as a
  settings toggle.
- A separate activating Spotlight-like window for typing — would steal focus
  from the target app, breaking the paste-target invariant.
- A global text-input hotkey instead of click — the nub doubles as a status
  affordance.

## Consequences

**Good**

- A persistent entry point, and a keyboard path to the whole command system
  for free; the user's frontmost app never deactivates.

**Bad**

- The panel's focus model became stateful and subtle (allowsKey, first-mouse,
  resign-key interactions).
- An always-on screen-edge window can collide with app UI, mitigated by
  shrinking the idle hover zone.

Evidence: commit 407d1dc (`Sources/zeldaFlow/UI/PillPanel.swift`,
`AppKitTextField.swift`, `scripts/install.sh`).
