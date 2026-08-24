# 17. Bounded network exceptions: Apple Music catalog lookup and opt-out Claude agent mode

Status: Accepted
Date: 2026-07-19 (catalog); agent mode in the working tree by 2026-07-28

## Context

Two capabilities cannot be local: playing a song not in the user's library,
and screen-understanding or background tasks beyond a 2B model. The README
elevates the local constraint to policy and forces every exception to be
named and gated.

## Decision

**Exception 1 (committed):** `AppleMusicCatalog` queries the public iTunes
Search API — anonymous, no key — with a precise-to-fuzzy search cascade and
artist verification (rejecting cover versions and background scores), then
plays via a Music.app deep link and verifies the right song actually started
before claiming success.

**Exception 2 (working tree, uncommitted):** an Agent mode bridging to the
Claude Code CLI (`claude -p`, stream-json) for "what's on my screen"
(screenshot deleted immediately after) and background tasks — opt-out in the
menu, and because the agent gets terminal access, every background task
requires a Fn-tap confirmation "always, with no setting to turn that off."
Absence of the CLI degrades to a disabled menu item. Web questions simply
open a Google search in the user's default browser rather than answering
in-app.

## Alternatives considered

- No catalog fallback — "play X" fails whenever the song isn't in the
  library.
- Apple MusicKit API — requires developer tokens/accounts, against the
  no-account stance.
- Embedding an Anthropic API client for agent tasks — the CLI bridge reuses
  the user's existing Claude Code auth and sandboxing instead of holding
  keys.
- Auto-running agent tasks without confirmation — rejected; the gate is
  deliberately non-configurable.

## Consequences

**Good**

- The privacy story stays crisp and auditable — dictation audio never touches
  the network, and each exception is documented, anonymous, or human-gated;
  playback verification avoids false "now playing" claims.

**Bad**

- iTunes Search fuzziness needs heuristic patching (cover-version filtering).
- Agent mode couples a flagship feature to an externally installed CLI.
- The two-tier trust model (local vs Claude) must be continuously explained
  in UI and docs.

Evidence: commit 0377f77 (`Sources/zeldaFlow/Command/AppleMusicCatalog.swift`,
`WebAnswer.swift`); working tree: `Sources/zeldaFlow/Agent/AgentService.swift`,
`ScreenCapture.swift`, README agent-mode section.
