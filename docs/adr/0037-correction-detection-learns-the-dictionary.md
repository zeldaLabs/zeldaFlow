# 37. Correction detection learns the dictionary

Status: Accepted (amends [ADR 0014](0014-learned-words-human-approved.md))
Date: 2026-09-02

## Context

ADR 0014 rejected "add this word?" pill prompts by name, and it was right to:
its suggestion source was recurrence counting, where the evidence is "a word
appeared twice" — indistinguishable from a recurring mishearing, so an
interruption bought nothing a Hub list didn't. But there is a categorically
stronger signal available: the user retyping a word seconds after dictation
inserted it wrong. That is ground truth — the exact spelling, typed in
context, at the moment the error is most salient. Wispr Flow built its
vocabulary loop on exactly this signal.

The engineering obstacle was detection. The app has no standing AX observers
and no clipboard monitor anywhere, deliberately (ADR 0019 bounds every AX
read because AX calls block in mach IPC; ADR 0028 keeps the event tap scoped
to the dictation key).

## Decision

**Detection: two bounded one-shot probes, everything fails closed.** After a
successful paste, `CorrectionWatcher` schedules reads of the focused text
element at +5 s and +12 s — two AX calls each (focused element, then its
value), on a dedicated queue with ScreenContext-style timeouts (0.25 s per
element). A probe refuses to run when the frontmost app changed, secure input
is active, the element is a secure field, or the value is empty/oversized;
the raw field text never leaves the probe queue — only a two-word candidate
does. There are no standing observers and no keystroke watching.

**Diff: anchor, align, qualify — or nothing.** `CorrectionDetector.detect`
locates the pasted span via 3-word anchors (the span is the privacy boundary:
text outside it is never compared), LCS-aligns the words, and accepts only
1→1 substitutions that pass a similarity gate (case-only changes; same first
letter within a generous edit distance; different first letter only for a
tiny edit on a longer word — "sindy" → "Cindy"). Rewrites, ambiguity, missing
anchors, content edits all yield nil.

**Prompt: idle-only, click-optional, auto-dismissing.** A candidate is always
recorded in the Hub's Dictionary page ("From your corrections"). The pill
shows `Learn "X"?` only from idle — never over a recording, chat note, or an
armed confirmation gate — and fades to the Hub after 8 s untouched. One click
approves; ignoring it costs nothing. ADR 0014's human-approval gate survives
intact: nothing enters the dictionary without a deliberate act, auto-add
stays rejected.

**Approval writes two things, guardedly.** The replacement rule
(`from → to`, whole-word, case-insensitive) always; the glossary word only
when distinctive (≥ 4 chars, not a common word). The Whisper prompt caps at
the 40 most recent dictionary words, because every prompt word widens
`HallucinationFilter`'s prompt-echo kill radius (5-char-prefix matching) —
the full list still reaches the Gemma cleanup pass and the replacement
engine, which scrub nothing. `--evaldictionary` pins the detector, the
guards, the cap, and the filter interaction in CI.

## Alternatives considered

- Standing `AXObserver` on the frontmost app — a persistent IPC liability
  against arbitrary apps; rejected.
- Watching ⌘Z/backspace via the event tap — turns a hotkey listener into a
  keylogger-shaped component; rejected.
- Auto-adding detected corrections — ADR 0014's poisoning argument still
  holds; a misdetected pair would compound forever.
- Clipboard monitoring for copied words — fires on activity that has nothing
  to do with dictation; deferred.

## Consequences

**Good**

- The dictionary now learns from the strongest evidence there is, at the
  moment it exists, with one click — while the never-interrupt principle
  survives in honest form (idle-only, optional, auto-fading).

**Bad**

- Dictations under 4 words can't anchor and are never checked (the frequency
  path still covers them).
- Apps with no AX value (some Electron/web surfaces) silently get nothing.
- Two probes only see corrections made within ~12 s of the paste.
- A 2→1 word merge ("cube con" → "KubeCon") is not detected in v1.

Evidence: `Sources/zeldaFlow/Support/CorrectionDetector.swift`,
`Support/LearnedWords.swift` correction records, `Support/DictionaryEvals.swift`,
`AppSettings.sttPrompt` glossary cap.
