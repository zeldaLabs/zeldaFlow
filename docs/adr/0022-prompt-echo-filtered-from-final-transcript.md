# 22. Filter prompt echo from the final transcript, not just the preview

Status: Accepted
Date: 2026-07-28

## Context

zeldaFlow biases Whisper by injecting an initial prompt containing the user's
dictionary and the terms currently visible on screen — literally
`"… Glossary: <dictionary words>."` (`AppSettings.whisperPrompt`) plus
`"On-screen terms: …"` (`AppState.contextualPrompt`). Whisper is known to
recite its own initial prompt when it cannot find speech, which is why
`dropPromptEcho` was added in ADR 8 — but it was wired only into
`scrubPreview`, and its doc comment said "Preview-only". The final
transcript, the text that actually reaches the user's clipboard, went
through `scrubFinal`, which dropped nothing but foreign-caption boilerplate.

A noise-robustness sweep made the consequence concrete. Under babble
interference at −5 dB SNR the decoder returned:

```
Glossary, Manushresth Krishnan, Manushresth Krishnan, Manushresth Krishnan, …
```

In a loud room, zeldaFlow would have pasted the user's own dictionary — and
their name — into whatever document they were dictating into. That is a
privacy defect, not merely a quality one: the leaked content is personal
data the user gave the app for a different purpose.

The reason the protection was preview-only is sound and still applies: a
false drop in the preview costs nothing (it is redrawn 6× a second), while a
false drop in the final transcript is silent data loss. So the fix could not
simply reuse the preview's aggressive rule, which drops any sentence merely
*starting* with "glossary" — someone dictating "Glossary: API, SDK, REST"
into documentation would lose the line.

## Decision

`scrubFinal` now takes the prompt that produced the transcript and drops a
sentence only when it is unmistakably the app's own prompt coming back:

1. a long verbatim run of the prompt (≥ 25 normalized characters), or
2. a sentence leading with scaffolding zeldaFlow itself injected (`glossary`,
   `on screen terms`) **whose body repeats two or more words that came from
   that same prompt**.

Condition 2 is what makes the rule safe. A genuine dictated glossary
survives because its terms did not come from us; the hallucinated one is
caught because, by construction, every word in it did. With no prompt
supplied the function behaves exactly as before.

`--selftest` now applies `scrubFinal` and prints a `FILTERED:` line whenever
it changes the text, so the harness exercises the pipeline users actually
run rather than the raw decoder output.

## Alternatives considered

- **Reuse the preview rule verbatim** — drops legitimate dictation that
  happens to begin with "Glossary"; a false drop in the final text is
  invisible data loss.
- **Stop injecting the dictionary into the prompt** — removes the leak by
  removing the feature; the glossary is what makes names and jargon spell
  correctly (ADR 13).
- **Post-filter only when the transcript looks like a repetition loop** —
  catches this instance but not the general case, and the same sweep showed
  a separate non-prompt loop hallucination that carries no private data and
  should *not* be dropped.
- **Redact only the dictionary words, keeping the rest** — leaves mangled
  half-sentences that read as real dictation; dropping the whole echoed
  sentence is the honest failure.

## Consequences

**Good**

- The user's dictionary and name can no longer be pasted into a document by
  a hallucinating decoder.
- The failure is now honest: the pill says "Didn't catch that" instead of
  inserting plausible-looking private text.
- `--selftest` reflects production, so future noise work measures the real
  pipeline.

**Bad**

- `scrubFinal` is no longer purely subtractive-by-blocklist; it now depends
  on the caller passing the correct prompt, and a caller that forgets
  silently loses the protection.
- A user whose dictionary genuinely contains the words they are dictating in
  a "Glossary:"-led sentence could still lose that sentence. Judged
  acceptable: it requires the two-word overlap *and* the scaffolding lead-in.
- ~~Command mode (`finishCommandSession`) still does not scrub; an echo there
  fails to parse and surfaces as "Couldn't understand that command", which
  leaks nothing.~~ **Wrong — see the amendment below.**

Evidence: `Sources/zeldaFlow/STT/HallucinationFilter.swift`
(`isFinalPromptEcho`, `scrubFinal`), `Sources/zeldaFlow/AppState.swift`
(final-pass call site), `Sources/zeldaFlow/Support/SelfTest.swift`;
reproduced and verified 2026-07-28 with babble interference at −5 dB SNR via
`evals/noise-robustness.py`'s method. Extends ADR 8.

## Amendment, 2026-08-04: both "bad" consequences came true

Background noise during a command-mode session decoded as
`"Glossary, Manushresth."` and zeldaFlow ran a web search for it — three
times, logged. Both hedges above turned out to be the actual defect:

1. **"A caller that forgets silently loses the protection."** Command mode
   was that caller. The assumption that an unscrubbed echo "fails to parse
   and leaks nothing" was simply false: `"Glossary, Manushresth."` parses
   perfectly well as a search query, so instead of failing safe it *acted*.
   Command mode now runs `scrubFinal` with its own prompt and refuses an
   empty result, the same as dictation.
2. **The two-word overlap had a hole at one word.** `"glossary manushresth"`
   is our scaffold plus a single glossary term, so rule 2's "≥2 body words"
   never fired. Rule 2 now also matches a body made of *nothing but* prompt
   words, whatever its length. This is strictly more aggressive — every
   sentence dropped before is still dropped — and "Glossary: API, SDK, REST"
   still survives, because none of those words came from us.

The distinction the original record missed is that the two paths have
opposite failure costs. Dictation pastes text: a false drop is silent data
loss, so the filter must be conservative. Command mode *executes*: a false
drop costs one repeated sentence, a false accept performs an action. A
filter tuned for the first path was never going to be sufficient for the
second, and the fact that it was simply absent there made it moot.

Pinned by `--evalcommands`: "one-word glossary echo dropped", "a real
command survives", "a command naming a glossary word survives".
