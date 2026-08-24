# 36. Answers become a clickable pill that expands into a chat note

**Status**: Accepted
**Date**: 2026-08-11

## Context

Asking the pill a question already worked end-to-end: `analyze_screen`
screenshots the display and asks the Claude Code CLI, `web_answer` answers
math/facts with local Gemma. But both rendered as a `.notice` — a transient,
click-through message that truncates at four lines and auto-fades on a
read-time heuristic. A long screen analysis was gone before it was read, and
there was no way to ask a follow-up without starting the whole command over
(and, for screen questions, re-capturing a screen that had since changed).

Constraints:

1. **The pill is a non-activating panel.** Whatever surface shows the
   conversation must not activate zeldaFlow or steal the user's app focus —
   the type bar's `allowsKey` dance (Spotlight behavior) is the only
   sanctioned way to take the keyboard.
2. **`PillController.layout` is a pure pinned table.** Every new phase is a
   row in that table, pinned by PillEvals, and every meeting-driven row must
   keep `.keep` placement (ADR 0018/0025).
3. **Two brains, one seam.** First answers come from either the CLI bridge or
   Gemma; follow-ups need a backend even when the CLI is busy with a
   background task (it is deliberately one-process-at-a-time) or missing.
4. **The original screenshot is gone by design** — captures never outlive
   their analysis (privacy rule in `ScreenCapture`).

## Decision

Two new `AppState` phases, both plain rows in the layout table:

- **`.answer(String)`** — renders and times out exactly like a notice; the
  only difference is `clickable: true`, so tapping the answer while it's up
  expands it. No hint, no special duration (rejected in review: the pill
  should just be clickable when an answer is there).
  Only outcomes that are *answers* get it: an ok outcome whose action is in
  `conversationalActions` (`analyze_screen`, `web_answer`) **and** that
  carries a `payload`. Status messages ("🔍 Searching…") stay notices.
- **`.chat`** — the pill grown into a 640×460 rounded-rect note: the thread,
  thinking dots, and an `AppKitTextField` composer. It takes key exactly like
  the type bar (`allowsKey`), mirrors to the hotkey monitor as
  `typeBarOpen` so Esc is swallowed and routed to `closeChat()`, and closes
  on click-away via the same `didResignKey` sink. It is excluded from
  `scheduleReset` — an open note is the user's to close.

Assistant turns render as real markdown through the same `MarkdownRenderer`
the meeting notes use (white-ink themed variant). SwiftUI `Text` ignores
AppKit attributes and `AttributedTextView` is an `NSScrollView` (a scroll
inside the thread's scroll is wrong), so each turn is a bare self-sizing
`NSTextView` whose height comes from `boundingRect` at the note's fixed
column width. The one-glance answer pill styles inline markdown only
(Foundation's `inlineOnlyPreservingWhitespace` parser) — block layout
belongs to the note.

The thread lives in `AppState.chatMessages` (user question + payload answer
seed it). Follow-ups render the last 12 turns as text and go to the Claude
CLI with **no tools** (`allowedTools: []` — the conversation is the only
context, so there is nothing to scope), falling back to a new
`CleanupService.chatReply` (single Gemma completion, history suffix-capped at
3000 chars for the 4k context) when the CLI is off, missing, or busy. A
`chatTurn` counter guards stale replies, mirroring `sessionGeneration`.

Follow-ups do **not** re-capture the screen. The first answer's text is the
record of what was on screen; the prompt tells the model to treat it as
accurate notes and to ask for a fresh look if one is needed. Re-capturing
silently would photograph a screen the user may have since changed — a new
capture should always be a new explicit command.

## Consequences

- Answers survive long enough to be read, and follow-ups keep their context —
  including screen questions, without keeping screenshots around.
- Chat replies join `lastInsertedText` and history (`💬` rows), so "Paste
  Last Transcript" works on them like every other long-form result.
- The clickable 560×120 answer pill swallows clicks in its transparent
  margins while it's up (same tradeoff the banner row already makes), and a
  short answer gives only a brief click window — acceptable: short answers
  rarely need follow-ups, and the question can be re-asked.
- A dangling chat reply can hold the one-at-a-time CLI slot for up to 90 s
  after the note closes; the reply is dropped by the turn guard, and the
  Gemma fallback covers a queued background task meanwhile.
- PillEvals pins both rows and includes the new phases in the exhaustive
  "meeting rows never move" sweep (now 256 rows).
