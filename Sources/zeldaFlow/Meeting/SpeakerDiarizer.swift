import Foundation
import FluidAudio

// Post-meeting speaker diarization of the system channel (ADR 31).
//
// The ONLY file that imports the vendored FluidAudio module — if the vendored
// build ever breaks, stubbing `run` to return nil removes the feature with
// zero blast radius. The channel split stays ground truth: the mic channel is
// "You" unconditionally; diarization only ever refines .them segments into
// cluster indices, and a segment the aligner can't attribute confidently
// keeps the generic "Them" rather than guessing.
//
// Shaped like TranscriptPolisher: pure nonisolated static pieces (the eval
// surface — no FluidAudio types in their signatures) plus one async entry
// point that fails to nil at every gate and never throws out.
enum SpeakerDiarizer {

    struct Outcome {
        let segments: [MeetingSegment]
        /// Distinct voices found on the system channel. 1 = a 1:1 call —
        /// the caller skips the rewrite and "Them" stays "Them".
        let speakerCount: Int
    }

    /// One diarization turn in meeting time, clusters renumbered 0-based.
    struct SpeakerTurn: Equatable {
        let cluster: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    /// system.wav must hold at least ~10 s of samples before diarization is
    /// worth a model load — and the header-only spool a failed tap leaves
    /// behind (micOnly meetings) must not count as audio.
    static let headerBytes = 44
    static let minSystemWavBytes = headerBytes + 10 * 16_000 * 2

    /// Diarization is bounded so a hung CoreML load can never wedge the
    /// finalize pipeline; the orphaned task's result is simply discarded.
    static let timeoutSeconds: UInt64 = 300

    // MARK: - Entry point

