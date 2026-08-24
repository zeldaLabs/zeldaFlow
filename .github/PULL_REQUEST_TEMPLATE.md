## What this changes

<!-- What it does and why. If it fixes an issue, "Fixes #123". -->

## How it was verified

<!-- Which harnesses you ran and what they printed. Paste the tail. -->

```
$ ./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands
```

<!-- Anything you checked by hand — hardware Fn, permission dialogs, a real
     call, a second monitor — say so here. Manual verification counts; see
     docs/UAT.md. -->

## Checklist

- [ ] `scripts/build-app.sh` succeeds
- [ ] `--evalcommands` passes, plus any harness this change touches
- [ ] **An eval pin** covering the new behaviour, or the bug this fixes
- [ ] **An ADR** in `docs/adr/`, if behaviour changed — what you decided, what
      you rejected, what it costs
- [ ] Docs updated if this changes what a user sees (README, TESTING, UAT)
- [ ] **No new network calls.** Dictation never touches the network; command
      mode has exactly two documented exceptions (ADR 17)
- [ ] Commits signed off (`git commit -s`) — see [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md)
- [ ] No AI co-author trailers in the commits

<!-- New to the project? The two house rules are the ADR and the eval pin.
     Everything else is negotiable; those two are what keep this codebase
     understandable a year from now. Ask if you're unsure what yours should
     look like — we'd rather help than bounce the PR. -->
