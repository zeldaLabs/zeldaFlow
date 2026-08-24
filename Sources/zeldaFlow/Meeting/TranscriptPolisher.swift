import Foundation

/// Post-meeting transcript polish: the same resident Gemma that cleans
/// dictation, applied to the meeting transcript before notes generate —
/// fixing what greedy Whisper decoding got wrong (punctuation, casing,
/// clearly mis-heard words) in BOTH channels.
///
/// The transcript is the user's record of what people said, so unlike notes
/// this pass is fail-closed at every level (the dictation cleaner's shrink
/// sanity check, taken further):
///   - server not ready, or a batch fails twice → those segments keep their
///     raw text; polish never blocks or fails the meeting.
///   - a reply with the wrong line count is discarded whole — index order is
///     the only thing tying a correction to its segment, and a misaligned
///     reply could put words in the wrong speaker's mouth.
///   - per line: an empty, runaway (>3×) or collapsed (<1/4) correction
///     keeps the original text.
///
/// Batches follow MeetingNotesGenerator's conventions (one 4,096-token
/// context per call; one call at a time; dictation holdback between calls),
/// but the budget is smaller because unlike a map call the reply here is as
/// large as the input.
enum TranscriptPolisher {

    /// Input chars per call. ~750 input tokens + a same-size reply + the
    /// system prompt + Gemma's ~470-token unswitchable chain-of-thought
    /// still sit well inside the 4,096-token window.
    nonisolated static let batchCharBudget = 3_000
    /// Reply cap: the corrected lines mirror the input (~750 tokens) plus
    /// JSON scaffolding and chain-of-thought.
    nonisolated static let replyMaxTokens = 1_600

    /// KV-cache rule (CleanupService precedent): nothing varying — no batch
    /// numbers, no counts. The glossary is appended by systemPrompt(_:)
    /// exactly like the dictation cleaner's, because the TEXT domain is
    /// where the user's vocabulary belongs: here it can only fix spellings,
    /// never inject words into audio (the 2026-08-08 lesson).
    nonisolated static let basePrompt = """
        You correct speech-recognition errors in a meeting transcript. The user message is numbered lines, each labelled "You" or "Them" (different speakers).
        Rules:
        - Return the corrected text of EVERY line: same order, exactly one output line per input line.
        - Fix only recognition mistakes: punctuation, capitalisation, and clearly mis-heard words that context makes obvious.
        - Never add, remove, merge, split, reorder, summarise or translate lines. Never change what a speaker meant. When unsure, return the line unchanged.
        - Output the text only — no numbering, no "You:"/"Them:" labels.
        - A line may be in any language: correct it in its own language and script.
        """

    nonisolated static func systemPrompt(dictionary: [String]) -> String {
        var p = basePrompt
        if !dictionary.isEmpty {
            p += "\nGlossary (correct spellings): \(dictionary.joined(separator: ", "))."
        }
        return p
    }

