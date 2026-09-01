import AppKit
import Combine
import SwiftUI

// Meeting detail — the drill-down MeetingsPage swaps in for one record:
// header (rename/delete), a Transcript/Notes tab pair, and per-tab export.
// The model, not the view, owns every subscription: the record is re-looked-up
// from the store so noteState transitions and late Gemma titles render while
// the page is open, and a live session's segments are mirrored here instead of
// observed from the view tree.

// MARK: - Model

/// View-local state. @State is unavailable on this beta CLT (missing
/// SwiftUIMacros plugin), so everything lives here behind @StateObject.
@MainActor fileprivate final class MeetingDetailModel: ObservableObject {
    @Published var tab = 0                      // 0 transcript · 1 notes
    @Published var record: MeetingRecord?
    @Published var segments: [MeetingSegment] = []
    @Published var notes: String?
    @Published var notesStale = false
    @Published var renaming = false
    @Published var draftTitle = ""
    @Published var hoveringTitle = false
    @Published var isLive = false
    @Published var copiedTranscript = false
    @Published var copiedNotes = false
    @Published var editingNotes = false
    /// Per-meeting speaker renames, cluster index → name (ADR 31).
    @Published var speakerNames: [Int: String] = [:]
    /// Names inferred from the transcript (ADR 38) — display fallback only;
    /// a user rename in `speakerNames` always wins, and only `speakerNames`
    /// is ever written back to meta.
    @Published var inferredNames: [Int: String] = [:]
    /// Thumbs on each artefact (ADR 35); nil = not rated yet, which is what
    /// shows the in-page ask.
    @Published var transcriptRating: MeetingRating?
    @Published var notesRating: MeetingRating?

    /// Draft buffer while editing. Deliberately not @Published: the
    /// NSTextView owns the live text, and publishing every keystroke would
    /// re-run body (and updateNSView) per character for nothing.
    var draftNotes = ""

    let recordID: UUID

    /// meta.notesHash, cached so staleness can be recomputed as live segments
    /// keep arriving after the notes were written.
    private var notesHash: String?
    /// meta.notesEditedAt, cached so Regenerate can warn before clobbering
    /// hand-edited notes.
    private var notesEditedAt: Date?
    /// Debounced-autosave state. `unsavedDraft` is the text not yet flushed
    /// to disk — deinit's safety net, because navigating away destroys this
    /// model instantly (MeetingsPage swaps the whole view, no willDisappear).
    private var saveTask: Task<Void, Never>?
    private var unsavedDraft: String?
    private var segmentsLoaded = false
    private var liveCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []

    init(recordID: UUID) {
        self.recordID = recordID

        // Seed synchronously before subscribing — the sinks hop through a
        // main-actor Task, and one frame of "record == nil" would flash the
        // deleted-meeting fallback on every open.
        record = MeetingStore.shared.records.first { $0.id == recordID }
        // Unconditional: notes may be nil pre-.done, but the meta carries
        // speaker names/count that render regardless of note state.
        loadNotesAndMeta()
        liveSessionChanged(MeetingCenter.shared.liveSession)

        MeetingStore.shared.$records
            .sink { [weak self] records in
                Task { @MainActor in self?.recordsChanged(records) }
            }
            .store(in: &cancellables)

        MeetingCenter.shared.$liveSession
            .sink { [weak self] session in
                Task { @MainActor in self?.liveSessionChanged(session) }
            }
            .store(in: &cancellables)

        // Polish/diarization rewrite transcript.jsonl after the detail view
        // already read it (stop finishes before those passes) — this is the
        // "speakers identified" refresh moment.
        MeetingStore.shared.transcriptRewrites
            .sink { [weak self] id in
                Task { @MainActor in
                    guard let self, id == self.recordID, !self.isLive else { return }
                    self.loadSegmentsFromDisk()
                    self.loadNotesAndMeta()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        // Back button / pill chip / banner all swap this view out instantly;
        // a pending debounce must not lose the last keystrokes. Both store
        // calls only enqueue onto the store's own serial queue, which makes
        // them safe to fire from deinit on any thread.
        if let draft = unsavedDraft {
            let now = Date()
            MeetingStore.shared.writeNotes(recordID, markdown: draft)
            MeetingStore.shared.updateMeta(recordID) { $0.notesEditedAt = now }
        }
    }

    // MARK: Record + notes lifecycle

    private func recordsChanged(_ records: [MeetingRecord]) {
        let previous = record?.noteState
        record = records.first { $0.id == recordID }
        // Entering .done means a generate/regenerate just finished — the
        // markdown and the meta hash on disk are new, so reload both.
        // Not while editing: a background regenerate finishing mid-edit must
        // not stomp the user's draft (Regenerate warned before it started).
        if record?.noteState == .done, previous != .done, !editingNotes {
            loadNotesAndMeta()
        }
    }

    private func loadNotesAndMeta() {
        let id = recordID
        Task { [weak self] in
            // Both loads are synchronous store-queue I/O — off the main
            // actor, same pattern as MeetingCenter.regenerateNotes.
            let loaded = await Task.detached {
                (MeetingStore.shared.loadNotes(id), MeetingStore.shared.loadMeta(id))
            }.value
            guard let self else { return }
            self.notes = loaded.0
            self.notesHash = loaded.1?.notesHash
            self.notesEditedAt = loaded.1?.notesEditedAt
            self.speakerNames = Self.parseSpeakerNames(loaded.1?.speakerNames)
            self.inferredNames = Self.parseInferredNames(loaded.1?.inferredSpeakerNames)
            self.transcriptRating = loaded.1?.transcriptRating
            self.notesRating = loaded.1?.notesRating
            self.refreshStaleness()
        }
    }

    // MARK: Feedback (ADR 35)

    /// Tapping the thumb you already gave clears it — a rating you can't
    /// take back is a rating people stop giving.
    func rateTranscript(_ rating: MeetingRating) {
        let value = transcriptRating == rating ? nil : rating
        transcriptRating = value
        let now = Date()
        MeetingStore.shared.updateMeta(recordID) {
            $0.transcriptRating = value
            $0.transcriptRatedAt = value == nil ? nil : now
        }
    }

    func rateNotes(_ rating: MeetingRating) {
        let value = notesRating == rating ? nil : rating
        notesRating = value
        let now = Date()
        MeetingStore.shared.updateMeta(recordID) {
            $0.notesRating = value
            $0.notesRatedAt = value == nil ? nil : now
        }
    }

    /// meta.speakerNames keeps String keys (JSON friendliness); the UI wants
    /// cluster indices.
    private static func parseSpeakerNames(_ raw: [String: String]?) -> [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in raw ?? [:] {
            if let index = Int(key) { out[index] = value }
        }
        return out
    }

    /// meta.inferredSpeakerNames is keyed by roster key ("s0", "s-1").
    private static func parseInferredNames(_ raw: [String: String]?) -> [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in raw ?? [:] {
            if key.hasPrefix("s"), let index = Int(key.dropFirst()) { out[index] = value }
        }
        return out
    }

    /// What the transcript, exports, and menus actually show: user renames
    /// over inferred names (ADR 38).
    var displayNames: [Int: String] {
        inferredNames.merging(speakerNames) { _, user in user }
    }

    // MARK: Speaker renaming (ADR 31)

    /// Distinct far-side speakers in this transcript, in first-heard order.
    /// `[-1]` for an undiarized call — one other person, still nameable.
    var speakerKeys: [Int] {
        var keys: [Int] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard let key = segment.renameKey, !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    func speakerMenuTitle(_ key: Int) -> String {
        if let name = displayNames[key] { return name }
        return key == MeetingSegment.unlabeledSpeakerKey ? "Them" : "Speaker \(key + 1)"
    }

    /// NSAlert + text field, the house pattern (confirmDelete). Renames live
    /// in meta.json only — the transcript file and its hash never change.
    /// `cluster` is a diarization index, or `unlabeledSpeakerKey` for the
    /// far side of a call diarization never split (a 1:1 call still deserves
    /// a name).
    func promptRenameSpeaker(_ cluster: Int) {
        let fallback = cluster == MeetingSegment.unlabeledSpeakerKey
            ? "Them" : "Speaker \(cluster + 1)"
        let previousLabel = displayNames[cluster] ?? fallback
        let alert = NSAlert()
        alert.messageText = "Name this speaker"
        alert.informativeText = "Shown in place of “\(previousLabel)” in this meeting's transcript, notes, and exports."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = fallback
        field.stringValue = displayNames[cluster] ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            speakerNames.removeValue(forKey: cluster)
        } else {
            speakerNames[cluster] = name
        }
        let snapshot = speakerNames
        MeetingStore.shared.updateMeta(recordID) { meta in
            meta.speakerNames = snapshot.isEmpty
                ? nil
                : Dictionary(uniqueKeysWithValues: snapshot.map { (String($0.key), $0.value) })
        }
        propagateRenameIntoNotes(cluster: cluster, previousLabel: previousLabel)
    }

    /// Renames reach the notes too (ADR 38). Unedited notes re-render from
    /// notes.json under the new roster — deterministic, no model, no drift.
    /// Hand-edited notes are never clobbered: they get a best-effort
    /// word-boundary text replacement of the one label that changed ("You"
    /// is never a rename target here — only far-side clusters rename).
    private func propagateRenameIntoNotes(cluster: Int, previousLabel: String) {
        guard notes != nil, !editingNotes else { return }
        if notesEditedAt == nil {
            Task { [weak self] in
                guard let self else { return }
                await MeetingCenter.shared.rerenderNotes(self.recordID)
                self.loadNotesAndMeta()
            }
            return
        }
        let newLabel = displayNames[cluster]
            ?? (cluster == MeetingSegment.unlabeledSpeakerKey ? "Them" : "Speaker \(cluster + 1)")
        guard newLabel != previousLabel, previousLabel != "You",
              let current = notes, !current.isEmpty else { return }
        let updated = Replacements.apply([previousLabel: newLabel], to: current)
        guard updated != current else { return }
        notes = updated
        MeetingStore.shared.writeNotes(recordID, markdown: updated)
    }

    /// meta.notesHash is the transcript hash at generation time; a mismatch
    /// against the current segments means the notes describe an older
    /// transcript (crash-recovered tail, segments landed after regenerate).
    private func refreshStaleness() {
        notesStale = notesHash != nil && notesHash != segments.transcriptHash()
    }

    // MARK: Live seam

    private func liveSessionChanged(_ session: MeetingSession?) {
        if let session, session.id == recordID {
            guard !isLive else { return }
            isLive = true
            segments = session.segments
            // objectWillChange fires *before* the array mutates; the Task hop
            // lands after, so the mirror always reads the post-change value.
            // Mirroring here — not observing the session from the view — is
            // what confines per-chunk invalidation to `segments` subscribers.
            liveCancellable = session.objectWillChange
                .sink { [weak self, weak session] _ in
                    Task { @MainActor in
                        guard let self, let session else { return }
                        self.segments = session.segments
                        self.refreshStaleness()
                    }
                }
        } else {
            let wasLive = isLive
            isLive = false
            liveCancellable = nil
            // Reload after a live meeting ends: the finalized on-disk
            // transcript has the late retractions the in-memory mirror never
            // saw. Unrelated sessions starting/stopping don't re-read disk.
            if wasLive || !segmentsLoaded { loadSegmentsFromDisk() }
        }
    }

    private func loadSegmentsFromDisk() {
        segmentsLoaded = true
        let id = recordID
        Task { [weak self] in
            let segments = await Task.detached { MeetingStore.shared.loadSegments(id) }.value
            guard let self else { return }
            self.segments = segments
            self.refreshStaleness()
        }
    }

    // MARK: Notes editing

    func beginEdit() {
        draftNotes = notes ?? ""
        editingNotes = true
    }

    func noteDraftChanged(_ text: String) {
        draftNotes = text
        unsavedDraft = text
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    func endEdit() {
        saveTask?.cancel()
        flushSave()
        editingNotes = false
    }

    private func flushSave() {
        guard let draft = unsavedDraft, record != nil else { return }
        let now = Date()
        MeetingStore.shared.writeNotes(recordID, markdown: draft)
        MeetingStore.shared.updateMeta(recordID) { $0.notesEditedAt = now }
        // Nothing re-reads notes.md while noteState stays .done — the local
        // copy is the preview's source of truth after our own write.
        notes = draft
        notesEditedAt = now
        unsavedDraft = nil
    }

    /// "Write notes yourself" for meetings that never got generated notes.
    /// Empty notes.md + .done is indistinguishable downstream from a
    /// generated result, so the toolbar/copy/export gates all just work.
    func createManualNotes() {
        guard var rec = record else { return }
        MeetingStore.shared.writeNotes(recordID, markdown: "")
        rec.noteState = .done
        record = rec                       // immediate — the sink hop lands a tick later
        MeetingStore.shared.update(rec)
        notes = ""
        beginEdit()
    }

    // MARK: Rename / delete

    func beginRename() {
        draftTitle = record?.displayTitle ?? ""
        renaming = true
    }

    func commitRename() {
        renaming = false
        guard var rec = record else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != rec.title else { return }
        rec.title = title
        MeetingStore.shared.update(rec)
    }

    func confirmDelete(then onDeleted: () -> Void) {
        guard let rec = record else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(rec.displayTitle)”?"
        alert.informativeText = "The transcript and notes are removed from this Mac. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MeetingStore.shared.delete(recordID)
        onDeleted()
    }

    // MARK: Copy / export / regenerate

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingExporter.plainTranscript(segments),
                                       forType: .string)
        flashCopied(\.copiedTranscript)
    }

    func copyNotes() {
        guard let notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notes, forType: .string)
        flashCopied(\.copiedNotes)
    }

    private func flashCopied(_ keyPath: ReferenceWritableKeyPath<MeetingDetailModel, Bool>) {
        self[keyPath: keyPath] = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?[keyPath: keyPath] = false
        }
    }

    func exportTranscript(_ ext: String) {
        guard let rec = record else { return }
        let content: String
        switch ext {
        case "md":  content = MeetingExporter.markdown(record: rec, segments: segments,
                                                       names: displayNames)
        case "srt": content = MeetingExporter.srt(segments: segments, names: displayNames)
        default:    content = MeetingExporter.txt(record: rec, segments: segments,
                                                  names: displayNames)
        }
        save(content, name: fileName(rec, ext: ext))
    }

    func exportNotes(_ ext: String) {
        guard let rec = record, let notes else { return }
        // .txt strips markdown syntax by round-tripping through the renderer.
        let content = ext == "txt"
            ? MarkdownRenderer.render(notes, ink: .labelColor, muted: .secondaryLabelColor).string
            : notes
        save(content, name: fileName(rec, ext: ext, suffix: " — notes"))
    }

    private func fileName(_ rec: MeetingRecord, ext: String, suffix: String = "") -> String {
        // displayTitle's fallback carries "h:mm" — the colon is the character
        // Finder can't stomach; "/" would silently become a folder.
        let base = rec.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        return base + suffix + "." + ext
    }

    private func save(_ content: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            Log.error("MeetingDetail: export failed: \(error.localizedDescription)")
        }
    }

    func regenerate() {
        if notesEditedAt != nil {
            let alert = NSAlert()
            alert.messageText = "Regenerate notes?"
            alert.informativeText = "You've edited these notes by hand. Regenerating replaces them with fresh AI-written notes."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Regenerate")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        MeetingCenter.shared.regenerateNotes(recordID)
    }

    // MARK: Header caption

    var metaCaption: String {
        guard let rec = record else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        var parts = [f.string(from: rec.date)]
        if isLive {
            // durationSeconds is 0 until stop finalizes it; "0 s" would read
            // as a bug on a meeting that is visibly still filling in.
            parts.append("recording")
        } else if rec.durationSeconds >= 60 {
            parts.append("\(Int(rec.durationSeconds / 60)) min")
        } else {
            parts.append("\(Int(rec.durationSeconds)) s")
        }
        if !rec.appName.isEmpty { parts.append(rec.appName) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - View

struct MeetingDetailView: View {
    @StateObject private var model: MeetingDetailModel
    private let onBack: () -> Void

    private static let tabWidth: CGFloat = 110

    init(recordID: UUID, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _model = StateObject(wrappedValue: MeetingDetailModel(recordID: recordID))
    }

    var body: some View {
        if model.record == nil {
            // Deleted out from under us (retention sweep, live discard) —
            // there is nothing to render, only a way home.
            VStack(spacing: 12) {
                Text("This meeting is gone.")
                    .foregroundStyle(Zelda.mutedFg)
                Button("Back to Meetings") { onBack() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                tabBar
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                content
                    .padding(.top, 10)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { onBack() } label: {
                Text("‹ Meetings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Zelda.mutedFg)
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    titleRow
                    Text(model.metaCaption)
                        .font(.caption)
                        .foregroundStyle(Zelda.mutedFg)
                }
                Spacer()
                if !model.isLive {
                    // While live, the record's fate belongs to the pill's
                    // Stop/Discard — deleting under an active recorder here
                    // would orphan the capture mid-write.
                    Button { model.confirmDelete(then: onBack) } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Zelda.mutedFg)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete meeting")
                }
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if model.renaming {
                AppKitTextField(placeholder: "Meeting title",
                                text: model.draftTitle,
                                onChange: { model.draftTitle = $0 },
                                onSubmit: { model.commitRename() },
                                onEscape: { model.renaming = false },
                                autofocus: true)
                    .frame(width: 340)
            } else {
                Text(model.record?.displayTitle ?? "")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Zelda.foreground)
                    .lineLimit(1)
                Button { model.beginRename() } label: {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Zelda.mutedFg)
                }
                .buttonStyle(.plain)
                .help("Rename")
                // Space is reserved and only opacity flips — a pencil that
                // appears in the layout would resize the hover region under
                // the cursor and flicker.
                .opacity(model.hoveringTitle ? 1 : 0)
            }
        }
        .onHover { model.hoveringTitle = $0 }
    }

    // MARK: Tab bar + per-tab toolbar

    private var tabBar: some View {
        HStack {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Zelda.card)
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                    .frame(width: Self.tabWidth, height: 26)
                    .offset(x: CGFloat(model.tab) * Self.tabWidth)
                    .animation(.easeOut(duration: 0.2), value: model.tab)
                HStack(spacing: 0) {
                    tabButton(0) { Text("Transcript") }
                    tabButton(1) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("Notes")
                            if model.notesStale {
                                Circle()
                                    .fill(Zelda.amber)
                                    .frame(width: 4, height: 4)
                            }
                        }
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Zelda.radiusSm).fill(Zelda.surface2))

            Spacer()

            if model.tab == 0 {
                transcriptToolbar
            } else if model.record?.noteState == .done {
                notesToolbar
            }
        }
    }

    private func tabButton(_ index: Int, @ViewBuilder label: () -> some View) -> some View {
        Button { model.tab = index } label: {
            label()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.tab == index ? Zelda.foreground : Zelda.mutedFg)
                .frame(width: Self.tabWidth, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transcriptToolbar: some View {
        HStack(spacing: 10) {
            // Naming a voice is also reachable from every speaker caption;
            // this is the version you can find without knowing to look.
            if !model.speakerKeys.isEmpty {
                Menu {
                    ForEach(model.speakerKeys, id: \.self) { key in
                        Button("Name \(model.speakerMenuTitle(key))…") {
                            model.promptRenameSpeaker(key)
                        }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Name the people on this call")
            }

            Button { model.copyTranscript() } label: {
                Image(systemName: model.copiedTranscript ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy transcript")
            .disabled(model.segments.isEmpty)

            Menu {
                Button("Text (.txt)") { model.exportTranscript("txt") }
                Button("Markdown (.md)") { model.exportTranscript("md") }
                Button("Subtitles (.srt)") { model.exportTranscript("srt") }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export transcript")
            .disabled(model.segments.isEmpty)

            // Stays after rating, so a verdict can be seen and changed.
            if !model.isLive, !model.segments.isEmpty {
                thumb(.up, current: model.transcriptRating) { model.rateTranscript($0) }
                thumb(.down, current: model.transcriptRating) { model.rateTranscript($0) }
            }
        }
    }

    private var notesToolbar: some View {
        HStack(spacing: 10) {
            Button {
                if model.editingNotes { model.endEdit() } else { model.beginEdit() }
            } label: {
                Image(systemName: model.editingNotes ? "checkmark" : "pencil")
            }
            .buttonStyle(.borderless)
            .help(model.editingNotes ? "Done editing" : "Edit notes")
            .keyboardShortcut("e", modifiers: .command)

            Button { model.copyNotes() } label: {
                Image(systemName: model.copiedNotes ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy notes")

            Menu {
                Button("Markdown (.md)") { model.exportNotes("md") }
                Button("Text (.txt)") { model.exportNotes("txt") }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export notes")

            Button { model.regenerate() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Regenerate notes")
            // Regenerating under an open editor would race the draft.
            .disabled(model.editingNotes)

            thumb(.up, current: model.notesRating) { model.rateNotes($0) }
            thumb(.down, current: model.notesRating) { model.rateNotes($0) }
        }
    }

    // MARK: Tab content

    // MARK: Feedback (ADR 35)

    /// The one-time ask. Shown until the artefact has a rating; rating it
    /// (or clearing it from the toolbar) is the only way it comes back.
    private func ratingAsk(_ question: String, rating: MeetingRating?,
                           onRate: @escaping (MeetingRating) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(question)
                .font(.caption)
                .foregroundStyle(Zelda.mutedFg)
            Spacer()
            thumb(.up, current: rating, onRate: onRate)
            thumb(.down, current: rating, onRate: onRate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Zelda.radiusSm).fill(Zelda.surface2))
    }

    private func thumb(_ rating: MeetingRating, current: MeetingRating?,
                       onRate: @escaping (MeetingRating) -> Void) -> some View {
        let selected = current == rating
        let name = rating == .up ? "hand.thumbsup" : "hand.thumbsdown"
        return Button { onRate(rating) } label: {
            Image(systemName: selected ? "\(name).fill" : name)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Zelda.primary : Zelda.mutedFg)
        }
        .buttonStyle(.plain)
        .help(rating == .up ? "Good" : "Needs work")
    }

    @ViewBuilder private var content: some View {
        if model.tab == 0 {
            VStack(alignment: .leading, spacing: 10) {
                // Only for a finished meeting: rating a transcript that is
                // still being written asks about something that isn't done.
                if !model.isLive, !model.segments.isEmpty, model.transcriptRating == nil {
                    ratingAsk("Was this transcript accurate?", rating: model.transcriptRating) {
                        model.rateTranscript($0)
                    }
                    .padding(.horizontal, 16)
                }
                // The transcript pads its bubbles 16 pt internally; 12 here
                // lands them on the page's 28 pt gutter.
                MeetingTranscriptView(segments: model.segments, isLive: model.isLive,
                                      speakerNames: model.displayNames,
                                      onRenameSpeaker: { model.promptRenameSpeaker($0) })
                    .padding(.horizontal, 12)
            }
        } else {
            notesTab
        }
    }

    @ViewBuilder private var notesTab: some View {
        switch model.record?.noteState {
        case .generating(let completed, let total):
            generatingView(completed: completed, total: total)
        case .failed(let message):
            failedView(message)
        case .done:
            notesDoneView
        default:
            VStack(spacing: 10) {
                Text("No notes for this meeting.")
                    .foregroundStyle(Zelda.mutedFg)
                Button("Generate notes") { model.regenerate() }
                Button { model.createManualNotes() } label: {
                    Text("or write them yourself")
                        .font(.caption)
                        .foregroundStyle(Zelda.mutedFg)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func generatingView(completed: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            // TimelineView, not repeatForever: continuous animation off a
            // clock is the one pattern this toolchain animates reliably.
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Zelda.primary)
                            .frame(width: 7, height: 7)
                            .opacity(0.35 + 0.65 * (sin(t * 4 - Double(i) * 0.9) + 1) / 2)
                    }
                }
            }
            Text("Writing your notes… \(completed)/\(total)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Zelda.foreground)
            Text("usually under a minute — you can leave this page")
                .font(.caption)
                .foregroundStyle(Zelda.mutedFg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(Zelda.amber)
            Text(message)
                .foregroundStyle(Zelda.mutedFg)
                .multilineTextAlignment(.center)
            Button("Retry") { model.regenerate() }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notesDoneView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hidden while editing — its Regenerate would clobber the draft.
            if model.notesStale, !model.editingNotes {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Zelda.amber)
                    Text("The transcript changed after these notes were written")
                        .font(.caption)
                        .foregroundStyle(Zelda.foreground)
                    Spacer()
                    Button("Regenerate") { model.regenerate() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Zelda.radiusSm).fill(Zelda.amberContainer))
            }
            if model.notesRating == nil, !model.editingNotes {
                ratingAsk("Were these notes useful?", rating: model.notesRating) {
                    model.rateNotes($0)
                }
            }
            if model.editingNotes {
                MarkdownEditorView(text: model.draftNotes,
                                   onChange: { model.noteDraftChanged($0) },
                                   onEscape: { model.endEdit() },
                                   autofocus: true)
            } else {
                AttributedTextView(text: MarkdownRenderer.render(model.notes ?? "",
                                                                 ink: .labelColor,
                                                                 muted: .secondaryLabelColor))
            }
        }
        .padding(.horizontal, 28)
    }
}
