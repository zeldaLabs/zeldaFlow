# 30. Meeting notes by local map-reduce in the 4,096-token context

Status: Accepted
Date: 2026-08-08

## Context

Notes are written by the same resident Gemma 4 E2B behind llama-server
that cleans dictation (ADR 2). Its context is 4,096 tokens, and the
measured usable input budget is **~4,500 chars** — past that llama-server
truncates *silently*, a failure mode found the hard way by the 12-minute
dictation stress test (PERFORMANCE.md). An hour of meeting is **45–60 k
chars** of "You:/Them:" transcript: an order of magnitude over budget.
The source project's single-shot notes prompt assumes a cloud model that
takes the whole transcript at once; here that is physically impossible.

A second constraint is the model itself. The house evidence on this exact
model (CleanupService, the task planner): free-form generation measured
**3/6** on realistic inputs — it invents labels, and when its
chain-of-thought runs long it returns empty content — while
schema-constrained selection scored **4/6 and never once fell out of
range in 20 trials**. A 2B model given format freedom will violate the
format; a 2B model filling a grammar cannot.

## Decision

**Map-reduce, with the model demoted to fact extraction.** The format is
never the model's to control.

- **Chunker** (pure Swift): greedy fill to **≤ 3,800 chars** — headroom
  for the ~1,000-char map prompt plus the 1,200-token reply inside the
  same 4,096-token window (the reply cap was 400 until 2026-09-01, when a
  real 34-minute meeting produced a chunk whose JSON needed 465 tokens:
  the capped reply truncated mid-array, failed decode, and — temperature
  0 being deterministic — failed the retry identically, failing the whole
  run) — never splitting a segment, and past 75 % of the
  budget (2,850 chars) preferring a **speaker-turn break**, so a question
  and its answer land in one chunk: a map call that sees only the
  question invents the answer's owner. 12–16 map calls per meeting hour.
- **Map**: one grammar-constrained JSON call per chunk — `summary`,
  `discussion[]`, `decisions[]`, `actions[{owner, text}]`, `followups[]`,
  with `owner` an **enum of "You" | "Them" | "Unclear"**: the tokens
  cannot form a fourth speaker, so the renderer never meets one. The map
  system prompt is a static constant with nothing interpolated (no
  "part N of M"), so llama's KV cache pays on every call (measured
  370/375 tokens cached on the planner's identical-prompt pattern).
- **Reduce, deterministically**: concatenate map outputs in chunk order
  and dedup near-identical bullets with the **same `TranscriptMatcher`
  that catches cross-channel echo** — cross-chunk repetition is the same
  problem, one fact worded almost alike twice. An action duplicate that
  knows its owner upgrades an "Unclear"; first wording wins.
- **Summary call**: the one place the model writes body prose — 1–2
  sentences over the N one-sentence chunk summaries, in order.
- **Conditional polish**: one consolidation pass *only when* the merged
  bullets fit the same 3,800-char budget the maps ran under. Past it,
  **skip polish and ship the deterministic merge** — degrade gracefully
  rather than truncate (the merge is complete, just less consolidated;
  llama-server would truncate silently). A polish that returns nothing
  usable for a non-empty draft is discarded for the merge, same spirit as
  cleanup's shrink sanity check.
- **Renderer** (pure Swift) assembles the markdown: opening summary, then
  `## Key Discussion Points` / `## Decisions Made` / `## Action Items`
  (as `- [ ]` checkboxes with You:/Them: prefixes) / `## Follow-ups`,
  empty sections omitted. The source's FORMAT RULES are enforced **by
  construction** — no preamble, no tables, no invented attendee list,
  because the model only ever supplied bullets.
- **Title**: the ported title prompt over the first 2,000 chars of the
  rendered notes (temperature 0.3, wrapping quotes stripped, 0 < len
  < 100 accepted); anything else falls back to a dated title rather than
  failing the run — the notes exist and the record is renameable.

**Queue policy: one call at a time, dictation first.** The llama-server
is dictation cleanup's too, and notes are the background job. Calls run
strictly sequentially; between calls the generator polls
`dictationActive` every 500 ms and pauses while true — a dictation
cleanup only ever waits behind the single in-flight call (≤ ~15 s worst,
input capped at 3,800 chars). Progress ("Writing notes… 7/17") updates
after every completed call.

**Failure is a visible state, never partial notes.** Each call retries
once; a second failure fails the *whole run* to a visible `.failed`
record state with the transcript intact and Retry available. Partial
notes that silently omit 20 minutes of a meeting are worse than an honest
failure — the transcript is already on disk either way.

**Staleness by hash.** SHA-256 of the ordered transcript is stored with
the notes (`notesHash`, plus timestamp and model name); a transcript that
changed since generation marks the notes stale, and Regenerate re-runs
the same pipeline.

## Alternatives considered

- **Single-shot over the whole transcript** — physically impossible in
  4,096 tokens, and the failure mode is silent truncation, the worst one
  available.
- **Let the model write the markdown** (the source's prompt, per chunk) —
  rejected on the measured 3/6-vs-4/6 house evidence; the grammar + the
  renderer remove the failure class instead of policing it.
- **A larger context** (`-c 8192`+) — KV memory and prompt-processing
  latency grow on the shared server whose dictation-cleanup latency is
  the product's second quality goal; the 4k context is a dictation-first
  choice (ADR 2) the notetaker adapts to rather than renegotiates.
- **Recursive multi-level reduce** — unnecessary: the merged bullets fit
  the polish budget for most meetings, and when they don't, skipping
  polish degrades more predictably than recursing.
- **A cloud model** — never (quality goal 1).

## Consequences

**Good**

- Notes for arbitrary meeting lengths in bounded memory and bounded
  per-call latency, on the model already resident.
- Format violations are structurally impossible; the chunker, merge,
  renderer, and JSON salvage are pure and pinned by `--evalmeeting`.
- Dictation keeps priority over the whole run, and a failed run leaves a
  visible, retryable state with nothing lost.

**Bad**

- 12–16 map calls plus 2–3 more per meeting hour: minutes of background
  wall time (visible as progress, and longer when dictation keeps
  pausing it).
- Each map sees only its chunk; a topic threaded across chunks is
  consolidated only if the polish pass runs — which is skipped exactly on
  the long meetings that need it most.
- The opening is a summary of summaries; per-chunk phrasing can flatten
  the arc of a long meeting.
- "Unclear" action owners survive when no chunk saw the attribution.
- The transcript hash is exact: any transcript change, however cosmetic,
  reads as stale.

Evidence: `Sources/zeldaFlow/Meeting/MeetingNotesGenerator.swift`
(budgets, prompts, schemas, chunker/merge/renderer),
`MeetingCenter.swift` (`generateNotes`, staleness meta),
`MeetingModels.swift` (`transcriptHash`);
`Sources/zeldaFlow/Cleanup/CleanupService.swift` (`structured`, the
~4,500-char measured budget, the 3/6-vs-4/6 selectStep evidence,
KV-cache numbers). Extends ADR 2 and ADR 7 — "the model fills structure,
never writes the artifact" is the same doctrine; transcript production is
ADR 29.
