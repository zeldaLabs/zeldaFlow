# 9. Self-signed stable "zeldaFlow Dev" certificate so TCC grants survive rebuilds

Status: Accepted
Date: 2026-07-19

## Context

macOS keys TCC grants (Accessibility, Microphone, Automation, Screen
Recording) to the code signature. Ad-hoc signatures change every build, so
each rebuild is treated as a brand-new app and silently loses its
permissions — fatal for an app whose core hotkey depends on Accessibility.
No paid Apple Developer ID is in play here.

## Decision

`scripts/make-cert.sh` creates a 10-year self-signed codeSigning certificate
(CN "zeldaFlow Dev") via openssl and imports it into the login keychain.
`build-app.sh` signs with `ZELDAFLOW_SIGN_ID`, else "zeldaFlow Dev" if found in the
keychain, else falls back to ad-hoc with a printed warning — always using the
stable bundle identifier `com.zeldalabs.zeldaflow`. One manual GUI step
remains (Keychain Access → Always Trust for code signing).

## Alternatives considered

- Ad-hoc signing only — the default fallback, but it requires re-toggling
  Accessibility after every rebuild (documented pain in the README).
- A paid Apple Developer ID certificate — the proper fix, but costs money and
  doesn't suit a local-tool workflow.
- `tccutil reset` scripting per build — fragile, and still requires manual
  re-granting.

## Consequences

**Good**

- Rebuild-and-run iteration keeps all TCC grants; "zeldaFlow Dev cert keeps TCC
  grants" is the confirmed working practice.

**Bad**

- A one-time manual trust step macOS refuses to automate.
- A self-signed cert means no distribution outside the machine (Gatekeeper).
- The p12 uses a fixed trivial password ("zeldaFlow").

Evidence: commit 0377f77 (`scripts/make-cert.sh`, `scripts/build-app.sh`
signing cascade, README "Signing & permissions caveat").
