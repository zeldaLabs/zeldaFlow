import Foundation

/// One live meeting's transcript pipeline: raw chunks in, ordered deduped
/// segments out. Confined to the main actor — at <= 0.4 segment events per
/// second (2 channels / 5 s), publication frequency is nothing, and holdback/
/// dedup state gets its thread confinement for free.
@MainActor final class MeetingSession: ObservableObject {

    let id: UUID
    let startedAt: Date

    /// Ordered by `start` (binary insert — holdback releases and retract
    /// survivors arrive out of spoken order; ported comment: "insertion order
    /// is not spoken order").
    @Published private(set) var segments: [MeetingSegment] = []

    private let store: MeetingStore
    private let transcriber: MeetingTranscriber
    private let holdback = MicHoldback()
    /// Recent system texts for merged-candidate dedup (±6 s window, so a mic
    /// echo straddling two system chunks still matches the concatenation).
    private var recentSystem: [(text: String, at: Date)] = []
    private var flushTask: Task<Void, Never>?
    private var finished = false

    var consumer: MeetingAudioConsumer { transcriber }
    var systemActivity: SystemActivityTracker { transcriber.systemActivity }

    init(id: UUID, startedAt: Date, engine: WhisperEngine, store: MeetingStore,
         dictationActive: @escaping () -> Bool) {
        self.id = id
        self.startedAt = startedAt
        self.store = store
        self.transcriber = MeetingTranscriber(engine: engine)
        transcriber.dictationActive = dictationActive
        transcriber.onChunkTranscribed = { [weak self] chunk in
            Task { @MainActor [weak self] in self?.handle(chunk) }
        }
    }

    func begin() {
        transcriber.start()
    }

    /// Drain the transcriber, force-release the holdback queue, and return the
    /// final ordered transcript.
    func finish() async -> [MeetingSegment] {
        guard !finished else { return segments }
        finished = true
        flushTask?.cancel()
        await transcriber.stopAndDrain()
        // Force flush: everything still queued either matches a system text
        // (dropped — it was echo) or commits (ported stop behavior).
        let result = holdback.flush(now: Date(), force: true,
                                    isDuplicate: { [weak self] seg in
                                        self?.isEcho(seg) ?? false
                                    })
        for seg in result.released { commit(seg) }
        for seg in result.dropped {
            Log.info("MeetingSession: dropped held-back echo at stop: \"\(seg.text.prefix(40))…\"")
        }
        segments.sort { $0.start < $1.start }
        return segments
    }

    /// Discard path: stop transcribing, keep nothing further.
    func abort() async {
        guard !finished else { return }
        finished = true
        flushTask?.cancel()
        await transcriber.stopAndDrain()
    }

    // MARK: - Chunk handling

    private func handle(_ chunk: MeetingTranscriber.RawChunk) {
        guard !finished else { return }
        let now = Date()
        let segment = MeetingSegment(
            id: UUID(),
            source: chunk.source,
            text: chunk.text,
            start: chunk.start,
            end: chunk.end,
            capturedAt: startedAt.addingTimeInterval(chunk.end),
            committedAt: now,
            risky: chunk.risky)

        switch chunk.source {
        case .them:
            commit(segment)
            rememberSystem(segment)
            // A fresh system text can (a) kill queued mic finals that match it
            // and (b) retract recently committed risky mic segments — the
            // racing-transcription case where the mic chunk landed first.
            let killed = holdback.removePending { [weak self] pending in
                self?.matches(pending, systemSegment: segment) ?? false
            }
            for k in killed {
                Log.info("MeetingSession: held-back mic echo dropped: \"\(k.text.prefix(40))…\"")
            }
            retractCommitted(against: segment, now: now)
        case .you:
            if segment.risky {
                holdback.queue(PendingMicFinal(
                    segment: segment,
                    releaseAt: now.addingTimeInterval(MicHoldback.holdbackSeconds)))
                armFlushTimer()
            } else {
                commit(segment)
            }
        }
    }

    private func commit(_ segment: MeetingSegment) {
        // Binary insert by start keeps the published array ordered without a
        // full re-sort per event.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start < segment.start { lo = mid + 1 } else { hi = mid }
        }
        segments.insert(segment, at: lo)
        store.appendTranscriptLine(id, .segment(segment))
    }

    private func rememberSystem(_ segment: MeetingSegment) {
        recentSystem.append((segment.text, segment.capturedAt))
        // Keep a little over the dedup window; pruning by count is enough at
        // this event rate.
        if recentSystem.count > 24 { recentSystem.removeFirst(recentSystem.count - 24) }
    }

    // MARK: - Dedup / retraction

    /// Is this mic segment far-side echo? Text match against every merged
    /// candidate of system texts within ±6 s — the ONLY condition that may
    /// drop a mic segment (ported policy invariant).
    private func isEcho(_ segment: MeetingSegment) -> Bool {
        let candidates = TranscriptMatcher.mergedCandidates(
            segments: recentSystem,
            around: segment.capturedAt,
            window: MicHoldback.holdbackSeconds,
            mergeLimit: 3)
        return candidates.contains { TranscriptMatcher.overlaps(segment.text, $0) }
    }

    private func matches(_ micSegment: MeetingSegment, systemSegment: MeetingSegment) -> Bool {
        if TranscriptMatcher.overlaps(micSegment.text, systemSegment.text) { return true }
        return isEcho(micSegment)
    }

    private func retractCommitted(against system: MeetingSegment, now: Date) {
        let committed = segments.filter { $0.source == .you && $0.risky }
        let ids = MicHoldback.retractionCandidates(
            committed: committed,
            systemText: system.text,
            systemCapturedAt: system.capturedAt,
            now: now,
            isDuplicate: { seg, text in TranscriptMatcher.overlaps(seg.text, text) })
        guard !ids.isEmpty else { return }
        for rid in ids {
            segments.removeAll { $0.id == rid }
            store.appendTranscriptLine(id, .retraction(MeetingRetraction(retractedID: rid, at: now)))
            Log.info("MeetingSession: retracted committed mic echo \(rid)")
        }
    }

    // MARK: - Holdback flush timer

    private func armFlushTimer() {
        guard let due = holdback.earliestReleaseAt else { return }
        flushTask?.cancel()
        let delay = max(0.05, due.timeIntervalSinceNow)
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.finished else { return }
            let result = self.holdback.flush(now: Date(), force: false,
                                             isDuplicate: { [weak self] seg in
                                                 self?.isEcho(seg) ?? false
                                             })
            for seg in result.released { self.commit(seg) }
            for seg in result.dropped {
                Log.info("MeetingSession: held-back mic echo dropped: \"\(seg.text.prefix(40))…\"")
            }
            if !result.deferred.isEmpty { self.armFlushTimer() }
        }
    }
}
