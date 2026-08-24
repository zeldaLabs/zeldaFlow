import Foundation

// Transcript/notes export in four shapes (txt, markdown, srt, json) plus the
// plain LLM-facing text. Port of OpenWhispr's transcriptFormatter.js with the
// speaker-mapping machinery removed: their resolveSpeaker walks names,
// diarization labels and mappings; our pipeline has exactly two channels, so
// the whole function collapses to You (mic) / Them (system audio) — the same
// labels MeetingModels.orderedTranscriptText() already emits.

enum MeetingExporter {

    // MARK: - Merging

    /// Consecutive same-source segments whose gap is under 2 s collapse into
    /// one block (ported: transcriptFormatter.js mergeSegments,
    /// `ts - lastTimestamp < 2`). Two refinements over the source:
    ///
    /// - Their segments carry a single timestamp, so "gap" there is really
    ///   next.start - prev.start (they track `lastTimestamp = ts` and mirror
    ///   it into `endTimestamp`). Our chunks have real end bounds, so the gap
    ///   is the honest next.start - prev.end — measured against ~5 s chunks,
    ///   their start-based gap would refuse to merge back-to-back chunks of
    ///   one uninterrupted speaker (gap ≈ 5 s > 2 s), which is exactly the
    ///   case merging exists for.
    /// - Sorted by start first: holdback releases commit out of spoken order
    ///   (see MeetingSegment.committedAt), and merging in commit order would
    ///   interleave one speaker's run into several blocks. Their DB rows
    ///   arrive pre-sorted, so the JS never needed this.
    ///
    /// Empty-after-trim segments are dropped and do not break a run, matching
    /// their `continue` before the lastTimestamp update.
    static func mergeSegments(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        var merged: [MeetingSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // Same source is no longer enough: two different far-side
            // speakers within 2 s must stay separate blocks (ADR 31).
            if let last = merged.last, last.source == seg.source,
               last.speaker == seg.speaker,
               seg.start - last.end < 2 {
                // Rebuild rather than mutate: MeetingSegment is all-let by
                // design (transcript lines are immutable once written).
                // capturedAt follows the new end to keep the model's
                // "capturedAt = epoch + end" invariant; risky is sticky —
                // a block containing any far-side-suspect text is suspect.
                merged[merged.count - 1] = MeetingSegment(
                    id: last.id,
                    source: last.source,
                    text: last.text + " " + text,
                    start: last.start,
                    end: seg.end,
                    capturedAt: seg.capturedAt,
                    committedAt: max(last.committedAt, seg.committedAt),
                    risky: last.risky || seg.risky,
                    speaker: last.speaker)
            } else {
                merged.append(MeetingSegment(
                    id: seg.id, source: seg.source, text: text,
                    start: seg.start, end: seg.end,
                    capturedAt: seg.capturedAt, committedAt: seg.committedAt,
                    risky: seg.risky, speaker: seg.speaker))
            }
        }
        return merged
    }

    // MARK: - Plain text (.txt)

