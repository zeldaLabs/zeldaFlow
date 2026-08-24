# 12. Speak-to-Edit: rewrite the selection via clipboard round-trip and the local LLM

Status: Accepted
Date: 2026-07-19

## Context

Users want to say "make this shorter" / "fix grammar" / "translate this"
about text already on screen in any app — still fully on-device.

## Decision

`EditActions` copies the current selection with a synthetic Cmd-C (polling
pasteboard `changeCount` for up to 1 s), sends it with the spoken instruction
to `CleanupService.rewrite` on the local Gemma server, and pastes the result
back over the selection via the standard `TextInserter` path. Guardrails: a
12,000-char selection cap; explicit failure messages for no-selection,
LLM-unavailable, and no-change results; a rewrite identical to the selection
is treated as failure; and the copied selection is deliberately left as the
"previous" clipboard for the insert cycle's snapshot/restore. Triggered by
the same triple-tap command mode via the fast path's `parseEdit`.

## Alternatives considered

- Accessibility API to read/replace the selection in place — unreliable
  across Electron and terminals, unlike the paste trick that already worked.
- A dedicated edit window or preview-and-approve UI — heavier flow; direct
  in-place replacement chosen.
- Cloud LLM for higher rewrite quality — violates the local constraint.

## Consequences

**Good**

- System-wide text editing with zero per-app integration, reusing existing
  insertion machinery and the local model.

**Bad**

- A destructive replace with no built-in undo of its own (relies on the
  target app's undo).
- Clipboard-timing heuristics inherit the paste path's raciness.
- Quality is limited by Gemma E2B, and Cmd-C interception fails in
  secure-input contexts.

Evidence: commit 395d513 (`Sources/zeldaFlow/Command/Actions+Edit.swift`,
`TextInserter.copySelection`, `CommandFastPath.parseEdit`).
