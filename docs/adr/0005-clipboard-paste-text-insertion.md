# 5. Text insertion by clipboard save/restore + synthetic Cmd-V, not keystrokes

Status: Accepted
Date: 2026-07-19

## Context

Transcribed text must land at the cursor of whatever app is frontmost —
native, Electron, terminals — reliably and fast.

## Decision

`TextInserter` snapshots the pasteboard, writes the text (marked with
nspasteboard.org's `org.nspasteboard.TransientType` so clipboard managers
skip it), waits 0.12 s for slow Electron apps, posts a synthetic Cmd-V, then
restores the previous clipboard after 0.6 s only if `changeCount` is
unchanged. Guards: if focus moved to a different app since dictation started,
or secure input (a password field) is active, the text is left on the
clipboard with an explanatory pill message instead of pasting blind.
Markdown-looking text is additionally rendered to RTF/HTML flavors so rich
editors paste real formatting.

## Alternatives considered

- Per-character CGEvent keystroke synthesis — slow for long text, breaks with
  non-ASCII/IME; the code comment notes paste is "the approach every shipping
  dictation tool uses (Wispr Flow, VoiceInk, Hex)".
- Accessibility API (`AXUIElement` setValue) — unsupported or broken in many
  apps, especially Electron and terminals.
- Leaving text on the clipboard always — worse UX for the common case.

## Consequences

**Good**

- Uniform behavior across app types; the previous clipboard is almost always
  restored; secure-input and focus-change cases degrade gracefully.

**Bad**

- Inherently racy: fixed sleeps and `changeCount` heuristics.
- Briefly clobbers the user's clipboard.
- Requires Accessibility for the synthetic keystroke.
- The original synchronous implementation blocked the main thread during
  every paste — the same thread that services the Fn event tap — which later
  forced the fully async rewrite in
  [ADR 20](0020-fully-async-text-insertion.md).

Evidence: commit 0377f77 (`Sources/zeldaFlow/Insert/TextInserter.swift`,
`Sources/zeldaFlow/Insert/MarkdownRenderer.swift`).
