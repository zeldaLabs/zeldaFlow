# 32. Editable meeting notes: raw-markdown edit mode with debounced autosave

**Status**: Accepted
**Date**: 2026-08-09

## Context

ADR 27 cut the manual-notes editor from v1: notes were generated, renameable,
exportable — but not editable. In practice the generated notes are a starting
point, not the final artifact: people fix action-item owners, add context the
model couldn't know, and delete sections that don't matter. That editing
happened outside the app, which forfeits the single-place story the meetings
page exists for.

Three platform constraints shaped the design:

1. **SwiftUI text input is broken on this beta toolchain.** TextField renders
   keystrokes but never delivers them to the binding (documented in
   `AppKitTextField.swift`), `TextEditor` shares the defect, and `@State` is
   unavailable (missing SwiftUIMacros plugin). Any editor must be an AppKit
   `NSTextView` behind an `NSViewRepresentable`, with state in the
   `@StateObject` model.
2. **`MarkdownRenderer` is strictly one-way.** The hand-rolled markdown →
   `NSAttributedString` renderer has no inverse, so WYSIWYG editing of the
   rendered rich text would require writing and maintaining an
   attributed-string → markdown serializer whose round-trip losses would
   corrupt exactly the file it edits.
3. **Navigation destroys the detail view instantly.** `MeetingsPage` swaps
   `MeetingDetailView` in and out on `MeetingNav.openMeetingID`; there is no
   willDisappear seam. Any "save on close" design silently loses the last
   edit.

## Decision

An **Edit/Done toggle over the raw markdown**, autosaved as the user types.

- The pencil button in the notes toolbar (or ⌘E) swaps the rendered
  `AttributedTextView` for `MarkdownEditorView` — a plain, monospaced,
  undo-enabled `NSTextView` showing `notes.md` verbatim. Done (or Esc)
  returns to the rendered preview.
- **Autosave, not explicit save**: `textDidChange` debounces ~800 ms into
  `MeetingStore.writeNotes` (already atomic) + `meta.notesEditedAt = now`.
  The model's `deinit` flushes any pending draft — both store calls only
  enqueue onto the store's serial queue, so the instant-navigation teardown
  cannot lose text.
- **`MeetingMeta.notesEditedAt`** (optional — old meta.json decodes
  unchanged) records that a human touched the file. Regenerate warns before
  clobbering when it is set; `generateNotes` clears it, because freshly
  generated notes are by definition unedited. `notesHash` keeps its existing
  meaning (transcript provenance of the last *generation*) — a hand-edit
  doesn't change which transcript the generation saw.
- While editing: the staleness banner is hidden and Regenerate is disabled
  (both would race the draft); the `.done`-edge reload in `recordsChanged`
  is gated on `!editingNotes` so a background regenerate can't stomp the
  buffer.
- Meetings that never had notes get **"or write them yourself"** under the
  Generate button: an empty `notes.md` + `.done` is indistinguishable
  downstream from a generated one, so every existing gate just works.

## Alternatives considered

- **WYSIWYG (edit the rendered rich text)** — rejected: requires the
  nonexistent inverse renderer; formatting round-trips are lossy; raw
  markdown in monospace is honest about what's actually in the file.
- **Explicit Save button** — rejected: the no-willDisappear teardown makes
  unsaved-changes prompts impossible to guarantee; autosave has no lost-work
  window bigger than the debounce.
- **A separate "user notes" file alongside the generated one** — rejected:
  two sources of truth for one document; export/copy would need merge rules.

## Consequences

- **Good**: edits survive the harshest exit path (instant view teardown);
  regeneration can no longer silently destroy human work; the store's
  atomic-write and staleness semantics are untouched.
- **Good**: `AttributedTextView` (read path) is untouched — zero regression
  surface for every other consumer.
- **Bad**: editing shows markdown syntax, not formatting. Accepted: the
  preview is one click away, and the syntax is the file.
- **Bad**: an edit mid-`.generating` isn't possible (toolbar gated on
  `.done`) — deliberate, the generator owns the file during a run.

Evidence: `Sources/zeldaFlow/UI/MarkdownEditorView.swift`,
`Sources/zeldaFlow/UI/MeetingDetailView.swift`,
`Sources/zeldaFlow/Meeting/MeetingModels.swift` (`notesEditedAt`),
`Sources/zeldaFlow/Meeting/MeetingCenter.swift` (`generateNotes`).
