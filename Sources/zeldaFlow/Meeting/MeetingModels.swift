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
    /// "You:/Them:" lines in spoken order — the HASH and legacy-export shape
    /// (the port of OpenWhispr's buildOrderedTranscriptText: holdback releases
    /// commit out of spoken order, so sort by start, not by insertion).
    /// NEVER speaker-labeled: transcriptHash() is the notes-staleness anchor
    /// and must stay byte-stable across diarization and renames (ADR 31).
    /// The notes pipeline reads speakerTranscriptText(roster:) instead.
    func orderedTranscriptText() -> String {
        sorted { $0.start < $1.start }
            .map { "\($0.source == .you ? "You" : "Them"): \($0.text)" }
            .joined(separator: "\n")
    }

    /// The LLM-facing shape since ADR 38: same ordering, but each line
    /// carries the segment's roster label ("You:", "Priya:", "Speaker 2:").
    /// Kept apart from orderedTranscriptText() so the hash never moves.
    func speakerTranscriptText(roster: MeetingRoster) -> String {
        sorted { $0.start < $1.start }
            .map { "\(roster.label(for: $0)): \($0.text)" }
            .joined(separator: "\n")
    }

    /// SHA-256 over the ordered transcript — the staleness anchor for notes
    /// (the port of OpenWhispr's enhanced_at_content_hash).
    func transcriptHash() -> String {
        let digest = SHA256.hash(data: Data(orderedTranscriptText().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Roster (ADR 38)

/// The per-meeting mapping from stable speaker keys to display labels, built
/// once before notes generation and rebuilt on every render. Keys are
/// strings derived from the rename keys — "you" for the mic, "s0"/"s1"… for
/// diarized clusters, "s-1" for the undiarized far side — so they survive
/// JSON round-trips and never collide. A label resolves as
/// user rename ?? inferred name ?? default, and the user always wins.
struct MeetingRoster: Equatable {
    struct Entry: Equatable {
        let key: String
        let label: String
    }

    /// "you" first, then far-side keys in first-speech order.
    private(set) var entries: [Entry] = []
    private var byKey: [String: String] = [:]

    static func key(forRenameKey renameKey: Int) -> String { "s\(renameKey)" }

    /// `userNames` is meta.speakerNames (Int cluster keys); `inferred` is
    /// meta.inferredSpeakerNames (roster string keys). Duplicate labels
    /// de-collide by falling back to the default — a second speaker inferred
    /// as "Priya" when one already is stays "Speaker N", keeping
    /// key(forLabel:) bijective for the owner grammar.
    init(segments: [MeetingSegment],
         userNames: [Int: String] = [:],
         inferred: [String: String] = [:]) {
        var used: Set<String> = ["you"]
        entries.append(Entry(key: "you", label: "You"))
        byKey["you"] = "You"
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard let renameKey = segment.renameKey else { continue }
            let key = Self.key(forRenameKey: renameKey)
            guard byKey[key] == nil else { continue }
            let fallback = renameKey == MeetingSegment.unlabeledSpeakerKey
                ? "Them" : "Speaker \(renameKey + 1)"
            var label = userNames[renameKey] ?? inferred[key] ?? fallback
            if used.contains(label.lowercased()) { label = fallback }
            used.insert(label.lowercased())
            entries.append(Entry(key: key, label: label))
            byKey[key] = label
        }
    }

    func label(forKey key: String) -> String { byKey[key] ?? key }

    func label(for segment: MeetingSegment) -> String {
        guard let renameKey = segment.renameKey else { return "You" }
        return byKey[Self.key(forRenameKey: renameKey)] ?? "Them"
    }

    /// Every label the owner grammar may emit (the roster, "Unclear" is
    /// appended by the schema builder).
    var ownerLabels: [String] { entries.map(\.label) }

    /// Labels of everyone but the user — the free-text rename targets.
    var farSideEntries: [Entry] { entries.filter { $0.key != "you" } }

    func key(forLabel label: String) -> String? {
        entries.first { $0.label == label }?.key
    }

    /// key → label, the shape NotesDocument persists.
    var labelsByKey: [String: String] { byKey }
}

// MARK: - Structured notes document (ADR 38)

/// The merged, structured result of a notes run — notes.json, written next
/// to notes.md. notes.md is a RENDER of this document: renaming a speaker
/// re-renders in milliseconds from here, no LLM involved. Action owners are
/// stored as stable roster keys ("you"/"s0"/"unclear"), and `roster` records
/// the labels the model actually saw, so a later render can rewrite them in
/// free text too.
struct NotesDocument: Codable, Equatable {
    struct Action: Codable, Equatable {
        var owner: String   // roster key, or "unclear"
        var text: String
    }
    var version: Int = 1
    var summary: String
    var discussion: [String]
    var decisions: [String]
    var actions: [Action]
    var followups: [String]
    /// Roster at generation time: key → the label the LLM saw.
    var roster: [String: String]

    /// Markdown render under `labels` (key → current label; nil entries fall
    /// back to the generation-time roster). Two mechanisms: action owners
    /// resolve by KEY (exact), and free-text bullets get a word-boundary
    /// rewrite of each far-side generation label to its current label,
    /// longest-first. "You" is never free-text rewritten — too common a word
    /// to touch safely; its attribution rides only on the owner keys.
    func render(labels: [String: String]? = nil) -> String {
        let current = labels ?? roster
        func label(_ key: String) -> String { current[key] ?? roster[key] ?? key }
        let renames = roster
            .filter { $0.key != "you" }
            .compactMap { entry -> (String, String)? in
                let new = label(entry.key)
                return new == entry.value ? nil : (entry.value, new)
            }
            .sorted { $0.0.count > $1.0.count }
        func resolve(_ text: String) -> String {
            var out = text
            for (old, new) in renames {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: old) + "\\b"
                if let re = try? NSRegularExpression(pattern: pattern) {
                    out = re.stringByReplacingMatches(
                        in: out, range: NSRange(out.startIndex..., in: out),
                        withTemplate: NSRegularExpression.escapedTemplate(for: new))
                }
            }
            return out
        }

        var parts: [String] = []
        let opening = resolve(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        if !opening.isEmpty { parts.append(opening) }
        if !discussion.isEmpty {
            parts.append("## Key Discussion Points\n"
                + discussion.map { "- \(resolve($0))" }.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            parts.append("## Decisions Made\n"
                + decisions.map { "- \(resolve($0))" }.joined(separator: "\n"))
        }
        if !actions.isEmpty {
            parts.append("## Action Items\n" + actions.map { item in
                // No prefix for "unclear" — it would read as a person's name.
                let prefix = item.owner == "unclear" ? "" : "**\(label(item.owner))**: "
                return "- [ ] \(prefix)\(resolve(item.text))"
            }.joined(separator: "\n"))
        }
        if !followups.isEmpty {
            parts.append("## Follow-ups\n"
                + followups.map { "- \(resolve($0))" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
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
    /// Names inferred from the transcript by the local model (ADR 38), keyed
    /// by roster key ("s0", "s-1"). Kept APART from speakerNames so a user
    /// rename always wins and re-running inference can never clobber one.
    var inferredSpeakerNames: [String: String]?
    /// Thumbs on the two artefacts the user actually reads (ADR 35).
    /// Optional: absent means "never asked/answered", which is what the
    /// in-page prompt keys off.
    var transcriptRating: MeetingRating?
    var transcriptRatedAt: Date?
    var notesRating: MeetingRating?
    var notesRatedAt: Date?
}

extension MeetingMeta {
    /// meta.speakerNames keeps String keys (JSON friendliness); rosters and
    /// the UI want cluster indices.
    var speakerNamesByCluster: [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in speakerNames ?? [:] {
            if let index = Int(key) { out[index] = value }
        }
        return out
    }

    /// The roster this meta implies for `segments` — user renames over
    /// inferred names over defaults (ADR 38).
    func roster(for segments: [MeetingSegment]) -> MeetingRoster {
        MeetingRoster(segments: segments,
                      userNames: speakerNamesByCluster,
                      inferred: inferredSpeakerNames ?? [:])
    }
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