    /// Title/date header over `[HH:MM:SS] You:` blocks
    /// (ported: transcriptFormatter.js formatTxt, minus the participants line
    /// — calendar participants don't exist in our model).
    static func txt(record: MeetingRecord, segments: [MeetingSegment],
                    names: [Int: String] = [:]) -> String {
        var lines = [record.displayTitle, headerDateString(record.date)]
        lines.append(contentsOf: ["", "──────────────────────────────────", ""])
        for seg in mergeSegments(segments) {
            lines.append("[\(clockStamp(seg.start))] \(seg.displayLabel(names: names)):")
            lines.append(seg.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown (.md)

    /// `**You** \`HH:MM:SS\`` blocks under an H1 + bold date header
    /// (ported: transcriptFormatter.js formatMd, minus participants).
    static func markdown(record: MeetingRecord, segments: [MeetingSegment],
                         names: [Int: String] = [:]) -> String {
        var lines = ["# \(record.displayTitle)", "",
                     "**Date:** \(headerDateString(record.date))"]
        lines.append(contentsOf: ["", "---", ""])
        for seg in mergeSegments(segments) {
            lines.append("**\(seg.displayLabel(names: names))** `\(clockStamp(seg.start))`")
            lines.append(seg.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SubRip (.srt)

    /// Numbered `HH:MM:SS,mmm --> HH:MM:SS,mmm` cues
    /// (ported: transcriptFormatter.js formatSrt). Improvement over the
    /// source: they fake each cue's end as the next cue's start (+3 s for the
    /// last) because their segments have no end bound — ours carry real chunk
    /// bounds, so a cue disappears when its speech actually stops instead of
    /// hanging on screen through the silence before the next speaker.
    static func srt(segments: [MeetingSegment], names: [Int: String] = [:]) -> String {
        var entries: [String] = []
        for (i, seg) in mergeSegments(segments).enumerated() {
            entries.append("\(i + 1)")
            entries.append("\(srtStamp(seg.start)) --> \(srtStamp(seg.end))")
            entries.append("\(seg.displayLabel(names: names)): \(seg.text)")
            entries.append("")
        }
        return entries.joined(separator: "\n")
    }

    // MARK: - JSON (.json)

    /// Their metadata + segments shape (ported: transcriptFormatter.js
    /// formatJson) via JSONEncoder — ISO-8601 dates instead of their locale
    /// string (machine-readable output should not depend on the exporting
    /// Mac's locale), prettyPrinted + sortedKeys so repeated exports of the
    /// same meeting diff cleanly.
    static func json(record: MeetingRecord, segments: [MeetingSegment],
                     names: [Int: String] = [:]) -> Data? {
        let merged = mergeSegments(segments)
        // Insertion-order unique, matching their JS Set semantics.
        var speakers: [String] = []
        for seg in merged {
            let label = seg.displayLabel(names: names)
            if !speakers.contains(label) { speakers.append(label) }
        }
        let export = ExportJSON(
            metadata: .init(
                title: record.displayTitle,
                date: record.date,
                // Their Math.round(lastSeg.endTimestamp): duration measured
                // from the transcript itself, not the record — the record's
                // duration includes trailing silence before the stop.
                durationSeconds: Int((merged.last?.end ?? 0).rounded()),
                speakerCount: speakers.count,
                segmentCount: merged.count),
            speakers: speakers,
            segments: merged.map {
                .init(speaker: $0.displayLabel(names: names),
                      timestamp: $0.start, text: $0.text)
            })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(export)
        } catch {
            Log.error("Meeting JSON export failed: \(error)")
            return nil
        }
    }

    /// The wire shape of formatJson, snake_case like theirs so downstream
    /// tooling written against OpenWhispr exports keeps working.
    private struct ExportJSON: Encodable {
        struct Metadata: Encodable {
            let title: String
            let date: Date
            let durationSeconds: Int
            let speakerCount: Int
            let segmentCount: Int
            enum CodingKeys: String, CodingKey {
                case title, date
                case durationSeconds = "duration_seconds"
                case speakerCount = "speaker_count"
                case segmentCount = "segment_count"
            }
        }
        struct Segment: Encodable {
            let speaker: String
            let timestamp: TimeInterval
            let text: String
        }
        let metadata: Metadata
        let speakers: [String]
        let segments: [Segment]
    }

    // MARK: - Plain transcript

    /// "You: …\nThem: …" in spoken order — the exact text the notes LLM sees
    /// and the transcriptHash() input, so copy-to-clipboard matches both.
    static func plainTranscript(_ segments: [MeetingSegment]) -> String {
        segments.orderedTranscriptText()
    }
}

// MARK: - Format helpers (fileprivate: other Meeting files ship their own)

// Speaker labels come from MeetingSegment.displayLabel — the un-collapse of
// OpenWhispr's resolveSpeaker (ADR 31): You / Them / "Speaker N" / rename.

/// HH:MM:SS, floor of seconds (ported: transcriptFormatter.js
/// formatTimestamp; offsets are sample-count derived and never negative,
/// so truncation and floor coincide).
private func clockStamp(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d",
                  total / 3600, (total % 3600) / 60, total % 60)
}

/// HH:MM:SS,mmm — SubRip's comma millisecond form, rounded to the
/// millisecond first so 1.9996 s renders 00:00:02,000 and not 00:00:01,1000
/// (ported: transcriptFormatter.js formatSrtTimestamp, same
/// Math.round(seconds * 1000) order of operations).
private func srtStamp(_ seconds: TimeInterval) -> String {
    let totalMs = Int((seconds * 1000).rounded())
    let total = totalMs / 1000
    return String(format: "%02d:%02d:%02d,%03d",
                  total / 3600, (total % 3600) / 60, total % 60,
                  totalMs % 1000)
}

/// Long date + short time in the exporting Mac's locale — the DateFormatter
/// twin of their `toLocaleDateString(undefined, {month:"long",…}) + " " +
/// toLocaleTimeString(…)` (ported: transcriptFormatter.js extractMetadata).
/// Human-facing headers follow the locale; the JSON export deliberately
/// does not (see json(record:segments:)).
private func headerDateString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .long
    f.timeStyle = .short
    return f.string(from: date)
}
