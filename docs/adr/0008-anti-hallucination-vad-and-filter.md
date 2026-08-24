# 8. Anti-hallucination stack: Silero VAD pre-filter plus a layered text scrubber

Status: Accepted
Date: 2026-07-19 (VAD); text filter added in the working tree by 2026-07-28

## Context

Whisper was trained on YouTube captions, so on silence or background music it
emits "Thank you for watching", subtitle credits, and `[Music]` tags — worst
in the live preview, which decodes partial audio.

## Decision

Three layers:

1. A Silero VAD pre-filter so "the decoder never sees silence, which is the
   single biggest fix for Thank-you-style hallucinations," plus
   `suppress_nst` and dropping segments with `no_speech_prob > 0.75`.
2. A `HallucinationFilter` that scrubs caption junk with deliberately
   asymmetric strictness: aggressive whole-utterance drops for the
   display-only preview, but only "strings that never occur in real
   dictation" (amara.org, Korean/Japanese caption credits) dropped from the
   final transcript — because "a false drop is silent data loss."
3. A prompt-echo filter so the decoder repeating its own glossary prompt
   never reaches the preview.

Sentences are re-split with delimiters preserved so filtered text reassembles
byte-identical.

## Alternatives considered

- VAD only — leaks junk into the partial-audio preview.
- One blocklist for both preview and final — rejected; a user can genuinely
  dictate "thank you," so symmetric filtering silently eats real words.
- Higher no-speech thresholds or energy gating alone — insufficient against
  caption-credit hallucinations over music.

## Consequences

**Good**

- Kills the "phantom song credits while dictating" class of bugs end-to-end
  while making silent data loss in final text nearly impossible by design.

**Bad**

- Curated junk lists need maintenance across languages; the preview can
  briefly show nothing (mitigated by keeping previous words on screen); the
  layered pipeline adds testing surface.

Evidence: commit 0377f77 (`WhisperEngine.swift` VAD comment and no-speech
segment drop); working tree: `Sources/zeldaFlow/STT/HallucinationFilter.swift`.
