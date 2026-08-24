# 23. Control any app through what it declares, never through coordinates

Status: Accepted
Date: 2026-07-30

## Context

Command mode could only do what it had a template for: a fast-path rule or a
prompt example per capability. "Bold this" worked nowhere unless someone had
written a bold rule; "export as PDF", "split the editor", "click Get" worked
nowhere at all. Scaling that by hand is a template zoo, and the project's
goal is an app that can drive *any* Mac app — the user's phrase for it was
"the open claw of the Mac".

macOS already publishes the necessary API. Every app's menu bar is its full
command set, exposed through Accessibility; every window's buttons and text
fields are enumerable the same way. Nothing needs to be scripted per app.

## Decision

Three layers, all reading the app's own declarations through AX:

- **`UIScout`** walks the frontmost app's menu bar into `MenuCommand` paths
  (bounded: 0.25 s per element, 1.2 s budget, 400 commands, depth 4 — the
  ADR 19 discipline). **`UIControls`** enumerates the focused window's
  buttons, fields, checkboxes and links, with per-label ordinals so
  duplicates stay addressable.
- **`UIMatcher`** scores spoken words against commands deterministically.
  A confident match is pressed without the LLM (ADR 6 order); an ambiguous
  one sends a shortlist into the command prompt, so the model chooses from
  commands that provably exist rather than inventing one (ADR 7).
- **`UIActions`** executes: re-read the live tree, resolve, then
  `AXUIElementPerformAction(.press)` or `AXUIElementSetAttributeValue` for
  fields — plus `press_key` for the closed set of navigation keys (Return,
  Tab, Escape, arrows) that no menu or button covers. Every action is bound
  to the app that was frontmost when the user spoke
  (`CommandContext.expectedFrontmost`); focus moving mid-command refuses
  rather than clicking into whatever window arrived. Files get the same
  treatment in `FileActions`: spoken places under `~` only, deletes go to
  the Trash, and the confirmation shows the *resolved* path — the only
  place a misheard filename is visible before it moves.

The safety rule throughout: the model selects from elements the app
declared; nothing synthesizes coordinates, and gates key off the *label*
("Get", "Buy", "Delete…") so a model that forgets to mark a click risky
cannot skip confirmation.

## Alternatives considered

- **Template per app** (AppleScript/URL schemes per target) — what this
  replaces; unbounded maintenance and always behind.
- **Vision + synthetic clicks at coordinates** — works on anything visible,
  but a moved window mis-clicks, it needs screen recording permission, and
  a model inventing coordinates is exactly the blast radius ADR 7 exists to
  prevent.
- **AppleScript dictionaries** — richer where they exist, but most apps
  ship none, and the menu bar is universal.

## Consequences

**Good**

- Measured on this machine: 444/444 enabled menu commands across 10 running
  apps (Safari 416 commands, Mail 306, Preview 238…) resolve by their own
  name, no per-app code.
- Disabled commands are refused, destructive ones and spend-money buttons
  are Fn-gated, and the matcher prefers an enabled duplicate over a
  greyed-out one (a real Calendar bug the breadth eval caught).

**Bad**

- Menu- and control-less surfaces (web page content, canvas apps) stay out
  of reach; Electron apps sometimes accept an AX value write and silently
  revert it.
- The label-based purchase gate is an English word list ("get", "buy",
  "install"…); other localisations need their own entries.
- Reading state *back* (unread counts, download progress) is not covered —
  acting is, observing is only what ADR 24's loop snapshots.

Evidence: `Sources/zeldaFlow/Command/UIScout.swift`, `UIControls.swift`,
`UIMatcher.swift`, `Actions+UI.swift`, `Actions+Files.swift`; verified live
by `--evalui` (menus, clicks, typing, gates, focus guard, breadth +
self-match sweep) and `--evalfiles` (path refusals, Trash-only deletes).
Extends ADR 6, 7, 13, 19.
