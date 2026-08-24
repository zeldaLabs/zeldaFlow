# 7. LLM outputs structured JSON actions that fill AppleScript templates — never code

Status: Accepted
Date: 2026-07-19

## Context

Command mode must let a small local LLM control Mac apps (Music, Mail,
Messages, Reminders, Calendar, Notes) without giving a language model an
arbitrary-execution channel.

## Decision

The LLM returns only a JSON `{"actions":[...]}` array decoded into
`ZeldaFlowAction` — a flat bag of optional typed parameters whose doc comment
states "The LLM only fills these fields — it never produces executable
code." Execution goes through hand-written AppleScript templates run via
`/usr/bin/osascript` with scripts passed as argv ("no shell involved"),
values escaped via `AppleScriptRunner.quote`, and dates built with
locale-proof component assignment instead of AppleScript date-string parsing.
The JSON extractor tolerates small-model sloppiness: it slices the outermost
braces and salvages bare action objects or bare arrays when the wrapper is
dropped. Send-email/send-message actions are gated behind an explicit Fn-tap
confirmation (Esc cancels), and unresolvable email recipients open a visible
draft instead of sending blind.

## Alternatives considered

- Letting the LLM write AppleScript or shell commands — rejected outright as
  an injection/execution risk.
- llama.cpp grammar-constrained (GBNF) or strict JSON-schema decoding — not
  used; lenient parse-and-salvage chosen instead.
- Apple Shortcuts / App Intents as the execution layer — less coverage and
  harder to template from an LLM.
- Auto-sending messages without confirmation — rejected; the README frames it
  as "humans sit at the approval gates, not in the loop."

## Consequences

**Good**

- A hard capability boundary: the worst a hallucinating model can do is fill
  a wrong parameter into a benign template, and outbound comms still need a
  human Fn-tap.
- The schema is trivially testable — `--evalcommands` pins the grammar and
  the gates.

**Bad**

- Every new capability needs schema + prompt + executor + template wiring
  (commit df52e0b touched 5 files for one command).
- `ZeldaFlowAction` grows as a wide optional-field bag; TCC Automation prompts
  appear per controlled app.

Evidence: commit 0377f77 (`Sources/zeldaFlow/Command/ZeldaFlowAction.swift`,
`AppleScriptRunner.swift`, `CleanupService.interpretCommand`).
