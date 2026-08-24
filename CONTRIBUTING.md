# Contributing to zeldaFlow

zeldaFlow is maintained at zeldaLabs by a small team
([MAINTAINERS.md](MAINTAINERS.md)) and open to people building on it. This page
is the short version of everything you need: what it takes to run the code, how
to add a capability, and the two rules that get a PR merged.

If you only want to *build something on top of it*, you don't need permission
or a PR — fork it and go. [TRADEMARK.md](TRADEMARK.md) has the one constraint
(give your fork its own name). [docs/EXTENDING.md](docs/EXTENDING.md) maps the
seams worth cutting at, honestly, including the ones that aren't ready.

## What you need before anything works

This is a native macOS app that runs local ML models. There is no way around
the hardware:

- **Apple Silicon Mac.** Both `setup.sh` and `build-app.sh` hard-fail on Intel.
- **macOS 15+.**
- **~5 GB of disk** for models, and ~1 GB resident while running.
- **Xcode Command Line Tools.** Full Xcode is not required.

## Setup, in this order

```bash
scripts/make-cert.sh     # FIRST. See below — this is the trap.
scripts/install.sh       # setup.sh → build-app.sh → /Applications → launch
```

**Run `make-cert.sh` before your first build.** It mints a self-signed
`zeldaFlow Dev` certificate into your keychain. macOS keys its privacy
permissions to the code signature, so without a *stable* identity every
rebuild produces a "new" app and silently drops your Accessibility and
Microphone grants — the symptom is Fn quietly doing nothing after a rebuild,
with no error anywhere (ADR 9). The cert is yours and local; nothing is shared
and no Apple Developer account is involved.

`setup.sh` downloads ~4.9 GB from public Hugging Face URLs. It is idempotent
and resumable — re-run it freely. Everything it downloads is MIT, Apache-2.0,
or CC-BY-4.0; see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

## Building

```bash
scripts/build-app.sh              # release; "debug" for -Onone -g
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands
```

**Never `swift build`.** [Package.swift](Package.swift) does not build this
app and is kept only for editor tooling — it has no FluidAudio target and
doesn't link half the frameworks (ADR 10). `scripts/build-app.sh` is the
build. If you change build inputs, change them there.

If you upgrade Xcode and the build fails with *"compiled module was created by
an older version of the compiler"*, that's the vendored FluidAudio archive.
The script detects toolchain changes and rebuilds it — if you somehow get
stuck, `rm -rf build/` and rebuild.

## Testing

Twelve headless harnesses, all documented in [docs/TESTING.md](docs/TESTING.md).
Four need nothing but the binary and are what CI runs:

```bash
BIN=./build/zeldaFlow.app/Contents/MacOS/zeldaFlow
"$BIN" --evalcommands    # 40 pins: command grammar, gates, anti-hallucination
"$BIN" --evalhotkey      # tap latency + the press/hold/tap gestures
"$BIN" --evaltask        # multi-step task loop: safety, termination, pruning
"$BIN" --evalmeeting     # meeting detection, chunking, notes, diarizer
```

The rest need a model, a display, audio hardware, or a TCC grant. Run what
your change touches. `docs/UAT.md` is the manual checklist for what no
harness can reach — hardware Fn presses, permission dialogs, audio by ear.

## Adding a voice command

This is the seam the codebase is actually good at, and it's four mechanical
edits. Only 4 of the 18 files under `Command/` even reference `AppState`, so
you can add a capability without touching the orchestration layer.

1. **Declare the parameter** — add an optional field to `struct ZeldaFlowAction`
   in [`Command/ZeldaFlowAction.swift`](Sources/zeldaFlow/Command/ZeldaFlowAction.swift)
2. **Register the route** — one `case "my_action":` in the switch in
   [`Command/ActionExecutor.swift`](Sources/zeldaFlow/Command/ActionExecutor.swift)
3. **Implement it** — a new `Command/Actions+*.swift`: a caseless `enum` with a
   static func returning `ActionOutcome`. Copy the shape of `Actions+Basic.swift`
4. **Teach the model** — one `{"action":"…"}` line in the JSON grammar in
   `commandSystemPrompt` in [`Cleanup/CleanupService.swift`](Sources/zeldaFlow/Cleanup/CleanupService.swift)

If the action is consequential — it sends something, spends something, or
can't be undone — add it to `ActionGate` so it's confirmation-gated. If it
should work without the LLM, add a deterministic pin in `CommandFastPath.swift`.

Adding a **meeting app** is a one-file change by design:
[`Meeting/MeetingApps.swift`](Sources/zeldaFlow/Meeting/MeetingApps.swift).

## House rules

Two, and they're both about the thing outliving the PR:

**Every behaviour change brings an ADR.** Not a paragraph in the PR
description — a numbered record in [`docs/adr/`](docs/adr/) saying what you
decided, what you rejected, and what it costs. There are 36 of them and they
are the reason someone can still understand this code. Follow the format in
`docs/adr/README.md`. Honest negative results are welcome; one of the
existing ADRs exists purely to record an experiment that failed.

**Every behaviour change brings an eval pin.** A `check(...)` in the relevant
`*Evals.swift` that fails before your fix and passes after. Bugs found in the
field become pins so they can't come back — that's most of what
`--evalcommands` is.

Beyond that: match the surrounding style, keep comments explaining *why*
rather than *what*, and don't reformat code you aren't changing.

## What will not be merged

**Anything that puts dictation on the network.** Not telemetry, not crash
reporting, not "optional" cloud STT, not an analytics ping. That constraint is
the product, and there is no version of this where it becomes negotiable.

Command mode has exactly two documented network exceptions (ADR 17) — the
opt-out Claude Code bridge, gated behind an explicit keypress every time, and
an anonymous Apple Music catalog lookup. Adding a third needs a very good ADR.

Also unlikely to land: dependencies added for convenience (this app vendors
deliberately), features that degrade dishonestly rather than saying what's
missing, and anything that makes the app do something the user didn't ask for.

## Signing off your commits

zeldaFlow uses the [Developer Certificate of Origin](https://developercertificate.org/).
It's one line, and it means you wrote the contribution or otherwise have the
right to submit it under Apache-2.0:

```bash
git commit -s -m "your message"
```

That appends `Signed-off-by: Your Name <your@email>`. Use your real name.
There's no CLA and nothing to sign — your copyright stays yours; you're
licensing the contribution under the project's license.

**Please don't add AI co-author trailers** (`Co-Authored-By:` lines for
assistants) to commits. Use whatever tools you like — the sign-off is about
who takes responsibility for the code, and that's a person.

## Pull requests

Small and focused beats large and comprehensive. Before you send:

- [ ] `scripts/build-app.sh` succeeds
- [ ] `--evalcommands` and any harness your change touches pass
- [ ] An ADR, if behaviour changed
- [ ] An eval pin, if behaviour changed
- [ ] No new network calls
- [ ] Commits signed off with `-s`

Opening an issue first is welcome for anything large — it's cheaper for both
of us than a rejected PR.

## Reporting bugs and vulnerabilities

Bugs: open an issue, and include your macOS version, Mac model, and the
relevant slice of `~/Library/Application Support/zeldaFlow/zeldaflow.log`
(check it for anything private first — it records what you dictated).
[docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) maps the log files.

Security vulnerabilities: **do not open an issue.** See
[SECURITY.md](SECURITY.md).

## Code of conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to every space this project
uses. Reports go to manu@zeldalabs.com.
