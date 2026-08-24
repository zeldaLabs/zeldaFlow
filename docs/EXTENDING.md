# Extending zeldaFlow

An honest map of where this codebase can be cut, and where it can't yet.

**There is no plugin API.** No dynamic loading, no manifest format, no
scripting bridge, no URL scheme, no config file that changes behaviour. Every
extension point below is compile-time: you fork, you edit Swift, you rebuild.
That's a deliberate v1 choice — a plugin surface on an app that holds the
microphone, the clipboard, and the accessibility tree is a security design
problem, not a weekend of work, and freezing an API before anyone has extended
anything tends to freeze the wrong one.

So this page tells you where the seams already are, and is candid about which
ones would need real surgery first. If you build something and the seam you
wanted was in the second list, open an issue — that's the signal we'd use to
decide what becomes a real API.

## The good seam: voice commands

The action pipeline is genuinely decoupled. Only 4 of the 18 files under
`Command/` reference `AppState` at all, and `ActionExecutor.run` takes just
`(ZeldaFlowAction, CommandContext)` — where `CommandContext` is one optional
string. Adding a command is four mechanical edits and touches no orchestration:

| Step | File | What you add |
|---|---|---|
| Declare the parameter | [`Command/ZeldaFlowAction.swift:6`](../Sources/zeldaFlow/Command/ZeldaFlowAction.swift) | an optional field on `struct ZeldaFlowAction` |
| Register the route | [`Command/ActionExecutor.swift`](../Sources/zeldaFlow/Command/ActionExecutor.swift) | one `case "my_action":` in the 30-case switch |
| Implement it | new `Command/Actions+*.swift` | a caseless `enum`, static func, returns `ActionOutcome` |
| Teach the model | [`Cleanup/CleanupService.swift:619`](../Sources/zeldaFlow/Cleanup/CleanupService.swift) | one `{"action":"…"}` line in `commandSystemPrompt` |

Two optional extras:

- **[`ActionGate`](../Sources/zeldaFlow/Command/ZeldaFlowAction.swift) (line 101)** — if
  the action sends something, spends something, or can't be undone, register it
  here so it's confirmation-gated. `agent_task` shows the unconditional form.
- **[`CommandFastPath.swift`](../Sources/zeldaFlow/Command/CommandFastPath.swift)** — a
  deterministic parse, so exact-word commands never reach the model. This is
  how "open Safari" can't become "open Safari Technology Preview" (ADR 6).

The model never writes code — it fills a JSON schema, and the executor decides
what that means (ADR 7). Keep new actions in that shape.

## Other one-file seams

| What | File | Notes |
|---|---|---|
| **Meeting apps** | [`Meeting/MeetingApps.swift`](../Sources/zeldaFlow/Meeting/MeetingApps.swift) | Pure data. Bundle IDs, browser title fragments, which apps need output corroboration. Detection engine, process monitor and browser probe all read this one table — supporting a new client is a table edit |
| **Hotkey binding** | [`Hotkey/HotkeyBinding.swift`](../Sources/zeldaFlow/Hotkey/HotkeyBinding.swift) | Already `Codable` and data-driven, with modifier-flag and non-typing-label tables. Genuinely rebindable |
| **Model paths** | [`Support/Paths.swift`](../Sources/zeldaFlow/Support/Paths.swift) | Every model filename and app-support location in one place. The obvious hook if you want swappable models |
| **Settings** | [`Support/AppSettings.swift`](../Sources/zeldaFlow/Support/AppSettings.swift) | `UserDefaults`-backed `@Published` properties. Add a toggle here, read it anywhere |
| **Anti-hallucination rules** | [`STT/HallucinationFilter.swift`](../Sources/zeldaFlow/STT/HallucinationFilter.swift) | Pure string functions, heavily pinned in `--evalcommands`. Easy and safe to extend |
| **Export formats** | [`Meeting/MeetingExporter.swift`](../Sources/zeldaFlow/Meeting/MeetingExporter.swift) | Markdown, txt, SRT, JSON today — all static funcs over `[MeetingSegment]` |

## The seams that aren't ready

These are the ones people ask for first, and each is a concrete `final class`
or caseless `enum` with no protocol in front of it. There are exactly **two**
protocols in ~24,000 lines of Swift (`HotkeyMonitorDelegate` and
`MeetingAudioConsumer`), and neither is a plugin seam. Swapping any of these
means extracting an interface first — doable, but it's a refactor, not a hook:

| You want to | Blocked by | Rough shape of the work |
|---|---|---|
| Swap the STT engine | `final class WhisperEngine` — whisper.cpp is hard-wired, including the initial-prompt dictionary path | Extract a `TranscriptionEngine` protocol; the awkward part is that VAD, prompt biasing and the resident-context lifecycle all leak through the current API |
| Swap the cleanup LLM | `final class CleanupService` — also owns both system prompts, the `llama-server` child process, and `enum LightCleaner` | Split prompt-building from process supervision from HTTP, then put a protocol on the middle |
| Change how text is inserted | `enum TextInserter` — caseless enum, static funcs, cannot be substituted at all | Make it an instance behind a protocol. Watch the clipboard save/restore and secure-input detection (ADR 5, ADR 20) |
| Replace the agent backend | `final class AgentService` — Claude Code CLI, stream-json | Protocol over "send a prompt, stream a narrative back". The confirmation gate must stay unconditional |
| Add UI | `AppState.swift` is ~1,100 lines and every UI file goes through it | No shortcut. This is the least decoupled part of the codebase and ARCHITECTURE §11 says so |

## Things you should know before you start

- **`scripts/build-app.sh` is the build.** Not `swift build` —
  [Package.swift](../Package.swift) doesn't describe the real target graph
  (ADR 10). New source files under `Sources/zeldaFlow/` are picked up
  automatically; new vendored code needs a line in the script.
- **The app builds `-swift-version 5` on purpose**, so strict-concurrency
  findings are warnings rather than errors. If you add concurrency, don't
  assume the compiler is checking you.
- **Two house rules apply to anything you contribute back**: an ADR for the
  decision, an eval pin for the behaviour. See
  [CONTRIBUTING.md](../CONTRIBUTING.md).
- **The network boundary is not negotiable.** Dictation never touches the
  network; command mode has exactly two documented exceptions (ADR 17). If
  your extension needs a third, that's an ADR conversation before it's code.
- **Read the ADRs before a big change.** There are 36 in [`adr/`](adr/), and
  they exist so you can tell a deliberate constraint from an accident. Most
  surprising-looking code here is ADR'd.

## If you're building on top rather than contributing back

Fork it, rename it ([TRADEMARK.md](../TRADEMARK.md) — that's the only
constraint), and go. Apache-2.0 means you can ship it commercially and
closed-source. Two practical notes:

- Keep [`LICENSE`](../LICENSE), [`NOTICE`](../NOTICE), and the vendored license
  texts with your fork — Apache-2.0 and BSD-2 both require it. CI has a gate
  that checks they're present; keep it.
- **The models are permissively licensed** — Whisper and Silero MIT, Gemma 4
  Apache-2.0, the optional diarizer models CC-BY-4.0. If you're building a
  product, read [THIRD-PARTY-LICENSES.md](../THIRD-PARTY-LICENSES.md) before
  you ship; the CC-BY-4.0 attribution is the one obligation that follows the
  output.

And tell us about it in Discussions. That's what it's there for.
