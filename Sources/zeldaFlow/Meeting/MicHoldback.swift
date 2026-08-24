import Foundation

// Holdback queue for risky mic finals — the port of meetingMicHoldback.js plus
// the pending-queue plumbing that drives it (ipcHandlers.js ~5002-5280:
// queuePendingMicFinal / flushPendingMicFinals / removePendingMicFinalsFor /
// removeRacingMicEntriesFor).
//
// Their header policy comment, verbatim — it is the load-bearing rule of this
// file (ported: meetingMicHoldback.js):
//
//   Policy: a text match (`isDuplicate`) is the only condition that may drop a
//   held-back segment. Audio-only echo evidence delays a segment, never
//   discards it — field logs showed genuine local speech scoring correlations
//   of 0.73–0.81 during double-talk, above every audio gate. Released segments
//   with bleed flags can still be retracted when a matching system transcript
//   arrives late (see removeRacingMicEntriesFor in ipcHandlers.js).
//
// (removeRacingMicEntriesFor is `retractionCandidates` here; "bleed flags"
// arrive collapsed into MeetingSegment.risky.)

/// One risky mic final waiting out its holdback window before it may commit.
struct PendingMicFinal: Equatable {
    let segment: MeetingSegment
    /// committedAt (the moment it was queued) + `MicHoldback.holdbackSeconds`
    /// — computed by the caller so this class never reads a wall clock
    /// (ported: queuePendingMicFinal's `releaseAt: Date.now() + holdbackMs`).
    let releaseAt: Date
}

/// Not thread-safe by design: the owner (MeetingSession) confines every call
/// to the meeting pipeline queue, so a lock here could only hide a confinement
/// bug. Time is injected everywhere — `now:` parameters, caller-computed
/// `releaseAt` — so the eval can pin every race deterministically.
final class MicHoldback {

    // MARK: - Ported constants (ipcHandlers.js:5006-5013)

    /// LOCAL_RISKY_MIC_SEGMENT_HOLDBACK_MS = LOCAL_MEETING_CHUNK_INTERVAL_MS
    /// (5000) + 1000. Their why, kept: must outlast one local transcription
    /// cycle so a straddling remote utterance's NEXT-cycle system transcript
    /// can still confirm buffered echo. (Their 3000 ms variant —
    /// STREAMING_RISKY_MIC_SEGMENT_HOLDBACK_MS — belongs to their streaming
    /// pipeline; we are the ~5 s chunked local pipeline, so the
    /// chunk-interval-plus-one-second constant is the one that applies.)
    static let holdbackSeconds: TimeInterval = 6.0

    /// RACING_MIC_RETRACT_WINDOW_MS = 4000. They widened this to 6 s for
    /// candidates carrying bleed evidence (hasBleedEvidence /
    /// likelyRenderBleed); MeetingSegment collapses every risk signal into the
    /// single `risky` bit, so the evidence needed to justify the wider window
    /// does not exist here and the 4 s window applies uniformly.
    static let retractWindowSeconds: TimeInterval = 4.0

    /// DUPLICATE_TRANSCRIPT_WINDOW_MS = 6000 — used here only as the scan
    /// bound of the retraction pass (the ported `break` in
    /// removeRacingMicEntriesFor): commit order tracks capture order to within
    /// one holdback, so once a candidate's capture falls more than this far
    /// before the system capture, everything committed before it is out of
    /// reach too and the newest-first scan stops. Keeps the pass O(recent
    /// segments), not O(entire meeting).
    private static let duplicateWindowSeconds: TimeInterval = 6.0

    // MARK: - Pending queue

    /// Kept sorted by releaseAt so `earliestReleaseAt` is the first element
    /// (ported: queuePendingMicFinal's sort-on-insert, ipcHandlers.js:5277).
    private var pending: [PendingMicFinal] = []

    /// The owner re-arms its flush timer to this after every mutation — the
    /// port of schedulePendingMicFinalFlush minus the timer itself: owning a
    /// DispatchSourceTimer here would drag a real clock into the one class
    /// the eval must drive with a fake one. nil = nothing pending, no timer.
    var earliestReleaseAt: Date? { pending.first?.releaseAt }

    var pendingCount: Int { pending.count }

    func queue(_ p: PendingMicFinal) {
        // Insert before the first later-releasing entry: keeps the array
        // sorted and, for equal releaseAt (two finals queued in the same
        // pipeline tick), keeps arrival order. Their Array.sort is stable;
        // Swift's sort() is not, so ordered insertion replaces it.
        let idx = pending.firstIndex { $0.releaseAt > p.releaseAt } ?? pending.endIndex
        pending.insert(p, at: idx)
    }

