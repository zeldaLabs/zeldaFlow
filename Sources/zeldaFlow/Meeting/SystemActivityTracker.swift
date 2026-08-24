import Foundation

/// "Was the far side audible during this window?" — the one piece of
/// OpenWhispr's 442-line MeetingEchoLeakDetector this port keeps
/// (meetingEchoLeakDetector.js:211-224, isSystemSpeaking, plus the history
/// bookkeeping at :59-76 and :392-398). The full detector cross-correlates
/// mic and system waveforms to grade bleed; v1 only needs the binary VAD
/// question, because a mic segment captured while the system channel was
/// loud is `risky` (MeetingSegment.risky) and gets held back for text-dedup.
/// A ~6 s ring of (offset, rms) per system chunk answers it in one scan.
///
/// Pure state, no CoreAudio, no I/O — fully unit-pinnable.
final class SystemActivityTracker {

    // MARK: - Ported constants

    /// The dedup window is ±6 s (ipcHandlers.js DUPLICATE_TRANSCRIPT_WINDOW_MS)
    /// and no query ever reaches further back than that, so history older
    /// than 6 s is dead weight. ported: meetingEchoLeakDetector.js:2
    /// (MAX_SYSTEM_HISTORY_MS = 6000).
    static let historySeconds: TimeInterval = 6.0

    /// Below this the system channel is comfort noise / codec hiss, not
    /// speech — the source uses a lower bar for the system channel (0.004)
    /// than for the mic (MIN_RMS = 0.006) because loopback audio has no room
    /// noise floor. ported: meetingEchoLeakDetector.js:5
    /// (MIN_SYSTEM_RMS = 0.004).
    static let minSystemRMS: Float = 0.004

    /// Padding the caller applies around a mic segment before querying:
    /// echo tails and chunk-boundary jitter mean far-side speech can bracket
    /// the segment by a few hundred ms. ported: meetingEchoLeakDetector.js:23
    /// (SYSTEM_VAD_TAIL_MS = 300).
    static let vadTailSeconds: TimeInterval = 0.3

    // MARK: - State

    /// Appended on the meeting pipeline queue (~100 ms cadence, per
    /// MeetingAudioConsumer.systemChunk), queried on the transcriber tick
    /// (every ~5 s) — two queues, so every touch of `history` holds the
    /// lock. Contention is 10 Hz vs 0.2 Hz and the critical sections are
    /// microseconds; an NSLock is invisible next to the ~100 ms chunk
    /// cadence.
    private let lock = NSLock()
    /// Offsets are seconds from meeting start, sample-count derived
    /// (MeetingAudioConsumer contract), so they are monotonic — both the
    /// front-trim in record() and the early break in isSystemSpeaking()
    /// lean on that ordering, exactly as the source leans on Date.now().
    private var history: [(offset: TimeInterval, rms: Float)] = []

    // MARK: - API

    /// Record one system chunk's RMS. Called per ~100 ms chunk; trims
    /// entries older than `historySeconds` behind the newest offset, the
    /// port of _trimHistory (meetingEchoLeakDetector.js:392-398). 6 s of
    /// 100 ms chunks is ~60 entries, so Array.removeFirst beats a real ring
    /// buffer on clarity at zero measurable cost.
    func record(rms: Float, at offset: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        history.append((offset: offset, rms: rms))
        let cutoff = offset - Self.historySeconds
        var drop = 0
        while drop < history.count && history[drop].offset < cutoff { drop += 1 }
        if drop > 0 { history.removeFirst(drop) }
    }

    /// True when any recorded chunk inside [from, to] reached `minSystemRMS`.
    ///
    /// The ±0.3 s tail is NOT applied here — the caller passes the already
    /// padded window, i.e. [start - vadTailSeconds, end + vadTailSeconds].
    /// The source buries SYSTEM_VAD_TAIL_MS inside its loop
    /// (meetingEchoLeakDetector.js:215,218) and its callers pass raw segment
    /// bounds; we deliberately move the padding to the call site so this
    /// stays a pure interval-overlap test: the padding policy is visible
    /// where the risky decision is made, and tests can pin exact window
    /// edges without reverse-engineering hidden slack.
    ///
    /// The source also extends each entry by its buffer duration
    /// (entryEnd = timestampMs + durationMs, line 213); our entries are
    /// chunk-start points, which narrows the lower edge by at most one
    /// ~100 ms chunk — absorbed three times over by the 300 ms tail the
    /// caller adds, which is exactly why the tail exceeds the chunk length.
    func isSystemSpeaking(from: TimeInterval, to: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Newest-first with an early break, as in the source (:212-216):
        // offsets are monotonic, so the first entry older than `from` proves
        // every remaining entry is out of window.
        for entry in history.reversed() {
            if entry.offset < from { break }
            if entry.rms >= Self.minSystemRMS && entry.offset <= to { return true }
        }
        return false
    }

    /// Drop all history — meeting stop/start reuse, the port of reset()
    /// (meetingEchoLeakDetector.js:54-57). Offsets restart at 0 for a new
    /// meeting epoch, so stale entries would otherwise sit "in the future"
    /// and poison the monotonic break for the first 6 s.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        history = []
    }
}
