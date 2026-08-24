# 10. Keep Package.swift but build with a direct swiftc invocation; no Xcode project

Status: Accepted
Date: 2026-07-19

## Context

zeldaFlow is developed on the macOS 27 beta Command Line Tools, where
`swift build` is broken: the CLT's PackageDescription swiftinterface and
dylib disagree, so any Package.swift fails to compile. The app has zero
package dependencies and one binary framework.

## Decision

`scripts/build-app.sh` compiles all sources with one `swiftc` call
(`-swift-version 5`, target `arm64-apple-macos15.0`, framework links,
`@executable_path` rpath), assembles the .app bundle by hand (Info.plist,
embedded whisper.framework), and codesigns. Package.swift is retained "for
when Apple fixes the toolchain," itself restricted to API that exists in both
interface and dylib. A related toolchain accommodation: the beta CLT ships no
SwiftUIMacros plugin, so `@State` is unavailable — the UI uses small
`@StateObject` ObservableObject models instead.

## Alternatives considered

- `swift build` — broken on this toolchain (root cause documented in both
  files).
- A full Xcode project — heavyweight, full Xcode may not be present, and
  harder to keep scripted and reviewable.
- Downgrading to stable CLT — conflicts with the beta OS in use.
- Make/CMake wrappers — swiftc-direct is simpler for a dependency-free
  target.

## Consequences

**Good**

- Reliable scripted builds; bundle assembly and signing are explicit and
  inspectable.

**Bad**

- Manual source listing and flag maintenance; no incremental compilation.
- The `@State` workaround shapes UI code style throughout.
- The project must remember to revisit when the toolchain is fixed.

Evidence: commit 0377f77 (`scripts/build-app.sh` header comment,
`Package.swift` NOTE comment, README "Beta-toolchain notes").