    /// Release everything due (or everything, when `force` — meeting stop must
    /// not swallow held speech). The port of partitionPendingMicFinals
    /// (meetingMicHoldback.js) driven the way flushPendingMicFinals drives it:
    /// still-early entries stay `deferred`; of the due ones, only a text match
    /// (`isDuplicate`) may put an entry in `dropped` — expiry alone can only
    /// move it to `released`, per the policy header above.
    func flush(now: Date, force: Bool, isDuplicate: (MeetingSegment) -> Bool)
        -> (deferred: [PendingMicFinal], dropped: [MeetingSegment], released: [MeetingSegment]) {
        var deferred: [PendingMicFinal] = []
        var dropped: [MeetingSegment] = []
        var released: [MeetingSegment] = []
        for entry in pending {
            if !force && entry.releaseAt > now {
                deferred.append(entry)
                continue
            }
            if isDuplicate(entry.segment) {
                dropped.append(entry.segment)
                continue
            }
            released.append(entry.segment)
        }
        pending = deferred
        return (deferred, dropped, released)
    }

    /// On a fresh system segment: drop queued mic finals that text-match it —
    /// the port of removePendingMicFinalsFor (ipcHandlers.js:5243-5266). The
    /// arriving system transcript IS the text match, so dropping here honors
    /// the policy header rather than bypassing it. Non-matching entries keep
    /// their queue order and their release deadlines.
    func removePending(matching isDuplicate: (MeetingSegment) -> Bool) -> [MeetingSegment] {
        var kept: [PendingMicFinal] = []
        var removed: [MeetingSegment] = []
        for entry in pending {
            if isDuplicate(entry.segment) {
                removed.append(entry.segment)
            } else {
                kept.append(entry)
            }
        }
        pending = kept
        return removed
    }

    // MARK: - Retraction of already-COMMITTED segments

    /// The port of removeRacingMicEntriesFor (ipcHandlers.js:5080-5117), pure
    /// so the eval pins the race: returns the ids to retract; the owner
    /// appends the tombstones. Only risky-flagged mic segments are eligible,
    /// and the text match (`isDuplicate(candidate, systemText)`) remains the
    /// only condition that condemns one. Their why-comment, kept
    /// (ported: meetingMicHoldback.js isWithinRetractWindow):
    ///
    ///   A committed mic segment may be retracted by an arriving system
    ///   transcript when the two plausibly describe the same audio. Capture
    ///   timestamps race directly for segments committed on arrival;
    ///   held-back segments commit only after their holdback window, so their
    ///   confirming transcript — delayed by up to a transcription cycle —
    ///   races their commit time instead. Without the commit-time comparison,
    ///   a segment released at capture + holdback could never be retracted:
    ///   the confirming transcript always arrives more than `holdback` away
    ///   from the capture timestamp.
    ///
    /// One remapping from the source: their local pipeline stamped every
    /// segment with Date.now() at transcription completion, so their
    /// commit-clock clause compared committedAt against the system segment's
    /// ARRIVAL time. Our segments carry true capture stamps
    /// (sample-count-derived), so the capture clause races
    /// capturedAt-vs-capturedAt directly — strictly tighter than their
    /// arrival-vs-arrival approximation — and the commit clause races
    /// committedAt against `now`, which is exactly the arrival moment of the
    /// system segment being processed. Comparing committedAt against
    /// systemCapturedAt instead would re-dead-code the clause: a held-back
    /// segment commits capture + ~11 s (one 5 s cycle + 6 s holdback), always
    /// beyond the 4 s window from any capture stamp.
    static func retractionCandidates(committed: [MeetingSegment], systemText: String,
                                     systemCapturedAt: Date, now: Date,
                                     isDuplicate: (MeetingSegment, String) -> Bool) -> [UUID] {
        var ids: [UUID] = []
        for candidate in committed.reversed() {
            guard candidate.source == .you else { continue }
            if !isWithinRetractWindow(candidate: candidate,
                                      systemCapturedAt: systemCapturedAt, now: now) {
                if candidate.capturedAt <
                    systemCapturedAt.addingTimeInterval(-duplicateWindowSeconds) {
                    break   // scan bound — see duplicateWindowSeconds
                }
                continue
            }
            guard candidate.risky else { continue }
            if isDuplicate(candidate, systemText) {
                ids.append(candidate.id)
            }
        }
        return ids
    }

    /// The window races BOTH clocks — capture-timestamp distance OR
    /// commit-time distance (see the remapping note on retractionCandidates).
    /// The forward guard is theirs (`systemTimestamp >= candidate.timestamp`):
    /// echo confirmation only runs forward — a system segment captured before
    /// the mic candidate cannot be the far-side original of its echo.
    private static func isWithinRetractWindow(candidate: MeetingSegment,
                                              systemCapturedAt: Date, now: Date) -> Bool {
        if abs(candidate.capturedAt.timeIntervalSince(systemCapturedAt))
            <= retractWindowSeconds {
            return true
        }
        return systemCapturedAt >= candidate.capturedAt
            && abs(candidate.committedAt.timeIntervalSince(now)) <= retractWindowSeconds
    }
}
