import Foundation
import CryptoKit

// Shared vocabulary of the meeting notetaker (ADR 0027). Everything here is
// a pure value type or protocol — capture, transcription, storage, notes and
// UI all build against this file and nothing else of each other.

// MARK: - Segments

/// One transcribed chunk of one channel. Finals only: the local chunked
/// pipeline emits a segment per ~5 s chunk per channel and never produces
/// partials (OpenWhispr's local mode behaves identically) — a `kind` field
/// would imply a state the pipeline cannot produce.
struct MeetingSegment: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case you    // the mic channel — the user
        case them   // the system-audio channel — everyone else
    }
    let id: UUID
    let source: Source
    let text: String
    /// Seconds from meeting start, derived from per-channel sample counters
    /// anchored to one meeting epoch — sample counts can't drift, timers can.
    let start: TimeInterval
    let end: TimeInterval
    /// Meeting epoch + `end` — the clock the ±6 s dedup window runs on.
    let capturedAt: Date
    /// When the segment entered the transcript. The 4 s retract race runs on
    /// this too: a held-back segment commits long after it was captured, and
    /// without the commit-time comparison a released segment could never be
    /// retracted by a late system transcript.
    let committedAt: Date
    /// Captured while the far side was speaking (or in the 1.5 s startup
    /// warmup): held back before commit and eligible for late retraction.
    let risky: Bool
    /// Post-meeting diarization cluster on the system channel (ADR 31):
    /// 0-based by first speech time. nil = mic channel, undiarized meeting,
    /// or a segment the aligner couldn't attribute confidently. Display-only
    /// — dedup and channel behavior key on `source`, and the LLM/hash text
    /// (orderedTranscriptText) deliberately never sees it.
    let speaker: Int?

    /// Explicit init so `speaker` can default: every pre-diarization
    /// constructor site keeps compiling (and building) unchanged.
    init(id: UUID, source: Source, text: String,
         start: TimeInterval, end: TimeInterval,
         capturedAt: Date, committedAt: Date, risky: Bool,
         speaker: Int? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.start = start
        self.end = end
        self.capturedAt = capturedAt
        self.committedAt = committedAt
        self.risky = risky
        self.speaker = speaker
    }

    /// Display label: "You", "Them" (undiarized), or "Speaker N" / the
    /// user's per-meeting rename. NOT the LLM/hash label.
    ///
    /// An undiarized far side is nameable too — a 1:1 call has one other
    /// person and naming them is the whole point — so it renames under the
    /// reserved key `unlabeledSpeakerKey`.
    func displayLabel(names: [Int: String] = [:]) -> String {
        guard source == .them else { return "You" }
        guard let speaker else {
            return names[MeetingSegment.unlabeledSpeakerKey] ?? "Them"
        }
        return names[speaker] ?? "Speaker \(speaker + 1)"
    }

    /// Rename key for far-side segments diarization never split (a 1:1 call,
    /// or diarization off/unavailable). Negative so it can never collide with
    /// a real 0-based cluster index.
    static let unlabeledSpeakerKey = -1

    /// The speaker key this segment renames under, or nil for the mic.
    var renameKey: Int? {
        source == .them ? (speaker ?? MeetingSegment.unlabeledSpeakerKey) : nil
    }
}

/// Tombstone appended to transcript.jsonl when a committed segment is later
/// identified as far-side echo — an append, never a rewrite, for crash safety.
struct MeetingRetraction: Codable, Equatable {
    let retractedID: UUID
    let at: Date
}

/// One line of transcript.jsonl.
enum TranscriptLine: Codable, Equatable {
    case segment(MeetingSegment)
    case retraction(MeetingRetraction)
}

extension Array where Element == MeetingSegment {
    /// "You:/Them:" lines in spoken order — the LLM-facing and export shape
    /// (the port of OpenWhispr's buildOrderedTranscriptText: holdback releases
    /// commit out of spoken order, so sort by start, not by insertion).
    func orderedTranscriptText() -> String {
        sorted { $0.start < $1.start }
            .map { "\($0.source == .you ? "You" : "Them"): \($0.text)" }
            .joined(separator: "\n")
    }

