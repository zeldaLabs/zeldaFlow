import Combine
import Foundation

/// JSONL store for the meeting notetaker (ADR 0027). Mirrors HistoryStore's
/// shape — serial queue, append-only FileHandle writes, ISO-8601 dates,
/// per-line `try?` decode so a torn final line from a crash is skipped, not
/// fatal, newest-N in memory — with three deliberate deviations, each
/// commented at its site:
///   (a) an injectable base directory, so `--evalmeeting` runs in a scratch
///       dir instead of the live Application Support tree;
///   (b) records mutate (noteState transitions, late Gemma titles), which a
///       pure append-only log can't express — so every mutation is an append
///       and load folds last-record-per-id-wins, preserving crash safety;
///       compaction at launch bounds the resulting file growth;
///   (c) per-meeting folders, because a meeting is not one line: it owns a
///       transcript log, notes, meta and the audio spool.
///
/// Layout:
///   <baseDir>/meetings.jsonl                — MeetingRecord per line (index;
///                                             `deleted: true` tombstones)
///   <baseDir>/meetings/<uuid>/transcript.jsonl — TranscriptLine per line
///   <baseDir>/meetings/<uuid>/notes.md         — atomic write
///   <baseDir>/meetings/<uuid>/meta.json        — MeetingMeta, atomic rewrite
///                                                (it is tiny)
///   <baseDir>/meetings/<uuid>/mic.wav, system.wav — the audio spool writes
///                                                here via folderURL(_:)
///
/// No fsync anywhere (HistoryStore parity): the OS flushes dirty pages within
/// seconds, and the stated loss budget — see appendTranscriptLine — is
/// already dominated by audio that hasn't been transcribed yet, so an fsync
/// per line would cost I/O without moving the real number.
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// Newest-first, live records only (tombstones excluded), capped like
    /// HistoryStore's 500 so a years-old archive can't bloat the menu app.
    @Published private(set) var records: [MeetingRecord] = []

    private let maxInMemory = 500
    private let queue = DispatchQueue(label: "zeldaflow.meetings", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseDir: URL

    // Queue-confined fold of the whole index: last record per id. Records are
    // a few hundred bytes each, so even years of meetings stay trivially in
    // memory — this is what lets delete/sweep/orphan checks work without
    // re-reading the file, while `records` stays capped for the UI.
    private var byID: [UUID: MeetingRecord] = [:]
    private var indexLineCount = 0

    // Deviation (a) from HistoryStore's `private init()`: the base directory
    // is injectable so `--evalmeeting` exercises the full store against a
    // scratch dir without touching (or needing) the user's real meetings.
    // The default preserves singleton behavior via `shared`.
    init(baseDir: URL = Paths.appSupport) {
        self.baseDir = baseDir
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - Paths

    private var indexURL: URL { baseDir.appendingPathComponent("meetings.jsonl") }
    private var meetingsDir: URL { baseDir.appendingPathComponent("meetings", isDirectory: true) }

    /// The per-meeting folder — also where the audio spool lives (mic.wav /
    /// system.wav). Pure derivation; create(_:meta:) is what makes the folder.
    func folderURL(_ id: UUID) -> URL {
        meetingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func transcriptURL(_ id: UUID) -> URL {
        folderURL(id).appendingPathComponent("transcript.jsonl")
    }
    private func notesURL(_ id: UUID) -> URL {
        folderURL(id).appendingPathComponent("notes.md")
    }
    private func metaURL(_ id: UUID) -> URL {
        folderURL(id).appendingPathComponent("meta.json")
    }

    // MARK: - Load + compaction (deviation b)

    private func load() {
        queue.async {
            try? FileManager.default.createDirectory(at: self.meetingsDir,
                                                     withIntermediateDirectories: true)
            var folded: [UUID: MeetingRecord] = [:]
            var lines = 0
            if let data = try? Data(contentsOf: self.indexURL),
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    lines += 1
                    // Last record per id wins: a later append (title arrived,
                    // noteState moved, tombstone) supersedes every earlier
                    // line for that meeting. `try?` skips a torn final line
                    // from a crash mid-write, same as HistoryStore.
                    if let record = try? self.decoder.decode(MeetingRecord.self,
                                                             from: Data(line.utf8)) {
                        folded[record.id] = record
                    }
                }
            }
            self.byID = folded
            self.indexLineCount = lines

            let live = folded.values.filter { $0.deleted != true }
            // Compact when the file holds > 4x its live records. A meeting's
            // normal life appends ~3 lines (create, title, notes done), so 4x
            // means real garbage — superseded lines and tombstones — not
            // steady-state churn; below that the rewrite isn't worth doing.
            if lines > 4 * live.count {
                self.compactLocked()
            }

            let newestFirst = live.sorted { $0.date > $1.date }.prefix(self.maxInMemory)
            let published = Array(newestFirst)
            DispatchQueue.main.async { self.records = published }
        }
    }

    /// Public compaction hook; the work runs on the store queue.
    func compact() {
        queue.async { self.compactLocked() }
    }

    /// Rewrites the index to exactly one line per live record, dropping
    /// superseded lines and tombstones (a tombstone has done its job once the
    /// folder is gone and no earlier line for that id survives). Atomic
    /// rewrite is safe here precisely because the fold makes the file's
    /// content reproducible — the append-only rule protects in-flight
    /// mutations, not this whole-file replacement of settled state.
    /// Must run on `queue`.
    private func compactLocked() {
        let live = byID.values.filter { $0.deleted != true }
            // Date-ascending restores the order appends would have produced,
            // so post-compaction appends keep the file roughly chronological.
            .sorted { $0.date < $1.date }
        var out = Data()
        for record in live {
            guard let data = try? encoder.encode(record) else { continue }
            out.append(data)
            out.append(0x0A)
        }
        do {
            try out.write(to: indexURL, options: .atomic)
            byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            if indexLineCount != live.count {
                Log.info("MeetingStore: compacted index \(indexLineCount) -> \(live.count) lines")
            }
            indexLineCount = live.count
        } catch {
            // Failed compaction is harmless: the appended log is still the
            // source of truth and the next launch retries.
            Log.error("MeetingStore: compaction failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Index mutations (append-only, deviation b)

    func create(_ record: MeetingRecord, meta: MeetingMeta) {
        DispatchQueue.main.async {
            self.records.insert(record, at: 0)
            if self.records.count > self.maxInMemory {
                self.records.removeLast(self.records.count - self.maxInMemory)
            }
        }
        queue.async {
            // Folder and meta land before the index line: an index entry must
            // never reference a folder that doesn't exist yet. The reverse
            // crash order (line without folder) would surface a meeting the
            // detail view can't open; this order at worst leaks one empty
            // folder, which the retention sweep never resurrects.
            try? FileManager.default.createDirectory(at: self.folderURL(record.id),
                                                     withIntermediateDirectories: true)
            self.writeMetaLocked(record.id, meta)
            self.appendIndexLineLocked(record)
        }
    }

    func update(_ record: MeetingRecord) {
        // Synchronous when already on main: a caller that updates and then
        // reads `records` in the same main-actor job must see its own write —
        // deferring via main.async let setNoteState read a stale copy and
        // clobber durationSeconds/title back to old values (2026-08-08).
        onMain {
            if let i = self.records.firstIndex(where: { $0.id == record.id }) {
                self.records[i] = record
            }
        }
        queue.async { self.appendIndexLineLocked(record) }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Tombstone in the index (crash-safe append; compaction reaps it later)
    /// plus immediate removal of the folder — transcript, notes and audio go
    /// now, not at the next compaction.
    func delete(_ id: UUID) {
        onMain {
            self.records.removeAll { $0.id == id }
        }
        queue.async {
            if var tombstone = self.byID[id] {
                tombstone.deleted = true
                self.appendIndexLineLocked(tombstone)
            }
            try? FileManager.default.removeItem(at: self.folderURL(id))
        }
    }

    /// Must run on `queue`. Also maintains the fold, so later mutations and
    /// the orphan/sweep checks see this write without re-reading the file.
    private func appendIndexLineLocked(_ record: MeetingRecord) {
        byID[record.id] = record
        guard let data = try? encoder.encode(record) else { return }
        appendLineLocked(data, to: indexURL)
        indexLineCount += 1
    }

    /// HistoryStore's append verbatim: create-if-missing, seek to end, write
    /// line. Must run on `queue`.
    private func appendLineLocked(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            // createFile fails when the parent folder is gone (meeting was
            // deleted mid-flight); the write below then silently drops, which
            // is exactly right — never resurrect a deleted meeting's folder.
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    // MARK: - Meta (atomic rewrite — the one non-append file, it is tiny)

    func updateMeta(_ id: UUID, mutate: @escaping (inout MeetingMeta) -> Void) {
        queue.async {
            guard var meta = self.readMetaLocked(id) else {
                Log.error("MeetingStore: updateMeta(\(id.uuidString)) but meta.json is unreadable")
                return
            }
            mutate(&meta)
            self.writeMetaLocked(id, meta)
        }
    }

    func loadMeta(_ id: UUID) -> MeetingMeta? {
        queue.sync { readMetaLocked(id) }
    }

    /// Must run on `queue`.
    private func readMetaLocked(_ id: UUID) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? decoder.decode(MeetingMeta.self, from: data)
    }

    /// Must run on `queue`. Atomic: meta.json is whole state, not a log, and
    /// a torn half-JSON would be unreadable — .atomic makes the swap
    /// all-or-nothing at ~200 bytes of cost.
    private func writeMetaLocked(_ id: UUID, _ meta: MeetingMeta) {
        guard let data = try? encoder.encode(meta) else { return }
        do {
            try data.write(to: metaURL(id), options: .atomic)
        } catch {
            Log.error("MeetingStore: meta write failed for \(id.uuidString): \(error.localizedDescription)")
        }
    }

    // MARK: - Transcript

    /// Called at segment commit: two channels emitting one segment per 5 s
    /// chunk (ported: LOCAL_MEETING_CHUNK_INTERVAL_MS = 5000, ipcHandlers.js)
    /// is ~0.4 Hz — negligible I/O, so every commit goes straight to disk.
    ///
    /// Loss window on a hard crash (no fsync, OS page flush only): at most
    /// one chunk interval — 5 s — of system audio awaiting transcription,
    /// and chunk + holdback ≈ 11 s of risky mic, because a risky segment is
    /// held 6 s past its 5 s chunk before it may commit (ported:
    /// LOCAL_RISKY_MIC_SEGMENT_HOLDBACK_MS = chunk + 1000, ipcHandlers.js).
    /// Both are audio not yet in this file — the write path adds nothing
    /// measurable on top, which is why fsync isn't bought here.
    func appendTranscriptLine(_ id: UUID, _ line: TranscriptLine) {
        queue.async {
            guard let data = try? self.encoder.encode(line) else { return }
            self.appendLineLocked(data, to: self.transcriptURL(id))
        }
    }

    /// Full transcript with retraction tombstones applied (a segment later
    /// identified as far-side echo is appended as a retraction, never erased
    /// in place — same crash-safety rule as the index). Synchronous: call off
    /// the main thread for big meetings — a 4 h meeting is ~5,800 lines,
    /// single-digit milliseconds to parse but not free.
    func loadSegments(_ id: UUID) -> [MeetingSegment] {
        queue.sync {
            guard let data = try? Data(contentsOf: transcriptURL(id)),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            var segments: [MeetingSegment] = []
            var retracted: Set<UUID> = []
            for line in text.split(separator: "\n") {
                guard let entry = try? decoder.decode(TranscriptLine.self,
                                                      from: Data(line.utf8)) else { continue }
                switch entry {
                case .segment(let segment): segments.append(segment)
                case .retraction(let retraction): retracted.insert(retraction.retractedID)
                }
            }
            return segments.filter { !retracted.contains($0.id) }
        }
    }

    /// Fires (on main) after each successful rewriteTranscript — the signal
    /// an open detail view uses to re-read segments it loaded before the
    /// polish/diarization passes landed. Nothing watches files here.
    let transcriptRewrites = PassthroughSubject<UUID, Never>()

    /// Atomic whole-file replacement for the transcript polish and
    /// diarization passes — the ONE sanctioned rewrite of transcript.jsonl
    /// (everything live appends). tmp + rename, so a crash mid-write leaves
    /// the original intact. The segments handed in already have retractions
    /// applied, so the rewritten file carries none.
    func rewriteTranscript(_ id: UUID, segments: [MeetingSegment]) {
        queue.async {
            var data = Data()
            for seg in segments {
                guard let line = try? self.encoder.encode(TranscriptLine.segment(seg))
                else { continue }
                data.append(line)
                data.append(0x0A)
            }
            let url = self.transcriptURL(id)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("transcript.jsonl.tmp")
            do {
                try data.write(to: tmp)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                DispatchQueue.main.async { self.transcriptRewrites.send(id) }
            } catch {
                Log.error("MeetingStore: transcript rewrite failed: \(error)")
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    // MARK: - Notes

    /// Atomic: notes are regenerated whole, and a crash mid-write must leave
    /// the previous notes intact rather than half of each.
    func writeNotes(_ id: UUID, markdown: String) {
        queue.async {
            do {
                try Data(markdown.utf8).write(to: self.notesURL(id), options: .atomic)
            } catch {
                Log.error("MeetingStore: notes write failed for \(id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    func loadNotes(_ id: UUID) -> String? {
        queue.sync {
            guard let data = try? Data(contentsOf: notesURL(id)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Crash recovery + retention

    /// Meetings whose last index state still looks mid-recording: noteState
    /// == .none and meta.endedAt == nil — a stop always sets endedAt, so a
    /// live-looking record at launch means the app died mid-meeting and the
    /// bootstrap sweep must finalize it (stopReason .crashRecovery). Missing
    /// or unreadable meta counts as orphaned: create() writes meta before the
    /// index line, so an index entry without meta is itself crash debris.
    /// Oldest-first, so recovery finalizes in the order the meetings started.
    func orphanedRecordingIDs() -> [UUID] {
        queue.sync {
            byID.values
                .filter { $0.deleted != true && $0.noteState == NoteState.none }
                .filter { record in
                    guard let meta = readMetaLocked(record.id) else { return true }
                    return meta.endedAt == nil
                }
                .sorted { $0.date < $1.date }
                .map(\.id)
        }
    }

    /// Retention sweep, run at launch and every 24 h by the lifecycle layer:
    /// tombstone + delete every folder past the cutoff, then compact.
    /// retentionDays <= 0 means keep forever (ported: retentionSettings.js,
    /// transcriptRetentionDays 0 = keep transcripts forever).
    func sweep(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        queue.async {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            var expired: [UUID] = []
            for record in self.byID.values
            where record.deleted != true && record.date < cutoff {
                var tombstone = record
                tombstone.deleted = true
                // Tombstone first, folder second: if we crash between the
                // two, the record is already dead in the index and the next
                // sweep re-deletes the surviving folder.
                self.appendIndexLineLocked(tombstone)
                try? FileManager.default.removeItem(at: self.folderURL(record.id))
                expired.append(record.id)
            }
            // Compact unconditionally: the sweep is the store's only periodic
            // hook, so it also reaps ordinary churn (superseded lines from
            // titles and noteState flips) that never crossed the launch-time
            // 4x threshold.
            self.compactLocked()
            guard !expired.isEmpty else { return }
            Log.info("MeetingStore: swept \(expired.count) meetings past \(retentionDays) d retention")
            let gone = Set(expired)
            DispatchQueue.main.async {
                self.records.removeAll { gone.contains($0.id) }
            }
        }
    }
}
