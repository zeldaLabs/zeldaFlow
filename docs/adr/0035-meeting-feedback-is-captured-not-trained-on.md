# 35. Meeting feedback is captured, not trained on

**Status**: Accepted
**Date**: 2026-08-10

## Context

After the ADR 34 accuracy work the user asked for a thumbs up / thumbs down
on meeting output that would "automatically retrain" the system, so it
improves as more meetings are recorded.

The honest engineering answer is that the retraining half is not available
to this app:

- **Whisper cannot be fine-tuned here.** It needs GPU-hours and thousands of
  labeled audio/text pairs. zeldaFlow deliberately **deletes the meeting
  audio** once the transcript is finalized (ADR 27's privacy stance), so the
  training input does not survive the meeting that produced it.
- **A thumb carries one bit.** "This was bad" does not say which word was
  wrong, which is the information a decoder would need. Feedback that
  improves recognition has to be *specific* (a correction), not *scalar*.
- **Fine-tuning Gemma locally** (LoRA) is technically possible but needs a
  training stack the app does not have, many examples, and risks degrading a
  model whose output is already grammar-constrained.

Shipping a thumb wired to nothing while claiming self-improvement would be
theatre. Shipping a thumb that honestly records a verdict is not.

## Decision

Capture the verdict; make no claim beyond that.

- `MeetingRating` (`up` / `down`) is recorded per meeting for the two
  artefacts the user actually reads: the transcript and the notes. Both live
  in `meta.json` as optionals (`transcriptRating`, `notesRating`, plus the
  times), so absent means "never answered" — that is what drives the ask.
- **The ask appears when the meeting is opened** and only while unrated: a
  one-line bar above the transcript ("Was this transcript accurate?") and
  above the notes ("Were these notes useful?"). Rating it dismisses it.
- **Thumbs also live in both toolbars, permanently**, so a verdict can be
  seen and changed later. Pressing the thumb you already gave clears it — a
  rating you cannot take back is a rating people stop giving.
- **The transcript ask is withheld while a meeting is live.** Asking whether
  a transcript is accurate while it is still being written asks about
  something that does not exist yet.

What the stored ratings are FOR, today: they mark which meetings were bad,
which is exactly the corpus needed to make quality work measurable — a
thumbs-down meeting is a regression fixture with the user's own audio
characteristics behind it. That is the honest path from feedback to
improvement, and it runs through releases, not through a training loop.

## Alternatives considered

- **Corrections → learned vocabulary** (edit a wrong word, remember the
  term, bias future decodes; ADR 14's approved-dictionary machinery already
  exists): the genuinely compounding loop, and the one that would attack
  "not the exact words" directly. Offered and explicitly deferred by the
  user in favour of plain thumbs.
- **Speaker voice memory** (name once, recognised in later meetings via the
  embeddings the diarizer already returns): also offered, also deferred.
- **Thumbs-down → standing style instructions for the notes model**:
  prompt-level "learning" that works without training. Deferred with the
  rest; the storage shape here does not preclude it.

## Consequences

- **Good**: the user can register a verdict in one click, on both artefacts,
  without being lied to about what happens next. The data accumulates
  locally in a shape any future loop can consume.
- **Bad**: nothing improves *automatically* from a rating today. This is
  stated plainly rather than implied away.
- The fields are optional and additive, so old `meta.json` decodes
  unchanged and `schemaVersion` stays 1.

Evidence: `Sources/zeldaFlow/Meeting/MeetingModels.swift` (`MeetingRating`),
`Sources/zeldaFlow/UI/MeetingDetailView.swift` (`ratingAsk`, `rateTranscript`,
`rateNotes`), `Support/MeetingEvals.swift` (round-trip pins).
