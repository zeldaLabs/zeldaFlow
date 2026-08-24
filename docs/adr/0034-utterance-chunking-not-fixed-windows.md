# 34. Meeting audio is cut at pauses, not every 5 seconds

**Status**: Accepted
**Date**: 2026-08-09

## Context

The first real multi-minute call through the notetaker produced a transcript
the user described as "single lines always, and not the exact words I said."
The stored transcript showed exactly why — every segment was 5.0 s long,
contiguous, on both channels:

```
them  34.9- 39.9 (5.0s) | Then comments say,
them  39.9- 44.9 (5.0s) | The prices relate everything to the total sales value, all confidence to
them  44.9- 49.9 (5.0s) | So, you can see that there is a meeting conversation,
them 124.9-129.9 (5.0s) | Grass profit and net profit.
```

Three distinct failures, one cause:

1. **Words at every boundary were mangled or lost.** A blind cut every 5 s
   lands mid-word roughly whenever someone is talking. "sum" became "sam",
   "gross profit" became "Grass profit", sentences ended mid-clause.
2. **Only about half the speech survived.** 279 words over 210 s of
   near-continuous far-side speech is ~80 wpm against a natural ~150 wpm.
   Nothing dropped the *audio* — every 5 s window was transcribed — but each
   isolated window gave back a fragment of what it contained.
3. **The decode prompt was recited as speech.** "meeting conversation"
   appears four times in the transcript; it is verbatim from
   `meetingSystemPrompt` ("This is a meeting conversation, carefully
   punctuated."), which `carry_initial_prompt` pushes into *every* decode
   window. On a low-information 5 s window, reciting the prompt is the
   likeliest continuation.

The contrast that named the fix: the app's dictation path transcribes the
same user accurately, and it differs in exactly one way — it decodes a whole
utterance bounded by silence, once.

## Decision

**Cut at pauses; never at a clock.**

- A tick (now every 1 s) no longer produces a chunk. It *asks* whether the
  buffer ends somewhere sensible: at least `minUtteranceSeconds` (8 s) of
  audio, then cut inside the first pause of `pauseSeconds` (0.45 s below
  `pauseRMS` 0.006, measured on 20 ms frames). Boundaries land in silence,
  so no word straddles a decode.
- A talker who never pauses is force-cut at `maxUtteranceSeconds` (24 s, well
  inside whisper's 30 s window) **on the quietest frame in the preceding
  second** — worst case a syllable, not a guaranteed mid-word slice.
- **The far side gets no prompt at all.** Nothing carried, nothing to recite.
  Whole utterances punctuate themselves; the steering string was buying
  punctuation at the cost of inventing sentences. The user's own channel
  keeps its glossary prompt (names and jargon are worth it, and ADR 22's
  scrub is built for that channel).
- **Gates measure the loudest second, not the whole-chunk average.** This is
  a direct consequence of longer chunks: a 20 s utterance is mostly the
  silence around the words, so a whole-chunk RMS drags a real sentence under
  the silence and mic-bleed thresholds and deletes it. Every gate that can
  DROP audio now asks "was there a loud second in here?"
- **`risky` narrowed the same way.** Risky buys a 6 s holdback plus
  eligibility for retraction as echo. Over a 20 s window "the far side spoke
  at some point" is almost always true, so the old rule flagged *every* mic
  chunk (it did — every mic segment in the field transcript was risky). Now
  loud, close-mic speech (`clearlyUserRMS`) is never suspect; only
  quiet-and-overlapping is.

**A separate decode profile for meetings** (`WhisperEngine.Options`;
dictation keeps its exact shipped behavior):

- **Timestamps on, one emission per whisper span.** With `no_timestamps`
  the whole window collapses to a single segment, so an early end-of-text
  silently discards the rest of the decode, and the `no_speech_prob` filter
  becomes an all-or-nothing kill switch — under 24 s utterances that would
  throw away a whole minute-fragment of a call on one bad reading, strictly
  worse than the 5 s it discarded before. Spans also give the transcript
  real sentence times instead of scheduler grid cells, which is what
  diarization (ADR 31) and the notes map-reduce actually want. Span times
  are clamped into the window; an eval pins that they land on the source
  timeline even with the Silero pre-filter active.
- **Temperature fallback on** (`temperature_inc` 0.2, `entropy_thold` 2.4,
  `logprob_thold` -1.0). This is whisper's only defence against repetition
  loops and low-confidence decodes; with it off, "I was going to go to the
  balance sheet and I was going to go to the balance sheet" is accepted and
  stored. Dictation still runs a single temperature for bounded latency; an
  unattended recording can afford the occasional re-decode.
- **`no_speech_prob` drop raised to 0.9** for meetings — with several spans
  per window a false positive now costs one sentence, not the window.

**Echo matching gained word boundaries.** `TranscriptMatcher` used raw
substring containment (the JS port's `includes()`) *before* its 3-token
floor, so "ok" matched inside "broken" and a short mic reply could be
deleted as far-side echo. Containment is now tested on whole-token runs.
Deleting the user's own words is the expensive direction of this trade.

## Alternatives considered

- **Overlapping fixed windows + dedup** (the classic streaming-Whisper
  trick): recovers boundary words but needs text-level overlap merging, and
  the app already has one text-dedup system (ADR 29) whose interaction with
  a second one is hard to reason about. Cutting in silence removes the
  problem instead of compensating for it.
- **Carrying the previous chunk's text as the next chunk's prompt**
  (condition-on-previous-text): standard, and improves continuity — but this
  session is fixing a prompt-recitation bug, and that technique feeds model
  output back in as prompt. Not while the far side is unprompted.
- **Keeping 5 s for latency**: the live transcript now lags by an utterance
  (10-25 s) instead of 5 s. For a notetaker whose product is the transcript
  after the meeting, correct words later beat wrong words sooner.

## Consequences

- **Good**: segments are utterance-shaped, which is what a reader wants and
  what the notes map-reduce wants; boundaries stop eating words; the prompt
  can no longer appear as dialogue; a real sentence inside a mostly-quiet
  window can no longer be gated away.
- **Bad**: the live transcript updates every 10-25 s, not every 5 s. A long
  monologue still gets a hard cut at 24 s.
- **Bad**: temperature fallback makes worst-case decode latency unbounded in
  principle (up to 5 re-decodes of one window). The meeting path already
  runs ~10 s behind realtime and yields to dictation, so it absorbs this;
  dictation is deliberately untouched.
- The transcript VIEW re-merges a speaker's consecutive sentences into
  paragraphs (the exporter's 2 s rule), so sentence-level spans in storage
  do not read as a wall of one-line bubbles.
- **Measured**: on a 49 s speech fixture the same audio through the same
  whisper produced 10 chunks / 146 words the old way and 3 chunks / 147 words
  the new way — word parity on clean audio, with correct sentence
  punctuation and paragraph-shaped segments. Synthetic speech cannot
  reproduce the field word-loss (it has no disfluencies, overlap, or codec
  damage), so the word-recovery claim rests on the mechanism and on the next
  real call. `--evalmeeting` pins the A/B (`ZF_SPEECH_FIXTURE`) so it can
  only improve from here.

Evidence: `Sources/zeldaFlow/Meeting/MeetingTranscriber.swift`
(`utteranceCut`, `loudestWindowRMS`, `decodePrompt`),
`Sources/zeldaFlow/Support/MeetingEvals.swift` (`chunkingSection`,
`liveChunkingABSection`).
