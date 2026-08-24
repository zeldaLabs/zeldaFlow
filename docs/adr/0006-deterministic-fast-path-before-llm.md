# 6. Deterministic fast-path parser runs before the LLM for voice commands

Status: Accepted
Date: 2026-07-19

## Context

A 2B-class local model can mangle proper nouns and substitute entities;
common commands ("open Safari", "play X by Y", "navigate to Z") don't need a
model at all.

## Decision

`CommandFastPath` is a hand-written parser tried before the LLM: it strips
wake words and courtesy fluff, then matches single-intent patterns (open /
search / play / volume / edit / navigate). Its header states the rationale:
whatever it recognizes "is built from the user's exact words, so a small
model can never substitute Google Chrome for Safari or drop an artist name.
Returns nil for anything it isn't sure about — the LLM stays the fallback."
Multi-intent utterances containing " and " / " then " are deliberately punted
to the LLM; questions are routed whole to web search.

## Alternatives considered

- LLM-only interpretation — simpler, but risks entity substitution and adds
  seconds of latency to trivial commands.
- Grammar/intent frameworks (App Intents, custom grammars) — heavier, and the
  LLM already covers the long tail.
- Having the fast path handle multi-intent chaining too — rejected;
  conjunction splitting is exactly where naive parsing goes wrong.

## Consequences

**Good**

- Instant, deterministic execution of the common cases with zero
  hallucination risk; LLM cost is paid only for genuinely open-ended
  phrasing.
- The behavior is pinned by an eval harness (`--evalcommands`), which today
  holds 23 assertions.

**Bad**

- A growing list of hand-maintained English-only phrasings, with ordering
  subtleties — navigate had to be inserted before question routing so "how do
  I get to X" navigates instead of googling.

Evidence: commit 0377f77 (`Sources/zeldaFlow/Command/CommandFastPath.swift`
header comment); ordering consequence visible in commit df52e0b.
