# Security policy

zeldaFlow holds more privilege than most Mac apps, on purpose. Before the
reporting instructions, here is the honest surface, so you know what's worth
looking at.

## What this app can do

To work at all, zeldaFlow holds:

- **A suppressing CGEventTap on the Fn key** — it sees every key event on the
  system and swallows some of them (ADR 3). Accessibility permission.
- **The microphone**, and for meetings a **Core Audio process tap** on other
  apps' output — that is, the audio of the people you're on a call with.
- **The clipboard**, saved and restored around every insertion (ADR 5).
- **The accessibility tree of other apps** — it reads on-screen text for
  context biasing and drives other apps' menus for voice commands (ADR 13, 23).
- **Screen capture**, on request, for "what's on my screen".
- **A subprocess bridge to the Claude Code CLI**, which has terminal access
  (ADR 17). Opt-out, and every task requires a Fn-tap confirmation with no
  setting to disable it.
- **A local `llama-server` child process** on `127.0.0.1`, hosting Gemma.

Any of these is worth a hard look. Findings that turn one of them into
something the user didn't ask for are exactly what this policy is for.

## Design constraints that are load-bearing

These are guarantees, not aspirations. A break in any of them is a
vulnerability even if nothing else goes wrong:

- **Dictation never touches the network.** Ever.
- Command mode has exactly two documented network exceptions (ADR 17): the
  opt-out Claude bridge, and an anonymous Apple Music catalog lookup.
- `llama-server` binds to loopback only.
- **Meeting audio is deleted** once the transcript is finalized. The WAVs are
  a spool, not an archive.
- Consequential actions are confirmation-gated; `agent_task` is gated
  unconditionally and that gate has no off switch.
- Screenshots are deleted immediately after the model answers.

## Reporting a vulnerability

**Please do not open a public issue.**

Use GitHub's private vulnerability reporting — the **Security** tab on this
repository → *Report a vulnerability*. It's private to the maintainers and
gives us a place to talk before anything is public.

If that isn't working for you, email **manu@zeldalabs.com** or
**sahas@zeldalabs.com** with `zeldaFlow security` in the subject.

Useful to include: what you found, how to reproduce it, your macOS version and
Mac model, and what you think the impact is. A proof of concept helps a lot. If
you're not sure whether something counts, report it anyway — over-reporting is
the cheaper mistake.

## What to expect

This is a small team, so these are honest targets, not an SLA:

| | |
|---|---|
| First response | within 7 days |
| Assessment and a plan | within 14 days |
| Fix for a confirmed high-severity issue | as fast as I can, and I'll tell you the timeline |

I'll keep you updated, credit you in the release notes and the advisory unless
you'd rather I didn't, and let you know before anything goes public. Please
give me a chance to ship a fix before disclosing — and if I go quiet on you for
weeks, disclose anyway. That's fair.

## Scope

**In scope:** anything in this repository — the app, the build and setup
scripts, the vendored code under `Vendor/`.

**Out of scope**, though I still want to hear about it and will help route it:

- Vulnerabilities in upstream projects (whisper.cpp, llama.cpp, FluidAudio,
  the Claude Code CLI) — report those to their maintainers
- Anything requiring an attacker who already has code execution as your user,
  or physical access to an unlocked Mac. On macOS that attacker has already won
- The app being able to do what it openly says it does — reading the screen,
  holding the mic, swallowing Fn. The bug would be doing it *unrequested*,
  outside a documented gate, or without the visible indicator
- Missing hardening on a self-signed dev build. There is no notarized
  distribution yet; builds are from source (ADR 9)

## Supported versions

Version 1.0.0 (`main`) is the only supported version. There is no LTS branch
and no backporting — fixes land on `main` and go out in the next release.
