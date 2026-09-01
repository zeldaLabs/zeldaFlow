# 38. Speaker-attributed notes with inferred names

Status: Accepted
Date: 2026-09-02

## Context

ADR 31 shipped diarization display-only and called speaker-aware notes "an
explicit v2"; ADR 30's owner grammar baked `You|Them|Unclear` in, and both
notes prompts said "Do NOT guess participant names." The result read like a
transcript digest — "them, them, you" — while tools like Gemini's meeting
notes name people, attribute decisions, and hand each action item to its
owner. The blockers were structural: the model never saw speaker identity
(`orderedTranscriptText()` emits only You/Them, and it is also the
`transcriptHash()` input — a hard staleness invariant), and nothing mapped
diarized clusters to human names.

## Decision

**A per-meeting roster, and a second LLM-facing transcript builder.**
`MeetingRoster` maps stable keys (`you`, `s0`, `s1`…, `s-1` for the
undiarized far side) to labels, resolving user rename ?? inferred name ??
default, de-colliding duplicates. `speakerTranscriptText(roster:)` emits
"Priya:/Speaker 2:" lines for the notes pipeline ONLY —
`orderedTranscriptText()` and `transcriptHash()` are byte-identical to
before, pinned by eval.

**Names are inferred from the transcript, evidence-gated.** One
schema-constrained Gemma call (after polish, before notes) reads the
transcript head plus vocative/self-intro lines and proposes {label, name,
evidence-quote}. Pure Swift then re-verifies every claim: name-shaped,
present verbatim in the transcript, evidence line present near-verbatim,
not conversation furniture, no duplicate assignment. Survivors land in
`meta.inferredSpeakerNames` — a SEPARATE field from `speakerNames`, so a
user rename always wins and re-inference can never clobber one. Ambiguity
keeps "Speaker N"; total failure changes nothing.

**The owner grammar becomes the roster.** `notesSchema(ownerLabels:)` emits
the meeting's actual labels + "Unclear" — still a grammar, so an uninvited
speaker stays unrepresentable. Prompts are per-meeting constants (roster
line last), keeping the llama-server KV cache paid across a run's dozen map
calls. Map bullets carry "**Topic** — point" lead-ins and due dates; the
"do NOT guess names" rule became "use ONLY these labels".

**notes.md becomes a render of notes.json.** The merged structured result
persists as a `NotesDocument` (owners as roster keys, plus the
generation-time roster). Renaming a speaker re-renders notes.md from it in
milliseconds — owner prefixes resolve by key, free-text mentions get a
word-boundary rewrite of the changed far-side label ("You" is never
free-text rewritten). Hand-edited notes are never clobbered: they get a
best-effort single-label text replacement instead. A rename does NOT mark
notes stale — `notesHash` keeps meaning "the words changed".

## Alternatives considered

- Placeholder tokens in notes.md, resolved at display — destroys ADR 32's
  raw-markdown editing legibility.
- Plain search-replace on rename — fails on "You", chains across renames,
  collides on repeated names.
- Full LLM regeneration on rename — 30-60 s for a label change.
- Seeding inferred names into `speakerNames` — re-inference could overwrite
  a human's correction.
- Calendar/attendee metadata as a name source — a network/permission
  surface the all-local story is better off without.

## Consequences

**Good**

- Notes name people, attribute decisions, and own action items
  (`- [ ] **Priya**: send the contract by Friday`); a rename fixes every
  mention in one click; old meetings gain names on Regenerate (inference
  runs first when `inferredSpeakerNames` is nil).

**Bad**

- A name never spoken is never inferred; a wrong-but-present name can be
  (the mitigation is the rename, which the feature makes global).
- The grammar guarantees a VALID owner, not a CORRECT one — "Unclear"
  remains the escape hatch.
- Edited notes get best-effort text replacement only.
- Pre-ADR-38 meetings have no notes.json; their rename propagation is a
  no-op until regenerated (their notes contain no names by construction).

Evidence: `Sources/zeldaFlow/Meeting/MeetingModels.swift` (MeetingRoster,
NotesDocument, speakerTranscriptText), `Meeting/SpeakerNameInferrer.swift`,
`Meeting/MeetingNotesGenerator.swift`, `MeetingCenter.rerenderNotes`,
`Support/MeetingEvals.swift` speakerNotesSection.
