# 24. Multi-step tasks: the loop builds the options, the model only points

Status: Accepted
Date: 2026-07-30

## Context

One sentence, one action was the command-mode contract. "Download Slack
from the App Store" opened the App Store and stopped; finishing the task
needs observe → act → observe again until done. The planner available is
the local Gemma behind llama-server (ADR 2) in a 4096-token context.

The design was settled by measuring that model, not by taste:

- Asked to *generate* the next step freely, it scored **3/6** on realistic
  screens: it invented labels that weren't on screen, and when its
  chain-of-thought ran long it returned empty content — a higher token
  budget just bought longer reasoning and the same wrong answer.
  (`enable_thinking: false` does not suppress reasoning on this build; the
  comment claiming so was wrong and is corrected.)
- Given a numbered list of real options under a `json_schema`
  `{"n": integer}`, it scored **4/6** and never chose out of range in 20
  trials.
- **Pruning flipped wrong answers to right ones**: withholding the field
  that already held the typed text and the link echoing the window title
  moved "click Slack" (wrong) to "click Get" (right) at half the tokens.
- Asked whether the task was *finished* — offered exactly `wait` and
  `done` on a visibly complete screen — it chose `wait`. Every time.

## Decision

`TaskRunner` is a sense–act loop in which the LLM is a ranker of last
resort and every safety property lives in code:

- **`TaskCandidates`** builds the option list each iteration from the live
  observation (ADR 23 primitives), pruned by a `TrialLedger`: steps that
  succeeded or failed twice are withheld, as are window-title echoes and
  already-filled fields. One transition is sequenced outright — after
  typing into a field, the only offers are "press return" and "wait" —
  because measured free choice after typing went clicking around the UI.
- **`CleanupService.selectStep`** asks the model for an index under a
  strict JSON schema; `fieldText` extracts what to type (measured 6/6)
  in a second constrained call. Both prompts are constants so the
  llama-server prompt cache holds (~370/375 tokens cached per step).
- **Completion is decided deterministically, never asked**: a gated action
  (Get/Buy/…) succeeding after its Fn-tap *is* the task; so is running the
  menu command the goal itself names (top `UIMatcher` score ≥ 55).
- **Termination is unconditional**: 12 steps, 150 s, three identical
  screen fingerprints, or an empty candidate list — whichever first. Every
  step re-binds to the observed app's bundle ID, so the user taking over
  mid-task makes the loop refuse, not click. Esc cancels between any two
  steps. The gates of ADR 17/23 apply unchanged mid-loop.
- Entry is deliberately reluctant (`TaskIntent`): a task verb plus words
  beyond the app name. "Open the App Store" stays one-shot; running a loop
  nobody asked for is the worse error.

## Alternatives considered

- **Free-form step generation** — measured 3/6 with empty-content failures;
  rejected on data.
- **Plan-then-execute** (whole plan up front, replan on divergence) —
  fewer LLM calls, but the plan goes stale against live UI and the same
  model wrote the plan; per-step selection re-grounds every step.
- **Ask the model for `done`** — measured: it cannot; deterministic
  completion or a loop that never ends.
- **Cloud model for planning** — capability would rise, but dictation and
  command interpretation are local by principle (ADR 1/2, ADR 17's bounded
  exceptions); a task loop that phones home per step is a different app.

## Consequences

**Good**

- Verified end to end on this Mac: App Store task reaches the Get button
  and stops at the gate in 4.2 s; "check for new mail" completes in two
  steps; "make a new note" in one.
- With pruning, live selection measured 3/3 on the eval scenarios (up from
  3/6 free-form); a planner outage degrades to a refused step, never a
  wrong click.

**Bad**

- The loop reports what it *did*, not what happened afterwards — "clicked
  Get" does not claim the download finished; observing outcomes is future
  work.
- `maxSteps 12 / 150 s` caps real but long tasks; the ceiling is honest
  rather than generous.
- Goal-match completion inherits `UIMatcher`'s scoring; a menu item that
  merely shares words with the goal could end a task early. The ≥ 55 floor
  plus top-rank requirement is the current guard.

Evidence: `Sources/zeldaFlow/Task/TaskRunner.swift`, `TaskCandidates.swift`,
`TaskObservation.swift`, `TaskIntent.swift`,
`Sources/zeldaFlow/Cleanup/CleanupService.swift` (`selectStep`,
`fieldText`); measurements against the live llama-server 2026-07-30;
`--evaltask` pins intent, pruning, gates and termination without the model,
`--runtask "<goal>"` drives a real task with confirmations auto-declined.
Extends ADR 2, 6, 7, 17, 23.
