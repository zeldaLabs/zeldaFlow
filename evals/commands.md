# Command-layer behavior pins

zeldaFlow's voice commands are interpreted by two layers: a deterministic
fast-path parser (exact words, no model) and a local LLM fallback. The parts
that must never drift are pinned by `--evalcommands`:

```bash
scripts/build-app.sh
./build/zeldaFlow.app/Contents/MacOS/zeldaFlow --evalcommands
```

Runs in under a second — no LLM, no network, no permissions. Re-run it after
any change to `CommandFastPath`, `ActionGate`, `MusicPlayers`, or
`AppResolver`.

## What is pinned

**Must-execute** — common commands parse from the user's exact words, so a
model can never substitute a different app, artist, or destination:
open/close app, playback control, volume, `play <song> by <artist>`,
playlists, navigation, questions, speak-to-edit.

**Device adaptation** — a named music service ("on Spotify") always reaches
the action verbatim; nothing else guesses a service at parse time. Apps that
aren't installed on this Mac fall back to their web app rather than a
different local app.

**Must-defer** — ambiguity belongs to the LLM: multi-intent commands
("open Notes and play some jazz"), messaging with free-form content, and
UI-level phrases ("close the tab") must return nil from the fast path.

**Must-confirm** — the gates around anything that leaves this Mac:

| Action | Gate |
|---|---|
| `send_email`, `send_message` | Fn-tap confirmation while "Confirm before sending" is on |
| `draft_email` | never gated — nothing is sent |
| `agent_task` | **always** gated, regardless of settings — the agent gets terminal access |

If a pin fails, the fix is almost never to update the eval — it exists to
make you argue with it.
