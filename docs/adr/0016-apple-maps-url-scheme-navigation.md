# 16. Apple Maps navigation via the maps:// URL scheme instead of UI scripting

Status: Accepted
Date: 2026-07-19

## Context

"Navigate to the airport" should open turn-by-turn directions. Apple Maps has
no AppleScript dictionary worth using, but macOS honors the `maps://` URL
scheme.

## Decision

A `navigate` action builds `maps://?daddr=<dest>&dirflg=<d|w|r>` and opens it
with NSWorkspace. The code comment records live verification: "On macOS the
maps:// URL computes the route AND opens the turn-by-turn Details panel by
itself — verified live; no UI scripting needed." The fast path recognizes
many phrasings ("navigate to", "take me to", "how do I get to") with "by
walk/transit/car" suffix parsing, deliberately ordered before question
routing so "how do I get to X" navigates instead of googling. Destination and
transport fields were added to `ZeldaFlowAction`, the executor, and the LLM
prompt.

## Alternatives considered

- AppleScript / System Events UI scripting of Maps — fragile,
  permission-heavy; explicitly avoided per the comment.
- A Google Maps web URL — leaves the native-apps pattern and the local
  ecosystem.
- LLM-only recognition of navigation intent — the fast path guarantees exact
  destination text.

## Consequences

**Good**

- One URL open replaces UI automation entirely; transport modes come for
  free; the behavior is live-verified and documented in code.

**Bad**

- Demonstrates the schema-extension tax: one small feature touched 5 files
  (fast path, action schema, executor, actions, LLM prompt).
- `dest.capitalized` may distort case-sensitive place names.
- Fast-path ordering constraints keep accumulating.

Evidence: commit df52e0b (`Sources/zeldaFlow/Command/Actions+Basic.swift`
`navigate()`, `CommandFastPath.parseNavigate`, `ZeldaFlowAction`
destination/transport fields).