    nonisolated static let schema: CleanupService.JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "lines": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ]),
        ]),
        "required": .array([.string("lines")]),
        "additionalProperties": .bool(false),
    ])

    private struct Reply: Decodable { let lines: [String] }

    // MARK: - Pure pieces (internal for the eval suite)

    /// Spoken-order batches that never split a segment. Returns index ranges
    /// into the SORTED array it also returns — index order is the alignment
    /// contract with the model's reply.
    nonisolated static func batches(_ segments: [MeetingSegment])
        -> (ordered: [MeetingSegment], ranges: [Range<Int>]) {
        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var ranges: [Range<Int>] = []
        var startIndex = 0
        var chars = 0
        for (i, seg) in ordered.enumerated() {
            let line = payloadLine(index: i - startIndex, segment: seg)
            if chars > 0, chars + line.count > batchCharBudget {
                ranges.append(startIndex..<i)
                startIndex = i
                chars = 0
            }
            chars += line.count + 1
        }
        if startIndex < ordered.count { ranges.append(startIndex..<ordered.count) }
        return (ordered, ranges)
    }

    /// "3| You: text" — numbering restarts per batch so the model counts
    /// what it can see.
    nonisolated static func payloadLine(index: Int, segment: MeetingSegment) -> String {
        "\(index + 1)| \(segment.source == .you ? "You" : "Them"): \(segment.text)"
    }

    nonisolated static func payload(_ batch: ArraySlice<MeetingSegment>) -> String {
        batch.enumerated()
            .map { payloadLine(index: $0.offset, segment: $0.element) }
            .joined(separator: "\n")
    }

    /// The fail-closed apply. Returns the batch with corrections merged in,
    /// or nil when the reply is unusable as a whole (count mismatch).
    nonisolated static func apply(corrections: [String],
                                  to batch: [MeetingSegment]) -> [MeetingSegment]? {
        guard corrections.count == batch.count else { return nil }
        return zip(batch, corrections).map { seg, raw in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
                text = String(text.dropFirst().dropLast())
            }
            // Models sometimes parrot the label or numbering back despite the
            // prompt; strip the exact shapes we put in play, nothing else.
            for prefix in ["You: ", "Them: "] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            guard !text.isEmpty,
                  text.count <= seg.text.count * 3 + 40,
                  text.count * 4 >= seg.text.count else { return seg }
            guard text != seg.text else { return seg }
            return MeetingSegment(id: seg.id, source: seg.source, text: text,
                                  start: seg.start, end: seg.end,
                                  capturedAt: seg.capturedAt,
                                  committedAt: seg.committedAt, risky: seg.risky,
                                  speaker: seg.speaker)
        }
    }

    // MARK: - The pass

    /// Returns polished segments (spoken order), or nil when polish changed
    /// nothing or could not run — the caller then keeps the raw transcript.
    static func polish(segments: [MeetingSegment], cleanup: CleanupService,
                       dictationActive: @escaping () -> Bool) async -> [MeetingSegment]? {
        // Short timeout, unlike notes' 120 s: notes wait for the server
        // because they cannot exist without it; polish is an upgrade the
        // meeting is complete without.
        guard await cleanup.ensureReady(timeoutSeconds: 20) else {
            Log.info("TranscriptPolisher: llama-server not ready — keeping raw transcript")
            return nil
        }
        let (ordered, ranges) = batches(segments)
        guard !ranges.isEmpty else { return nil }
        let system = systemPrompt(dictionary: AppSettings.shared.dictionaryWords)
        let started = Date()

        var out = ordered
        var changedBatches = 0
        for (i, range) in ranges.enumerated() {
            let batch = Array(ordered[range])
            var applied: [MeetingSegment]?
            for attempt in 0..<2 {
                while dictationActive() {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard let reply = await cleanup.structured(
                    system: system, user: payload(batch[...]),
                    maxTokens: replyMaxTokens, schema: schema),
                    let start = reply.firstIndex(of: "{"),
                    let end = reply.lastIndex(of: "}"), start < end,
                    let decoded = try? JSONDecoder().decode(
                        Reply.self, from: Data(String(reply[start...end]).utf8)),
                    let merged = apply(corrections: decoded.lines, to: batch) else {
                    if attempt == 1 {
                        Log.error("TranscriptPolisher: batch \(i + 1)/\(ranges.count) "
                                  + "unusable twice — keeping its raw text")
                    }
                    continue
                }
                applied = merged
                break
            }
            if let applied, applied != batch {
                out.replaceSubrange(range, with: applied)
                changedBatches += 1
            }
        }
        guard out != ordered else {
            Log.info("TranscriptPolisher: no corrections needed "
                     + "(\(ranges.count) batches, \(Int(Date().timeIntervalSince(started))) s)")
            return nil
        }
        Log.info("TranscriptPolisher: polished \(ordered.count) segments, "
                 + "\(changedBatches)/\(ranges.count) batches changed, "
                 + "\(Int(Date().timeIntervalSince(started))) s")
        return out
    }
}