    /// SHA-256 over the ordered transcript — the staleness anchor for notes
    /// (the port of OpenWhispr's enhanced_at_content_hash).
    func transcriptHash() -> String {
        let digest = SHA256.hash(data: Data(orderedTranscriptText().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Feedback

/// A thumbs rating on one artefact of a meeting (ADR 35). Deliberately two
/// values and nothing else: it records whether the output was good enough,
/// which is all a thumb can honestly carry.
enum MeetingRating: String, Codable, Equatable {
    case up
    case down
}

// MARK: - Notes state

enum NoteState: Codable, Equatable {
    case none
    case generating(completed: Int, total: Int)   // UI: "Writing notes… 7/17"
    case done
    case failed(String)                           // transcript intact; Retry stays
}

// MARK: - Records (meetings.jsonl index + per-meeting meta.json)

/// One line of meetings.jsonl. Append-only with last-record-per-id wins, so
/// mutations (late title, note-state transitions) stay crash-safe appends;
/// `deleted` is the discard tombstone.
struct MeetingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var date: Date
    var title: String              // Gemma 3-8 word title; renameable; "" until generated
    var durationSeconds: Double
    var appName: String            // "Zoom", "Google Meet", … or "" when unknown
    var noteState: NoteState
    var deleted: Bool?

    var displayTitle: String {
        if !title.isEmpty { return title }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Meeting · \(f.string(from: date))"
    }
}

/// Full mutable state of one meeting — meetings/<id>/meta.json, rewritten
/// atomically (it is tiny; the transcript is the file that only ever appends).
struct MeetingMeta: Codable, Equatable {
    var schemaVersion: Int = 1
    var startedAt: Date
    var endedAt: Date?
    var trigger: String            // triggering bundle ID, or "manual"
    var appName: String
    var stopReason: String?
    /// Hash of the transcript when notes were last generated; nil = never.
    var notesHash: String?
    var notesGeneratedAt: Date?
    var notesModel: String?
    /// When the user last hand-edited notes.md; nil = untouched since
    /// generation. Regenerate warns before clobbering when set.
    var notesEditedAt: Date?
    /// Diarization result (ADR 31): clusters found on the system channel;
    /// nil = never diarized, 1 = single remote voice (no labels shown).
    var speakerCount: Int?
    /// User renames per cluster ("0" → "Priya"). String keys because Swift
    /// encodes [Int:String] as a JSON array. Renames never touch the
    /// transcript file or its hash.
    var speakerNames: [String: String]?
    var diarizedAt: Date?
    /// Thumbs on the two artefacts the user actually reads (ADR 35).
    /// Optional: absent means "never asked/answered", which is what the
    /// in-page prompt keys off.
    var transcriptRating: MeetingRating?
    var transcriptRatedAt: Date?
    var notesRating: MeetingRating?
    var notesRatedAt: Date?
}

// MARK: - Lifecycle vocabulary

struct MeetingTrigger: Equatable {
    enum Kind: String { case autoApp, autoBrowser, manual }
    let kind: Kind
    let bundleID: String?
    let appName: String            // display name: "Zoom", "Google Meet", …

    static let manual = MeetingTrigger(kind: .manual, bundleID: nil, appName: "")
}

enum MeetingStopReason: String {
    case micIdle        // holder released the mic ≥ 30 s — the call ended
    case appQuit        // triggering app terminated (accelerated stop)
    case sleep          // lid closed / system sleep = user left the meeting
    case manual         // user pressed Stop
    case discard        // user pressed Discard — nothing is kept
    case maxDuration    // 4 h safety cap
    case diskFull       // free space fell under the floor mid-meeting
    case crashRecovery  // finalized by the bootstrap sweep after a crash
}

// MARK: - Capture → transcription seam

/// Called on the meeting pipeline queue with ~100 ms chunks of 16 kHz mono
/// Float32; offsets are seconds from meeting start (sample-count derived).
protocol MeetingAudioConsumer: AnyObject {
    func micChunk(_ samples: [Float], at offset: TimeInterval)
    func systemChunk(_ samples: [Float], at offset: TimeInterval)
}

// MARK: - Day grouping (meetings list UI)

enum MeetingDayGroup {
    /// "Today" / "Yesterday" / "Friday, Aug 1" (this week) / "Jul 12, 2026".
    static func label(for date: Date, now: Date = Date(),
                      calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let f = DateFormatter()
        let days = calendar.dateComponents([.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)).day ?? 99
        f.dateFormat = days < 7 ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// Newest-first records → (label, records) sections, preserving order.
    static func grouped(_ records: [MeetingRecord], now: Date = Date(),
                        calendar: Calendar = .current)
        -> [(label: String, records: [MeetingRecord])] {
        var out: [(label: String, records: [MeetingRecord])] = []
        for r in records {
            let label = Self.label(for: r.date, now: now, calendar: calendar)
            if out.last?.label == label {
                out[out.count - 1].records.append(r)
            } else {
                out.append((label, [r]))
            }
        }
        return out
    }
}
