# 15. Cinematic per-user onboarding; personal seed data removed for release

Status: Accepted
Date: 2026-07-19

## Context

First launch must walk through the Microphone and Accessibility grants. The
original static checklist window contained the developer's own name
hard-coded in the default dictionary — unacceptable for a public release —
and the product wanted a branded first impression.

## Decision

Replace the static onboarding view with `OnboardingCinematic`: a 711-line
animated flow (night-sky arrival, name "composer" field, permission cards,
finale) driven by a single `TimelineView` with staged reveals. The host
window keeps the pattern of tearing down `contentView` on close so animation
timers and the permission poll die. First launch asks the user's name
(`settings.userName`), adds it to the dictionary, and the default dictionary
seed became just `["zeldaFlow"]` — the diff comment: "No personal seed data —
each install starts clean and learns its own user." The old file also
documents why `@StateObject` models are used: `@State` is unavailable on the
beta CLT (missing SwiftUIMacros plugin; see ADR 10).

## Alternatives considered

- Keep the functional static permissions checklist — worked, but unbranded
  and impersonal.
- Skip name collection and keep a generic dictionary — loses the
  personalization that makes the user's own name transcribe correctly.
- A video/Lottie-based intro — a single TimelineView keeps it code-only and
  dependency-free.

## Consequences

**Good**

- Each install starts clean and personalizes itself — a prerequisite for the
  planned public release; the user's name immediately biases STT.

**Bad**

- 700+ lines of bespoke animation code to maintain for a screen seen once.
- Timing-based staged reveals are brittle to edit.

Evidence: commit ca6091f (`Sources/zeldaFlow/UI/OnboardingCinematic.swift`,
`AppSettings.swift` seed change, `OnboardingWindow.swift` reduction).