    static func run(folder: URL, segments: [MeetingSegment]) async -> Outcome? {
        guard Paths.diarizerModelsExist else {
            Log.info("SpeakerDiarizer: models not installed — skipping")
            return nil
        }
        guard segments.contains(where: { $0.source == .them }) else { return nil }
        let wav = folder.appendingPathComponent("system.wav")
        guard let samples = readSpool(wav) else {
            Log.info("SpeakerDiarizer: no usable system.wav — skipping")
            return nil
        }

        let turns: [SpeakerTurn]? = await withTaskGroup(of: [SpeakerTurn]?.self) { group in
            group.addTask { await diarize(samples) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                // The race winner cancels this task — only a REAL expiry logs.
                if !Task.isCancelled {
                    Log.error("SpeakerDiarizer: timed out after \(timeoutSeconds) s")
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let turns, !turns.isEmpty else { return nil }

        let speakerCount = Set(turns.map(\.cluster)).count
        let assignments = assign(segments.filter { $0.source == .them }, turns: turns)
        let annotated = annotate(segments, assignments: assignments)
        Log.info("SpeakerDiarizer: \(speakerCount) voice(s), " +
                 "\(assignments.count) of \(segments.filter { $0.source == .them }.count) " +
                 "system segments attributed")
        return Outcome(segments: annotated, speakerCount: speakerCount)
    }

    // MARK: - FluidAudio boundary

    private static func diarize(_ samples: [Float]) async -> [SpeakerTurn]? {
        // ADR 17: the app never fetches models itself — setup.sh installed
        // them, and offlineMode makes a missing file a typed error instead
        // of a HuggingFace download.
        ModelHub.offlineMode = true
        do {
            let models = try await OfflineDiarizerModels.load(from: Paths.diarizerModelsDir)
            let manager = OfflineDiarizerManager()
            manager.initialize(models: models)
            let result = try await manager.process(audio: samples)
            return normalizeTurns(result.segments.map {
                (speakerId: $0.speakerId,
                 start: TimeInterval($0.startTimeSeconds),
                 end: TimeInterval($0.endTimeSeconds))
            })
        } catch {
            Log.error("SpeakerDiarizer: \(error)")
            return nil
        }
    }

    /// 16 kHz mono Int16 WAV (WavSpool's fixed 44-byte header) → Float32.
    /// Mapped read so the Int16 side never fully materializes; a 4 h meeting
    /// converts to ~900 MB of Float for the duration of one call.
    private static func readSpool(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= minSystemWavBytes else { return nil }
        let payload = data.dropFirst(headerBytes)
        let count = payload.count / 2
        var samples = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<count { samples[i] = Float(int16[i]) / 32768 }
        }
        return samples
    }

    // MARK: - Pure pieces (the eval surface)

    /// FluidAudio speaker IDs are opaque strings; renumber 0-based by first
    /// speech time so "Speaker 1" is always whoever talked first.
    nonisolated static func normalizeTurns(
        _ raw: [(speakerId: String, start: TimeInterval, end: TimeInterval)]
    ) -> [SpeakerTurn] {
        var clusterFor: [String: Int] = [:]
        var turns: [SpeakerTurn] = []
        for turn in raw.sorted(by: { $0.start < $1.start }) where turn.end > turn.start {
            let cluster: Int
            if let existing = clusterFor[turn.speakerId] {
                cluster = existing
            } else {
                cluster = clusterFor.count
                clusterFor[turn.speakerId] = cluster
            }
            turns.append(SpeakerTurn(cluster: cluster, start: turn.start, end: turn.end))
        }
        return turns
    }

    /// Max-temporal-intersection voting (the Argmax SpeakerKit .subsegment
    /// idea): a Whisper chunk's timestamps drift ±0.5–1 s and one 5 s chunk
    /// can span several short turns, so each cluster's score is the SUM of
    /// its turns' overlaps with the segment — boundary matching would lose
    /// both ways. Weak evidence falls through midpoint containment, then
    /// nearest-edge within 1 s, then nil: unattributable stays "Them".
    nonisolated static func assign(_ them: [MeetingSegment],
                                   turns: [SpeakerTurn]) -> [UUID: Int] {
        guard !turns.isEmpty else { return [:] }
        var out: [UUID: Int] = [:]
        for seg in them where seg.source == .them {
            var scores: [Int: TimeInterval] = [:]
            for turn in turns {
                let overlap = min(seg.end, turn.end) - max(seg.start, turn.start)
                if overlap > 0 { scores[turn.cluster, default: 0] += overlap }
            }
            let floor = max(0.25, 0.15 * (seg.end - seg.start))
            if let best = scores.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
               best.value >= floor {
                out[seg.id] = best.key
                continue
            }
            let mid = (seg.start + seg.end) / 2
            if let host = turns.first(where: { $0.start <= mid && mid <= $0.end }) {
                out[seg.id] = host.cluster
                continue
            }
            let nearest = turns.min { edgeDistance($0, to: mid) < edgeDistance($1, to: mid) }
            if let nearest, edgeDistance(nearest, to: mid) <= 1.0 {
                out[seg.id] = nearest.cluster
            }
        }
        return out
    }

    private nonisolated static func edgeDistance(_ turn: SpeakerTurn,
                                                 to point: TimeInterval) -> TimeInterval {
        if point < turn.start { return turn.start - point }
        if point > turn.end { return point - turn.end }
        return 0
    }

    /// Rebuilds only the .them segments that got an assignment; .you and
    /// unassigned segments pass through untouched. Text and order are never
    /// changed, so transcriptHash() is provably stable across this pass.
    nonisolated static func annotate(_ segments: [MeetingSegment],
                                     assignments: [UUID: Int]) -> [MeetingSegment] {
        segments.map { seg in
            guard seg.source == .them, let cluster = assignments[seg.id] else { return seg }
            return MeetingSegment(id: seg.id, source: seg.source, text: seg.text,
                                  start: seg.start, end: seg.end,
                                  capturedAt: seg.capturedAt,
                                  committedAt: seg.committedAt, risky: seg.risky,
                                  speaker: cluster)
        }
    }
}
