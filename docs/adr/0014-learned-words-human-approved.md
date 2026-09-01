# 14. Learned-words dictionary: auto-suggest, human-approve, never interrupt

Status: Accepted, amended by [ADR 0037](0037-correction-detection-learns-the-dictionary.md)
Date: 2026-07-19

## Context

The user's recurring proper nouns and technical terms should improve
recognition over time, but auto-adding misheard words to the Whisper bias
prompt would compound errors — and dictation flow must never be interrupted.

## Decision

`LearnedWords` watches final transcripts for distinctive candidates
(camelCase tokens, mid-sentence capitalized words, 4–30 chars) and counts
recurrences per session. Only words seen ≥ 2 times surface — as up to 8
approvable suggestions in the Hub's Dictionary page; the component "never
interrupts the pill." Approving moves a word into
`AppSettings.dictionaryWords` (the Whisper prompt); dismissal is remembered
case-insensitively forever. State persists to `learned-words.json` with
atomic writes.

## Alternatives considered

- Auto-adding recurring words without approval — risks poisoning the bias
  prompt with recurring mishearings.
- Inline "add this word?" prompts in the pill — rejected explicitly; the pill
  stays uninterruptible.
- A manual-only dictionary — misses the words the user doesn't realize are
  being fumbled.

## Consequences

**Good**

- The dictionary improves with use while a human gates every entry —
  consistent with the app-wide approval-gate philosophy; dismissals are
  permanent, so suggestions don't nag.

**Bad**

- Cold start requires repeated use before suggestions appear.
- Counts accumulate unbounded in the JSON.
- The capitalization heuristics are English-centric.

Evidence: commit 395d513 (`Sources/zeldaFlow/Support/LearnedWords.swift` header
comment, `candidates()` heuristics, `refresh()` thresholds).
