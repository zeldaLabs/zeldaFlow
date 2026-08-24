import Foundation
import CoreAudio

/// Behavior pins for the meeting notetaker (ADR 0027), pure-first:
/// TranscriptMatcher, MicHoldback, the audio gates, the notes
/// chunker/renderer, MeetingStore (in a scratch dir), the detection state
/// machine (fake clock), and the pill layout table — then two LIVE sections
/// that SKIP gracefully when this machine lacks the model or the
/// system-audio grant. Run with `zeldaFlow --evalmeeting`.
///
/// Everything above the live sections needs no LLM, no network and no
/// permissions, so those pins can gate a release: if one fails, the echo
/// dedup or the crash-safety story changed meaning.
enum MeetingEvals {
    static func run() -> Int32 {
        print("zeldaFlow meeting evals — dedup, holdback, gates, notes, store, detection, layout")
        // MeetingDetectionEngine and PillController.layout are @MainActor;
        // the semaphore/runloop pump (AudioEvals pattern) keeps the main
        // queue serviced while the eval task awaits.
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task { @MainActor in
            code = await runAll()
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return code
    }

    @MainActor
    private static func runAll() async -> Int32 {
        let t = Tally()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeldaflow-meeting-evals-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        matcherSection(t)
        holdbackSection(t)
        gatesSection(t)
        notesSection(t)
        polisherSection(t)
        chunkingSection(t)
        diarizationSection(t)
        await storeSection(t, scratch: scratch)
        await detectionSection(t)
        layoutSection(t)
        await liveWhisperSection(t, scratch: scratch)
        await liveTapSection(t)
        await liveChunkingABSection(t)
        await liveDiarizerSection(t, scratch: scratch)

        if t.failures == 0 {
            print("\nOK — \(t.checks) checks passed"
                  + (t.skips > 0 ? ", \(t.skips) live section(s) skipped" : ""))
        } else {
            print("\nFAIL — \(t.failures) of \(t.checks) checks failed")
        }
        return t.failures == 0 ? 0 : 1
    }

    // MARK: - TranscriptPolisher (pure pieces)

    private static func polisherSection(_ t: Tally) {
        print("\n  TranscriptPolisher — fail-closed Gemma cleanup of the transcript:")
        func seg(_ i: Int, _ source: MeetingSegment.Source, _ text: String) -> MeetingSegment {
            MeetingSegment(id: UUID(), source: source, text: text,
                           start: Double(i) * 5, end: Double(i) * 5 + 5,
                           capturedAt: Date(timeIntervalSince1970: 1_754_000_000),
                           committedAt: Date(timeIntervalSince1970: 1_754_000_000),
                           risky: false)
        }
        let batch = [seg(0, .you, "Annelies of..."), seg(1, .them, "That's studying.")]

        t.check("count mismatch discards the whole reply",
                TranscriptPolisher.apply(corrections: ["one"], to: batch) == nil)
        let good = TranscriptPolisher.apply(
            corrections: ["Analysis of...", "That's studying."], to: batch)
        t.check("good corrections apply; id/source/timing untouched",
                good?[0].text == "Analysis of..." && good?[0].id == batch[0].id
                && good?[0].source == .you && good?[1].text == "That's studying.")
        let bad = TranscriptPolisher.apply(
            corrections: ["", String(repeating: "x", count: 500)], to: batch)
        t.check("empty and runaway corrections keep the original line",
                bad?[0].text == batch[0].text && bad?[1].text == batch[1].text)
        let labeled = TranscriptPolisher.apply(
            corrections: ["You: Analysis of...", "Them: That's studying."], to: batch)
        t.check("parroted speaker labels are stripped",
                labeled?[0].text == "Analysis of..." && labeled?[1].text == "That's studying.")

        let many = (0..<50).map {
            seg($0, $0 % 2 == 0 ? .you : .them, String(repeating: "word ", count: 30))
        }
        let (ordered, ranges) = TranscriptPolisher.batches(many)
        t.check("batches cover every segment exactly once, in order",
                ranges.map(\.count).reduce(0, +) == ordered.count
                && ranges.first?.lowerBound == 0
                && ranges.last?.upperBound == ordered.count
                && zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        t.check("every batch payload fits the context budget",
                ranges.allSatisfy {
                    TranscriptPolisher.payload(ordered[$0]).count
                        <= TranscriptPolisher.batchCharBudget + 80
                })
        t.check("polisher glossary lives in the text domain (prompt carries it)",
                TranscriptPolisher.systemPrompt(dictionary: ["zeldaFlow"]).contains("zeldaFlow"))
    }

    // MARK: - 1. TranscriptMatcher

    private static func matcherSection(_ t: Tally) {
        print("\n  TranscriptMatcher — the text match that alone may drop a mic segment:")

        t.check("identical texts overlap",
                TranscriptMatcher.overlaps("we should ship on friday", "We should ship on Friday."))
        // Containment runs BEFORE the 3-token gate (ported ordering): the
        // 2-token echo still matches its containing original.
        t.check("containment matches even under 3 tokens",
                TranscriptMatcher.overlaps("we should", "yes we should do that"))

        // Coverage boundary at exactly 0.6 over the shorter side: 6 of 10
        // shared tokens passes, 5 of 10 (coverage AND LCS both 0.5) fails.
        let a10 = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        t.check("token coverage 6/10 = 0.60 matches (threshold is inclusive)",
                TranscriptMatcher.overlaps(a10,
                    "alpha bravo charlie delta echo foxtrot kilo lima mike november"))
        t.check("token coverage 5/10 = 0.50 does not match",
                !TranscriptMatcher.overlaps(a10,
                    "alpha bravo charlie delta echo kilo lima mike november oscar"))

        // Below 3 tokens the ratios are meaningless ("yeah okay" would match
        // everything) — full token overlap still refuses.
        t.check("sub-3-token pair never matches on ratios",
                !TranscriptMatcher.overlaps("yeah okay", "okay yeah sure well"))

        // looselyOverlaps is ported-but-unused (v1 has no double-talk tagger)
        // — pin its 4-meaningful-token floor so it's ready when tagging lands.
        t.check("loose matcher: 4 meaningful tokens fully shared matches",
                TranscriptMatcher.looselyOverlaps("the quarterly budget review meeting",
                                                  "quarterly budget review meeting agenda items"))
        t.check("loose matcher: 3 meaningful tokens is below its floor",
                !TranscriptMatcher.looselyOverlaps("the budget review meeting",
                                                   "budget review meeting agenda items today"))

        // The straddle case mergedCandidates exists for: an echo that spans
        // the boundary of two 5 s system chunks scores 5/10 = 0.5 against
        // each chunk alone (below 0.6) but matches the concatenation.
        let t0 = Date(timeIntervalSince1970: 1_754_000_000)
        let s1 = "okay quick update from finance side first because budget approval landed yesterday afternoon"
        let s2 = "so procurement can order laptops once shipping quotes arrive next week"
        let echo = "budget approval landed yesterday afternoon so procurement can order laptops"
        t.check("straddling echo misses chunk 1 alone", !TranscriptMatcher.overlaps(echo, s1),
                "coverage 5/10")
        t.check("straddling echo misses chunk 2 alone", !TranscriptMatcher.overlaps(echo, s2),
                "coverage 5/10")
        let cands = TranscriptMatcher.mergedCandidates(
            segments: [(text: s1, at: t0), (text: s2, at: t0.addingTimeInterval(5))],
            around: t0.addingTimeInterval(5))
        let hits = cands.filter { TranscriptMatcher.overlaps(echo, $0) }
        t.check("straddling echo matches ONLY the merged concatenation",
                hits == [s1 + " " + s2], "\(cands.count) candidates, \(hits.count) hit")

        // ±6 s window: a chunk 7 s away is never the same utterance.
        let windowed = TranscriptMatcher.mergedCandidates(
            segments: [(text: "inside", at: t0), (text: "outside", at: t0.addingTimeInterval(7))],
            around: t0)
        t.check("candidates beyond the ±6 s window are excluded", windowed == ["inside"])

        // Merge limit 3: with 4 chunks in-window, no candidate concatenates
        // all 4 — longer merges only dilute the coverage ratios.
        let four = TranscriptMatcher.mergedCandidates(
            segments: [(text: "a", at: t0), (text: "b", at: t0.addingTimeInterval(1)),
                       (text: "c", at: t0.addingTimeInterval(2)), (text: "d", at: t0.addingTimeInterval(3))],
            around: t0.addingTimeInterval(1.5))
        t.check("merge limit caps runs at 3 chunks",
                four.count == 9 && !four.contains("a b c d"), "\(four.count) candidates")

        // Order-preserving dedup: duplicate texts yield one candidate each,
        // first occurrence wins (deterministic output is what tests pin).
        let dup = TranscriptMatcher.mergedCandidates(
            segments: [(text: "x", at: t0), (text: "x", at: t0.addingTimeInterval(1))],
            around: t0)
        t.check("duplicate candidates deduped in insertion order", dup == ["x", "x x"])
    }

    // MARK: - 2. MicHoldback

    private static func holdbackSection(_ t: Tally) {
        print("\n  MicHoldback — risky mic finals wait; only a text match may drop one:")
        let t0 = Date(timeIntervalSince1970: 1_754_100_000)

        // -- Pending queue --
        let hb = MicHoldback()
        let echoSeg = seg("the deploy is scheduled for tomorrow morning", start: 0, end: 5,
                          capturedAt: t0.addingTimeInterval(5), committedAt: t0.addingTimeInterval(5),
                          risky: true)
        hb.queue(PendingMicFinal(segment: echoSeg,
                                 releaseAt: t0.addingTimeInterval(5 + MicHoldback.holdbackSeconds)))

        // Not yet due: nothing may release early.
        var r = hb.flush(now: t0.addingTimeInterval(8), force: false, isDuplicate: { _ in true })
        t.check("flush before releaseAt defers (even a matching one)",
                r.deferred.count == 1 && r.dropped.isEmpty && r.released.isEmpty)

        // Due + text match = the one legal drop.
        r = hb.flush(now: t0.addingTimeInterval(11), force: false, isDuplicate: { _ in true })
        t.check("echo dropped on text match at flush",
                r.dropped.map(\.id) == [echoSeg.id] && r.released.isEmpty && hb.pendingCount == 0)

        // Due + no match = released; expiry alone can never drop (the policy
        // header: audio evidence delays, never discards).
        let speech = seg("no let us keep the original date", start: 5, end: 10,
                         capturedAt: t0.addingTimeInterval(10), committedAt: t0.addingTimeInterval(10),
                         risky: true)
        hb.queue(PendingMicFinal(segment: speech, releaseAt: t0.addingTimeInterval(16)))
        r = hb.flush(now: t0.addingTimeInterval(16), force: false, isDuplicate: { _ in false })
        t.check("genuine speech released after the 6 s holdback",
                r.released.map(\.id) == [speech.id] && r.dropped.isEmpty)

        // -- Queue order + removePending --
        let hb2 = MicHoldback()
        let sA = seg("first held segment", capturedAt: t0, committedAt: t0, risky: true)
        let sB = seg("second held segment", capturedAt: t0, committedAt: t0, risky: true)
        hb2.queue(PendingMicFinal(segment: sA, releaseAt: t0.addingTimeInterval(6)))
        hb2.queue(PendingMicFinal(segment: sB, releaseAt: t0.addingTimeInterval(3)))
        t.check("queue keeps releaseAt order (earliest drives the flush timer)",
                hb2.earliestReleaseAt == t0.addingTimeInterval(3))
        let removed = hb2.removePending { $0.id == sB.id }
        t.check("removePending kills only matches, survivors keep their deadline",
                removed.map(\.id) == [sB.id] && hb2.pendingCount == 1
                && hb2.earliestReleaseAt == t0.addingTimeInterval(6))

        // -- Force flush (meeting stop): everything non-matching commits;
        // held speech must never be swallowed by the stop itself. --
        let hb3 = MicHoldback()
        let far = t0.addingTimeInterval(100)
        hb3.queue(PendingMicFinal(segment: sA, releaseAt: far))
        hb3.queue(PendingMicFinal(segment: echoSeg, releaseAt: far))
        r = hb3.flush(now: t0, force: true, isDuplicate: { $0.id == echoSeg.id })
        t.check("force flush releases all non-matching, drops only text matches",
                r.released.map(\.id) == [sA.id] && r.dropped.map(\.id) == [echoSeg.id]
                && r.deferred.isEmpty)

        // -- Retraction of COMMITTED segments --
        print("\n  MicHoldback.retractionCandidates — the committedAt race:")
        let match: (MeetingSegment, String) -> Bool = { TranscriptMatcher.overlaps($0.text, $1) }
        let sysText = "the deploy is scheduled for tomorrow morning"

        // The race the commit clause exists for: a held-back segment commits
        // at capture + ~11 s (5 s chunk + 6 s holdback), so its confirming
        // system transcript always lands > 4 s from its CAPTURE stamp — only
        // the committedAt-vs-now comparison can reach it.
        let released = seg(sysText, start: 0, end: 5,
                           capturedAt: t0.addingTimeInterval(5),        // old (5 s from sys capture)
                           committedAt: t0.addingTimeInterval(11),      // fresh: released a moment ago
                           risky: true)
        // Scan bound: a segment captured > 6 s before the system capture ends
        // the newest-first scan, so a text twin from minutes ago is safe.
        let ancient = seg(sysText, start: 0, end: 5,
                          capturedAt: t0.addingTimeInterval(-20),
                          committedAt: t0.addingTimeInterval(-20), risky: true)
        var ids = MicHoldback.retractionCandidates(
            committed: [ancient, released], systemText: sysText,
            systemCapturedAt: t0.addingTimeInterval(10), now: t0.addingTimeInterval(11.2),
            isDuplicate: match)
        t.check("committed risky segment retracted via commit-time race",
                ids == [released.id],
                "capture Δ5 s > 4 s window, commit Δ0.2 s ≤ 4 s — and the 20 s-old twin stays")

        // Clause 1 alone: committed-on-arrival segments race capture stamps
        // directly, even when the system transcript is processed much later.
        let direct = seg(sysText, capturedAt: t0.addingTimeInterval(5),
                         committedAt: t0.addingTimeInterval(5), risky: true)
        ids = MicHoldback.retractionCandidates(
            committed: [direct], systemText: sysText,
            systemCapturedAt: t0.addingTimeInterval(7), now: t0.addingTimeInterval(30),
            isDuplicate: match)
        t.check("capture-clock race retracts independently of commit distance",
                ids == [direct.id], "capture Δ2 s, commit Δ25 s")

        // Non-risky is never eligible, no matter how perfect the text match.
        let safe = seg(sysText, capturedAt: t0.addingTimeInterval(5),
                       committedAt: t0.addingTimeInterval(11), risky: false)
        ids = MicHoldback.retractionCandidates(
            committed: [safe], systemText: sysText,
            systemCapturedAt: t0.addingTimeInterval(10), now: t0.addingTimeInterval(11.2),
            isDuplicate: match)
        t.check("non-risky committed segment is never retracted", ids.isEmpty)

        // Forward guard: echo confirmation only runs forward — a system
        // segment captured BEFORE the mic candidate can't be its original.
        let backward = seg(sysText, capturedAt: t0.addingTimeInterval(10),
                           committedAt: t0.addingTimeInterval(10), risky: true)
        ids = MicHoldback.retractionCandidates(
            committed: [backward], systemText: sysText,
            systemCapturedAt: t0, now: t0.addingTimeInterval(10.5),
            isDuplicate: match)
        t.check("system segment captured before the candidate cannot retract it", ids.isEmpty)
    }

    // MARK: - 3. Gates (silence / bleed / system-activity window)

    private static func gatesSection(_ t: Tally) {
        print("\n  Audio gates — the constants that decide what whisper ever sees:")

        // Mirrors the (private) gate expression in MeetingTranscriber
        // .drainChannel, pinned via the public constants so a constant edit
        // fails here before it silently eats meeting audio.
        func stats(_ s: [Float]) -> (rms: Float, peak: Float) {
            var sum: Float = 0, peak: Float = 0
            for v in s { sum += v * v; if abs(v) > peak { peak = abs(v) } }
            return ((sum / Float(max(s.count, 1))).squareRoot(), peak)
        }
        func silentGated(_ s: [Float]) -> Bool {
            let (r, p) = stats(s)
            return r < MeetingTranscriber.silenceRMS && p < MeetingTranscriber.silencePeak
        }
        func bleedShaped(_ s: [Float]) -> Bool {
            let (r, p) = stats(s)
            return r < MeetingTranscriber.bleedRMS && p < MeetingTranscriber.bleedPeak
        }

        let floor = [Float](repeating: 0.001, count: 16_000)      // rms 0.0010 < 0.0015
        t.check("room-noise floor (rms 0.0010, peak 0.001) is silence-gated", silentGated(floor))

        var clicky = floor
        clicky[8_000] = 0.06                                       // one transient ≥ peak 0.05
        t.check("one 0.06 transient defeats the silence gate (peak clause keeps clicky speech)",
                !silentGated(clicky))

        let faint = sine(amp: 0.003)                               // rms ≈ 0.0021 ≥ 0.0015
        t.check("faint speech (sine rms 0.0021) passes the silence gate", !silentGated(faint),
                "rms \(String(format: "%.4f", stats(faint).rms))")

        // The system-dominant mic gate: bleed-shaped audio (quiet, under
        // 0.018 rms / 0.07 peak) is skipped ONLY while the far side speaks.
        let bleed = sine(amp: 0.02)                                // rms ≈ 0.0141, peak 0.02
        let loud = sine(amp: 0.1)                                  // rms ≈ 0.0707 ≥ 0.018
        t.check("speaker bleed (sine rms 0.0141, peak 0.02) is bleed-shaped", bleedShaped(bleed))
        t.check("real speech over the far side (rms 0.0707) is not", !bleedShaped(loud))

        print("\n  SystemActivityTracker — was the far side audible in this window:")
        let tracker = SystemActivityTracker()
        tracker.record(rms: 0.01, at: 1.0)
        t.check("chunk at t=1.0 rms 0.01 → speaking in [0.9, 1.1]",
                tracker.isSystemSpeaking(from: 0.9, to: 1.1))
        t.check("not speaking in [2.0, 3.0] (no chunk there)",
                !tracker.isSystemSpeaking(from: 2.0, to: 3.0))
        tracker.record(rms: 0.003, at: 2.5)                        // under minSystemRMS 0.004
        t.check("codec hiss (rms 0.003 < 0.004) never counts as speech",
                !tracker.isSystemSpeaking(from: 2.4, to: 2.6))
        tracker.record(rms: SystemActivityTracker.minSystemRMS, at: 3.5)
        t.check("exactly minSystemRMS counts (threshold is inclusive)",
                tracker.isSystemSpeaking(from: 3.4, to: 3.6))
        // The ring trims behind the newest offset: a chunk at t=20 evicts
        // everything before t=14, so the loud t=1.0 entry must be gone even
        // for a window that would otherwise include it.
        tracker.record(rms: 0.0001, at: 20)
        t.check("6 s ring: entry at t=20 evicts the t=1.0 chunk",
                !tracker.isSystemSpeaking(from: 0.5, to: 25))
    }

    // MARK: - 4. Notes chunker / renderer (no LLM)

    private static func notesSection(_ t: Tally) {
        print("\n  MeetingNotesGenerator — chunker and renderer (no model calls):")

        // Synthetic 1 h transcript: 360 segments, 10 s apart, speakers in
        // 6-segment turns, ~131 chars per line → ~47 k chars. Turn breaks
        // land at the 4th run boundary (~3,140 chars ≥ 2,850 threshold), so
        // the expected chunk count is 47 k / ~3.1 k ≈ 15 — inside the
        // 12-16 band the 3,800-char context budget implies for an hour.
        let body = "of the hour long meeting where we cover the quarterly roadmap the hiring plan and the launch checklist in detail"
        var hour: [MeetingSegment] = []
        for i in 0..<360 {
            hour.append(seg(String(format: "segment %03d ", i) + body,
                            source: (i / 6) % 2 == 0 ? .you : .them,
                            start: Double(i) * 10, end: Double(i) * 10 + 5))
        }
        let chunks = MeetingNotesGenerator.chunk(hour)
        let maxLen = chunks.map(\.count).max() ?? 0
        t.check("1 h transcript chunks into 12-16 pieces", (12...16).contains(chunks.count),
                "\(chunks.count) chunks")
        t.check("no chunk exceeds the 3,800-char context budget",
                maxLen <= MeetingNotesGenerator.chunkCharBudget, "largest \(maxLen) chars")
        // Rejoining the chunks must reproduce the ordered transcript exactly:
        // proves no segment was split mid-text and none was dropped.
        t.check("chunks reassemble to the ordered transcript byte-for-byte",
                chunks.joined(separator: "\n") == hour.orderedTranscriptText())

        // Renderer fixture: the exact OpenWhispr note shape, enforced by
        // construction — summary paragraph, ## sections in fixed order,
        // "- [ ]" checkboxes, "Unclear" unprefixed (it would read as a name).
        let full = MeetingNotesGenerator.render(
            summary: "Two teams agreed a launch plan.",
            sections: MeetingNotesGenerator.Sections(
                discussion: ["point one", "point two"],
                decisions: ["decision one"],
                actions: [.init(owner: "You", text: "ship the beta"),
                          .init(owner: "Them", text: "send the contract"),
                          .init(owner: "Unclear", text: "review the metrics dashboard")],
                followups: ["revisit pricing next week"]))
        let expected = """
        Two teams agreed a launch plan.

        ## Key Discussion Points
        - point one
        - point two

        ## Decisions Made
        - decision one

        ## Action Items
        - [ ] You: ship the beta
        - [ ] Them: send the contract
        - [ ] review the metrics dashboard

        ## Follow-ups
        - revisit pricing next week
        """
        t.check("renderer emits the exact markdown shape", full == expected)

        let sparse = MeetingNotesGenerator.render(
            summary: "",
            sections: MeetingNotesGenerator.Sections(
                discussion: [], decisions: [],
                actions: [.init(owner: "You", text: "send the recap")], followups: []))
        t.check("empty summary and empty sections are omitted entirely",
                sparse == "## Action Items\n- [ ] You: send the recap")
        t.check("all-empty sections render to nothing",
                MeetingNotesGenerator.render(summary: "",
                    sections: MeetingNotesGenerator.Sections(
                        discussion: [], decisions: [], actions: [], followups: [])).isEmpty)

        // Merge: cross-chunk repetition collapses with the echo matcher, and
        // a duplicate that KNOWS the owner upgrades an Unclear one — the
        // commitment and its attribution can land in different chunks.
        let m1 = MeetingNotesGenerator.MapOutput(
            summary: "s1", discussion: ["the vendor demo went well"], decisions: [],
            actions: [.init(owner: "Unclear", text: "ship the beta build on friday")], followups: [])
        let m2 = MeetingNotesGenerator.MapOutput(
            summary: "s2", discussion: ["the vendor demo went well overall"], decisions: [],
            actions: [.init(owner: "You", text: "ship the beta build friday")], followups: [])
        let merged = MeetingNotesGenerator.merge([m1, m2])
        t.check("near-identical bullets from adjacent chunks dedup to the first wording",
                merged.discussion == ["the vendor demo went well"])
        t.check("duplicate action upgrades Unclear owner, keeps first wording",
                merged.actions == [.init(owner: "You", text: "ship the beta build on friday")])

        // transcriptHash is the notes-staleness anchor: stable across
        // insertion order (sorted by start), sensitive to any text change.
        let h1 = hour.transcriptHash()
        t.check("same segments hash identically", h1 == hour.transcriptHash())
        t.check("insertion order does not change the hash (sorted by start)",
                Array(hour.reversed()).transcriptHash() == h1)
        var edited = hour
        edited[100] = seg(edited[100].text + " x", source: edited[100].source,
                          start: edited[100].start, end: edited[100].end)
        t.check("one text change changes the hash", edited.transcriptHash() != h1)
    }

    // MARK: - 5. MeetingStore (scratch dir)

    @MainActor
    private static func storeSection(_ t: Tally, scratch: URL) async {
        print("\n  MeetingStore — append-only index, tombstones, crash tolerance (scratch dir):")
        let base = scratch.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Segment dates use a whole-second epoch (ISO-8601 coding drops
        // sub-second precision); record dates must be RECENT or the 1-day
        // retention sweep below would reap the "fresh" meeting too.
        let epoch = Date(timeIntervalSince1970: 1_754_000_000)
        let started = Date().addingTimeInterval(-600)

        let store1 = MeetingStore(baseDir: base)
        let m1 = UUID(), m2 = UUID()
        store1.create(MeetingRecord(id: m1, date: started, title: "", durationSeconds: 0,
                                    appName: "Zoom", noteState: NoteState.none, deleted: nil),
                      meta: MeetingMeta(startedAt: started, trigger: "us.zoom.xos", appName: "Zoom"))
        // Mutation = append; load folds last-record-per-id-wins.
        store1.update(MeetingRecord(id: m1, date: started, title: "Renamed", durationSeconds: 300,
                                    appName: "Zoom", noteState: NoteState.none, deleted: nil))
        store1.updateMeta(m1) { $0.endedAt = started.addingTimeInterval(300) }

        // m2 stays mid-recording-shaped (noteState .none, meta.endedAt nil) —
        // the orphan the bootstrap sweep must find after a crash.
        store1.create(MeetingRecord(id: m2, date: started.addingTimeInterval(60), title: "",
                                    durationSeconds: 0, appName: "", noteState: NoteState.none,
                                    deleted: nil),
                      meta: MeetingMeta(startedAt: started.addingTimeInterval(60),
                                        trigger: "manual", appName: ""))
        let sA = seg("first thing said", source: .them, start: 0, end: 5,
                     capturedAt: epoch, committedAt: epoch)
        let sB = seg("a risky mic line", source: .you, start: 5, end: 10,
                     capturedAt: epoch, committedAt: epoch, risky: true)
        let sC = seg("closing remark", source: .them, start: 10, end: 15,
                     capturedAt: epoch, committedAt: epoch)
        store1.appendTranscriptLine(m2, .segment(sA))
        store1.appendTranscriptLine(m2, .segment(sB))
        store1.appendTranscriptLine(m2, .segment(sC))
        // Retraction is an append, never a rewrite (crash safety) — loading
        // must apply the tombstone.
        store1.appendTranscriptLine(m2, .retraction(MeetingRetraction(retractedID: sB.id, at: epoch)))

        var segs = store1.loadSegments(m2)
        t.check("transcript round-trip applies the retraction tombstone",
                segs.map(\.id) == [sA.id, sC.id] && segs.map(\.text) == [sA.text, sC.text])

        // Barrier: loadSegments above ran queue.sync, so every earlier write
        // reached disk. Now tear the index's final line the way a crash
        // mid-append would.
        let indexURL = base.appendingPathComponent("meetings.jsonl")
        if let handle = try? FileHandle(forWritingTo: indexURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{\"id\":\"torn-half-li".utf8))
            try? handle.close()
        }

        let store2 = MeetingStore(baseDir: base)
        let loaded = await settle(store2) { $0.count == 2 }
        t.check("fresh init survives a torn final index line", loaded.count == 2,
                "\(loaded.count) records loaded")
        let rec1 = loaded.first { $0.id == m1 }
        t.check("create/update round-trip: last record per id wins",
                rec1?.title == "Renamed" && rec1?.durationSeconds == 300)
        segs = store2.loadSegments(m2)
        t.check("transcript survives reload from disk",
                segs.map(\.id) == [sA.id, sC.id])
        t.check("orphanedRecordingIDs finds only the record whose meta lacks endedAt",
                store2.orphanedRecordingIDs() == [m2],
                "m1 has endedAt, m2 does not")

        // A torn final line has no trailing newline, so the file may only be
        // appended to again after compaction rewrites it — which is exactly
        // what the store does across launches. Pin that the rewrite reaps
        // both the superseded m1 line and the torn fragment: 4 physical
        // lines + fragment → one clean line per live record.
        store2.compact()
        _ = store2.loadNotes(UUID())   // queue barrier: compaction done
        let indexText = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        t.check("compaction reaps superseded lines and the torn fragment",
                indexText.split(separator: "\n").count == 2 && indexText.hasSuffix("\n"),
                "\(indexText.split(separator: "\n").count) lines for 2 live records")

        store2.delete(m1)
        _ = store2.loadNotes(m1)   // queue barrier: tombstone + folder removal done
        t.check("delete removes the meeting folder immediately",
                !FileManager.default.fileExists(atPath: store2.folderURL(m1).path))

        let store3 = MeetingStore(baseDir: base)
        let afterDelete = await settle(store3) { $0.count == 1 }
        t.check("delete tombstone hides the record after a fresh init",
                afterDelete.map(\.id) == [m2])

        // Retention: a 3-day-old record dies under 1-day retention, the
        // fresh one survives, and the swept folder is gone on disk.
        let m3 = UUID()
        let old = Date().addingTimeInterval(-3 * 86_400)
        store3.create(MeetingRecord(id: m3, date: old, title: "Old", durationSeconds: 60,
                                    appName: "", noteState: .done, deleted: nil),
                      meta: MeetingMeta(startedAt: old, endedAt: old.addingTimeInterval(60),
                                        trigger: "manual", appName: ""))
        _ = await settle(store3) { $0.contains { $0.id == m3 } }
        store3.sweep(retentionDays: 1)
        let afterSweep = await settle(store3) { !$0.contains { $0.id == m3 } }
        t.check("sweep(retentionDays: 1) removes the old record, keeps the fresh one",
                afterSweep.map(\.id) == [m2])
        t.check("sweep deletes the expired folder and keeps the live one",
                !FileManager.default.fileExists(atPath: store3.folderURL(m3).path)
                && FileManager.default.fileExists(atPath: store3.folderURL(m2).path))

        let store4 = MeetingStore(baseDir: base)
        let final4 = await settle(store4) { $0.count == 1 }
        t.check("post-sweep state survives a fresh init", final4.map(\.id) == [m2])
    }

    /// Wait for the store's main-published `records` to satisfy `pred`.
    /// loadNotes(UUID()) is a queue.sync no-op that barriers every earlier
    /// disk write; the poll then lets the main-queue publication land.
    @MainActor
    private static func settle(_ store: MeetingStore,
                               until pred: ([MeetingRecord]) -> Bool) async -> [MeetingRecord] {
        for _ in 0..<150 {
            _ = store.loadNotes(UUID())
            if pred(store.records) { return store.records }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return store.records
    }

    // MARK: - 6. Detection state machine

    @MainActor
    private static func detectionSection(_ t: Tally) async {
        print("\n  MeetingDetectionEngine — auto start/stop (fake clock, thresholds 50-300 ms):")
        let zoom = MicActivityMonitor.MicUser(pid: 100, bundleID: "us.zoom.xos")

        // -- Known app holding the mic, sustained → .autoApp start --
        var h = DetectionHarness()
        h.engine.arm()
        h.micUsers([zoom])
        t.check("zoom holding the mic enters pending, does not fire immediately",
                h.isPending && h.starts.isEmpty)
        h.advance(0.2)                       // > sustain 0.1
        h.micUsers([zoom])
        t.check("sustained hold fires onShouldStart with .autoApp trigger",
                h.starts.count == 1 && h.starts.first?.kind == .autoApp
                && h.starts.first?.bundleID == "us.zoom.xos"
                && h.starts.first?.appName == "Zoom")
        h.teardown()

        // -- Unknown bundle (Voice Memos): never, however long it holds --
        h = DetectionHarness()
        h.engine.arm()
        let vm = MicActivityMonitor.MicUser(pid: 200, bundleID: "com.apple.VoiceMemos")
        h.micUsers([vm])
        h.advance(1.0)
        h.micUsers([vm])
        t.check("Voice Memos (unknown bundle) never starts a meeting",
                h.engine.state == .armed && h.starts.isEmpty)
        h.teardown()

        // -- FaceTime gated by the setting --
        h = DetectionHarness()
        h.engine.arm()
        let facetime = MicActivityMonitor.MicUser(pid: 300, bundleID: "com.apple.FaceTime")
        h.micUsers([facetime])
        t.check("FaceTime with detection off stays armed", h.engine.state == .armed)
        h.enabledPersonalCallApps = [MeetingApps.facetime]
        h.micUsers([facetime])
        h.advance(0.2)
        h.micUsers([facetime])
        t.check("FaceTime with detection on starts after sustain",
                h.starts.count == 1 && h.starts.first?.appName == "FaceTime")
        h.teardown()

        // -- Browser holder: only a probe hit corroborates --
        h = DetectionHarness()
        h.engine.arm()
        let chrome = MicActivityMonitor.MicUser(pid: 400,
                                                bundleID: "com.google.Chrome.helper.renderer")
        h.micUsers([chrome])                 // probe fires (miss) at pending entry
        await pump()
        h.advance(0.2)
        h.micUsers([chrome])                 // reprobe due (fake 0.2 s ≥ 0.05) — still a miss
        await pump()
        t.check("browser holding the mic with no meeting tab never starts",
                h.starts.isEmpty && h.isPending)
        h.probeHit = true
        h.advance(0.1)
        h.micUsers([chrome])                 // reprobe → hit → corroborated
        await pump(until: { !h.starts.isEmpty })
        t.check("probe hit corroborates → .autoBrowser start",
                h.starts.count == 1 && h.starts.first?.kind == .autoBrowser)
        h.teardown()

        // -- Safari: capture lives in WebKit's GPU process, whose bundle ID
        // shares no prefix with Safari's (the missed-Meet-call bug) --
        h = DetectionHarness()
        h.engine.arm()
        let safari = MicActivityMonitor.MicUser(pid: 500, bundleID: "com.apple.WebKit.GPU")
        h.probeHit = true
        h.micUsers([safari])                 // probe fires (hit) at pending entry
        await pump()
        h.advance(0.2)
        h.micUsers([safari])
        await pump(until: { !h.starts.isEmpty })
        t.check("Safari's WebKit GPU helper resolves to Safari → .autoBrowser start",
                h.starts.count == 1 && h.starts.first?.kind == .autoBrowser
                && h.starts.first?.appName == "Safari")
        h.teardown()

        // -- Safari mute vs hang-up: Safari tears down capture on MUTE, so a
        // browser capture hitting the mic-idle deadline consults the probe —
        // meeting tab still open defers the stop; tab gone lets it fire --
        h = DetectionHarness()
        h.engine.browserMuteHold = 0.6
        h.engine.arm()
        let safariCall = MicActivityMonitor.MicUser(pid: 501, bundleID: "com.apple.WebKit.GPU")
        h.probeHit = true
        h.micUsers([safariCall])
        await pump()
        h.advance(0.2)
        h.micUsers([safariCall])
        await pump()
        h.engine.meetingDidStart()
        h.micUsers([])                       // mute: the mic is released
        t.check("muted browser capture enters stopPending", h.isStopPending)
        h.advance(0.2)                       // past stopAfterInactive 0.15
        h.micUsers([])                       // deadline → probe → hit → defer
        await pump()
        t.check("meeting tab still open defers the mic-idle stop",
                h.stops.isEmpty && h.isStopPending)
        h.probeHit = false                   // hang-up: tab closed / title reverted
        h.advance(0.1)
        h.micUsers([])
        await pump(until: { !h.stops.isEmpty })
        t.check("tab gone → the deferred stop fires .micIdle", h.stops == [.micIdle])
        h.teardown()

        // -- The defer is bounded: past browserMuteHold, mic idle wins even
        // with a matching tab still open (a leave page must not record
        // silence to the 4 h cap) --
        h = DetectionHarness()
        h.engine.browserMuteHold = 0.3
        h.engine.arm()
        h.probeHit = true
        h.micUsers([safariCall])
        await pump()
        h.advance(0.2)
        h.micUsers([safariCall])
        await pump()
        h.engine.meetingDidStart()
        h.micUsers([])
        h.advance(0.35)                      // ≥ browserMuteHold
        h.micUsers([])
        await pump(until: { !h.stops.isEmpty })
        t.check("past the bounded hold the stop fires even with the tab open",
                h.stops == [.micIdle])
        h.teardown()

        // -- Dictation suppression, incl. the 0.1 s post-dictation cooldown --
        h = DetectionHarness()
        h.engine.arm()
        h.engine.setUserDictating(true)
        h.micUsers([zoom])
        t.check("mic grab during dictation is ignored", h.engine.state == .armed)
        h.engine.setUserDictating(false)
        h.micUsers([zoom])
        t.check("post-dictation cooldown still suppresses (mic teardown looks like activity)",
                h.engine.state == .armed)
        h.advance(0.2)                       // past the 0.1 s cooldown
        h.micUsers([zoom])
        t.check("after the cooldown the same holder enters pending", h.isPending)
        h.engine.setUserDictating(true)
        t.check("dictation starting kills a pending detection", h.engine.state == .armed)
        h.teardown()

        // -- capturing → holder inactive → stopPending → .micIdle --
        guard var cap = capturedHarness(zoom, t) else { return }
        cap.h.micUsers([])
        t.check("holder releasing the mic enters stopPending (still capturing)",
                cap.h.isStopPending && cap.h.stops.isEmpty)
        cap.h.advance(0.2)                   // > stopAfterInactive 0.15
        cap.h.micUsers([])
        t.check("sustained mic idle fires onShouldStop(.micIdle)",
                cap.h.stops == [.micIdle])
        cap.h.teardown()

        // -- Reactivation during stopPending resumes the SAME meeting --
        guard let cap2 = capturedHarness(zoom, t) else { return }
        cap = cap2
        cap.h.micUsers([])
        cap.h.advance(0.05)                  // inside the 0.15 s countdown
        cap.h.micUsers([zoom])
        var resumed = false
        if case .capturing(let since, let holder) = cap.h.engine.state {
            // The ORIGINAL start survives the blip, so duration and the 4 h
            // cap stay honest — and no second onShouldStart may fire.
            resumed = since == cap.since && holder.pid == zoom.pid
        }
        t.check("mic blip resumes the same meeting with its original start",
                resumed && cap.h.starts.count == 1 && cap.h.stops.isEmpty)

        // -- Manual stop → cooldown blocks re-trigger until it lapses --
        cap.h.engine.meetingWasStopped(manually: true)
        cap.h.micUsers([zoom])
        t.check("manual-stop cooldown blocks a new start on the same call",
                cap.h.isCooldown && cap.h.starts.count == 1)
        cap.h.advance(0.35)                  // past manualCooldown 0.3
        cap.h.micUsers([zoom])
        cap.h.advance(0.15)
        cap.h.micUsers([zoom])
        t.check("cooldown lapse re-arms and the holder starts again",
                cap.h.starts.count == 2)
        cap.h.teardown()

        // -- Tier-2 (attributed: false) requires corroboration --
        let anon = MicActivityMonitor.MicUser(pid: -1, bundleID: nil)
        h = DetectionHarness()
        h.engine.arm()
        h.micUsers([anon], attributed: false)
        h.advance(0.2)
        h.micUsers([anon], attributed: false)
        t.check("device-level mic activity alone never starts (tier-2 uncorroborated)",
                h.starts.isEmpty && h.isPending)
        h.engine.handle(.appLaunched(bundleID: "us.zoom.xos"))
        t.check("a meeting app launching corroborates tier-2 → .autoApp",
                h.starts.count == 1 && h.starts.first?.kind == .autoApp
                && h.starts.first?.appName == "Zoom")
        h.teardown()

        h = DetectionHarness()
        h.runningApps = ["com.microsoft.teams"]
        h.engine.arm()
        h.micUsers([anon], attributed: false)
        h.advance(0.2)
        h.micUsers([anon], attributed: false)
        t.check("an already-running meeting app corroborates tier-2",
                h.starts.count == 1 && h.starts.first?.appName == "Microsoft Teams")
        h.teardown()

        // -- WhatsApp (ADR 33): opt-in + input+output dwell --
        let waCall = MicActivityMonitor.MicUser(pid: 600, bundleID: MeetingApps.whatsapp,
                                                runningOutput: true)
        let waMicOnly = MicActivityMonitor.MicUser(pid: 600, bundleID: MeetingApps.whatsapp)

        h = DetectionHarness()
        h.engine.arm()
        h.micUsers([waCall])
        h.advance(0.5)
        h.micUsers([waCall])
        t.check("WhatsApp with the toggle off stays armed, even mid-call",
                h.engine.state == .armed && h.starts.isEmpty)
        h.teardown()

        // Voice note: input-only never corroborates; the corroboration
        // window expiry latches the holder; release clears the latch.
        h = DetectionHarness()
        h.enabledPersonalCallApps = [MeetingApps.whatsapp]
        h.engine.arm()
        h.micUsers([waMicOnly])
        t.check("WhatsApp mic-only (voice note) enters pending, no start",
                h.isPending && h.starts.isEmpty)
        h.advance(0.4)                        // > sustain and > dwell — output never ran
        h.micUsers([waMicOnly])
        t.check("voice note never fires however long it records",
                h.starts.isEmpty && h.isPending)
        h.advance(5.0)                        // > corroborationWindow
        h.micUsers([waMicOnly])
        t.check("voice-note holder latches out after the corroboration window",
                h.engine.state == .armed && h.starts.isEmpty)
        h.micUsers([waMicOnly])
        t.check("latched holder stays out while it keeps the mic",
                h.engine.state == .armed)
        h.micUsers([])                        // release clears the latch…
        h.micUsers([waMicOnly])               // …fresh acquisition, fresh window
        t.check("mic release clears the latch for the next acquisition", h.isPending)
        h.teardown()

        // Call: concurrent input+output sustained past the dwell fires.
        h = DetectionHarness()
        h.enabledPersonalCallApps = [MeetingApps.whatsapp]
        h.engine.arm()
        h.micUsers([waCall])
        t.check("WhatsApp call enters pending, does not fire immediately",
                h.isPending && h.starts.isEmpty)
        h.advance(0.2)                        // > dwell 0.1 and > sustain 0.1
        h.micUsers([waCall])
        t.check("input+output past the dwell fires .autoApp WhatsApp",
                h.starts.count == 1 && h.starts.first?.kind == .autoApp
                && h.starts.first?.bundleID == MeetingApps.whatsapp
                && h.starts.first?.appName == "WhatsApp")

        // …and the call ends like any native holder: release → micIdle.
        h.engine.meetingDidStart()
        h.micUsers([])
        t.check("holder release enters the stop countdown", h.isStopPending)
        h.advance(0.2)                        // > stopAfterInactive 0.15
        h.micUsers([])
        t.check("mic idle past the deadline stops the WhatsApp call",
                h.stops == [.micIdle])
        h.teardown()

        // Output blip shorter than the dwell resets the clock.
        h = DetectionHarness()
        h.enabledPersonalCallApps = [MeetingApps.whatsapp]
        h.engine.arm()
        h.micUsers([waCall])                  // dwell clock starts
        h.advance(0.05)                       // < dwell
        h.micUsers([waMicOnly])               // output dropped — reset
        h.advance(0.3)
        h.micUsers([waMicOnly])
        t.check("an output blip below the dwell never accumulates into a call",
                h.starts.isEmpty && h.isPending)
        h.micUsers([waCall])                  // output resumes — dwell restarts
        h.advance(0.05)
        h.micUsers([waCall])
        t.check("dwell measures the CURRENT concurrency run, not history",
                h.starts.isEmpty)
        h.advance(0.1)
        h.micUsers([waCall])
        t.check("sustained concurrency after the reset fires", h.starts.count == 1)
        h.teardown()

        // Tier-2: WhatsApp must never corroborate anonymous mic use —
        // an all-day chat app running is not evidence of a call.
        h = DetectionHarness()
        h.enabledPersonalCallApps = [MeetingApps.whatsapp]
        h.runningApps = [MeetingApps.whatsapp]
        h.engine.arm()
        h.micUsers([anon], attributed: false)
        h.advance(0.2)
        h.micUsers([anon], attributed: false)
        t.check("tier-2: WhatsApp running never corroborates anonymous mic",
                h.starts.isEmpty && h.isPending)
        h.teardown()

        h = DetectionHarness()
        h.enabledPersonalCallApps = [MeetingApps.facetime]
        h.runningApps = [MeetingApps.facetime]
        h.engine.arm()
        h.micUsers([anon], attributed: false)
        h.advance(0.2)
        h.micUsers([anon], attributed: false)
        t.check("tier-2: FaceTime (enabled) still corroborates — behavior preserved",
                h.starts.count == 1 && h.starts.first?.appName == "FaceTime")
        h.teardown()

        // Regression for the substring bug the gate refactor fixed:
        // `facetime.contains(bundleID)` was String.contains, which admitted
        // partial IDs. Set membership must reject appexes and prefixes.
        h = DetectionHarness()
        h.engine.arm()
        h.micUsers([anon], attributed: false)
        h.engine.handle(.appLaunched(bundleID: "net.whatsapp.WhatsApp.ServiceExtension"))
        h.engine.handle(.appLaunched(bundleID: "com.apple"))
        h.advance(0.2)
        h.micUsers([anon], attributed: false)
        t.check("appex/partial bundle IDs never enter the corroboration set",
                h.starts.isEmpty && h.isPending)
        h.teardown()
    }

    /// Arm → pending → sustained → started → meetingDidStart, i.e. a harness
    /// sitting in .capturing with a known original start date.
    @MainActor
    private static func capturedHarness(_ zoom: MicActivityMonitor.MicUser, _ t: Tally)
        -> (h: DetectionHarness, since: Date)? {
        let h = DetectionHarness()
        h.engine.arm()
        h.micUsers([zoom])
        h.advance(0.2)
        h.micUsers([zoom])
        guard h.starts.count == 1 else {
            t.check("harness reaches capturing", false, "start never fired")
            return nil
        }
        let since = h.clock.t
        h.engine.meetingDidStart()
        return (h, since)
    }

    @MainActor
    private static func pump() async {
        // Lets probe completions (which hop through a main-actor Task) and
        // the engine's short real-time timers run.
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    /// Pumps until `condition` holds, or the budget runs out.
    ///
    /// Use this for an assertion that expects something to HAPPEN. A fixed
    /// sleep encodes an assumption about how fast the machine is: 40 ms is
    /// plenty on a developer Mac and demonstrably not enough on a loaded
    /// shared CI runner, where a main-actor Task hop can take far longer —
    /// the check then reads state the engine hasn't reached yet and fails a
    /// test whose logic is fine. Polling makes the check as fast as the
    /// machine allows and as patient as it needs to be.
    ///
    /// An assertion that nothing happens still wants the fixed `pump()`,
    /// which waits the window out instead of returning early.
    @MainActor
    private static func pump(until condition: () -> Bool,
                             budget: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(budget)
        repeat {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
    }

    // MARK: - 7. Pill layout table

    @MainActor
    private static func layoutSection(_ t: Tally) {
        print("\n  PillController.layout — the meeting rows of the sizing/placement table:")
        typealias L = PillController
        let rec = MeetingCenter.UIPhase.recording(started: Date(), micHealthy: true)

        var l = L.layout(phase: .idle, meeting: .idle, banner: nil, showIdlePill: true)
        t.check("idle + idle + idle pill on → 170 wide, visible, .keep",
                l.width == 170 && l.visible && l.placement == .keep)
        l = L.layout(phase: .idle, meeting: .idle, banner: nil, showIdlePill: false)
        t.check("idle + idle + idle pill off → hidden", !l.visible)

        l = L.layout(phase: .idle, meeting: rec, banner: nil, showIdlePill: false)
        t.check("idle + meeting recording → 232 chip, visible DESPITE idle pill off, .keep",
                l.width == 232 && l.height == 44 && l.visible && l.placement == .keep,
                "consent visibility outranks the idle-pill preference")

        l = L.layout(phase: .idle, meeting: .idle, banner: .finished(title: "T"), showIdlePill: true)
        t.check("idle + banner → 420 wide, .keep", l.width == 420 && l.placement == .keep)
        l = L.layout(phase: .idle, meeting: rec, banner: .started(app: "Zoom"), showIdlePill: true)
        t.check("banner outranks the meeting chip", l.width == 420 && l.placement == .keep)

        l = L.layout(phase: .recording(mode: .pushToTalk), meeting: rec, banner: nil,
                     showIdlePill: true)
        t.check("dictation .recording → 560, .follow (the ONE transition that may change screens)",
                l.width == 560 && l.height == 120 && l.placement == .follow)
        l = L.layout(phase: .typing, meeting: rec, banner: nil, showIdlePill: true)
        t.check("typing keeps its place and takes key",
                l.width == 520 && l.key && l.placement == .keep)

        // The ADR 0025/0027 invariant, exhaustively: with any non-idle
        // meeting state, every non-dictation-recording phase must .keep — a
        // meeting must never move the pill to another display.
        let phases: [AppState.Phase] = [.idle, .typing, .processing,
                                        .confirming("x"), .notice("x"), .success]
        let meetings: [MeetingCenter.UIPhase] = [
            .starting, rec, .recording(started: Date(), micHealthy: false),
            .processing(step: "Transcribing…"),
        ]
        let banners: [MeetingCenter.Banner?] = [nil, .started(app: "Zoom"),
                                                .finished(title: "T"), .micOnly]
        var moved = 0, rows = 0
        for phase in phases {
            for meeting in meetings {
                for banner in banners {
                    for show in [true, false] {
                        rows += 1
                        if L.layout(phase: phase, meeting: meeting, banner: banner,
                                    showIdlePill: show).placement != .keep {
                            moved += 1
                        }
                    }
                }
            }
        }
        t.check("every non-idle-meeting row outside dictation-recording is .keep",
                moved == 0, "\(rows) rows checked, \(moved) would move the pill")
    }

    // MARK: - 8. LIVE: whisper pipeline on a generated tone

    @MainActor
    private static func liveWhisperSection(_ t: Tally, scratch: URL) async {
        print("\n  LIVE — MeetingTranscriber over a generated 2 s 440 Hz tone:")
        guard Paths.whisperModelExists else {
            t.skip("whisper pipeline", "no whisper model at \(Paths.whisperModel.path)")
            return
        }

        // Synthesize the fixture through WavSpool — the same writer the
        // meeting spools use, so the WAV shape is the shipped one.
        let fixture = scratch.appendingPathComponent("tone-440.wav")
        if !FileManager.default.fileExists(atPath: fixture.path) {
            let spool = WavSpool(url: fixture)
            spool.append(sine(amp: 0.4, seconds: 2))
            spool.finalize()
        }
        let audio: [Float]
        do {
            audio = try SelfTest.loadAudio(path: fixture.path)
        } catch {
            t.check("SelfTest.loadAudio reads the generated fixture", false, "\(error)")
            return
        }
        t.check("SelfTest.loadAudio reads the generated fixture",
                audio.count == 32_000, "\(audio.count) samples (2 s @ 16 kHz)")

        let engine = WhisperEngine()
        do {
            let t0 = Date()
            try await engine.loadAndWarmUp(modelPath: Paths.whisperModel.path)
            print("        (model load+warmup \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        } catch {
            t.check("whisper model loads", false, "\(error)")
            return
        }

        let transcriber = MeetingTranscriber(engine: engine)
        transcriber.tickInterval = 0.4       // 1 s in production; the eval only needs ticks
        // The fixture is 2 s, well under the 8 s production minimum — shrink
        // the utterance policy so the tick path (not just the stop flush)
        // is what produces the chunk.
        transcriber.minUtteranceSeconds = 0.5
        transcriber.maxUtteranceSeconds = 2.0
        transcriber.dictationActive = { false }
        let chunkBox = LockedChunks()
        transcriber.onChunkTranscribed = { chunkBox.append($0) }

        // Feed both channels through the MeetingAudioConsumer seam in the
        // production cadence (~100 ms chunks of 16 kHz mono).
        let consumer: MeetingAudioConsumer = transcriber
        for start in stride(from: 0, to: audio.count, by: 1_600) {
            let end = min(start + 1_600, audio.count)
            let piece = Array(audio[start..<end])
            let at = TimeInterval(start) / 16_000
            consumer.micChunk(piece, at: at)
            consumer.systemChunk(piece, at: at)
        }

        transcriber.start()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let d0 = Date()
        await transcriber.stopAndDrain()
        let drainMs = Int(Date().timeIntervalSince(d0) * 1000)

        // A pure tone through VAD + gates yielding nothing IS a pass — the
        // pins are: the pipeline ran, drained every buffered sample, and any
        // chunk that did surface obeys the emit contract (non-empty text).
        let emitted = chunkBox.all()
        t.check("pipeline runs and drains without error",
                true, "drain \(drainMs) ms, \(emitted.count) chunk(s) emitted")
        t.check("emitted chunks (if any) carry non-empty text and sane bounds",
                emitted.allSatisfy { !$0.text.isEmpty && $0.end > $0.start },
                emitted.isEmpty ? "none emitted — VAD/gates did their job"
                                : emitted.map { "\($0.source): \"\($0.text.prefix(30))\"" }
                                    .joined(separator: ", "))
    }

    // MARK: - 9. LIVE: system-audio tap

    @MainActor
    private static func liveTapSection(_ t: Tally) async {
        print("\n  LIVE — SystemAudioTap start/frames/stop and aggregate hygiene:")
        guard Permissions.systemAudio == .granted else {
            t.skip("system-audio tap", "permission is \(Permissions.systemAudio.rawValue), not granted")
            return
        }

        let before = deviceCount()
        let tap = SystemAudioTap()
        let frames = LockedCounter()
        tap.chunkHandler = { samples, _ in frames.add(samples.count) }

        do {
            // start() blocks up to ~2 s in the device-alive poll — keep it
            // off the pumped main thread.
            try await Task.detached { try tap.start() }.value
        } catch {
            if case SystemAudioTap.TapError.permissionDenied = error {
                // The cache said granted but TCC now says no; start() already
                // reconciled the cache, so the next run will SKIP honestly.
                t.skip("system-audio tap", "TCC revoked since the cached grant — cache reconciled")
            } else {
                t.check("tap starts", false, "\(error)")
            }
            return
        }

        // A live tap delivers its first IOProc callback within ~100 ms; 3 s
        // is the same generosity as the tap's own verify watchdog.
        var sawFrames = false
        for _ in 0..<30 {
            if frames.value > 0 { sawFrames = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        t.check("frames arrive within 3 s of start", sawFrames,
                "\(frames.value) frames so far")
        await Task.detached { tap.stop() }.value

        // Three full cycles: each start creates a tap + private aggregate;
        // each stop must destroy both, or a weekend of meetings litters
        // coreaudiod with dead aggregates. The 250 ms settle between cycles
        // is load-bearing on the macOS 27 beta: coreaudiod destroys taps
        // asynchronously (same reason the aggregate-count check below has a
        // settling beat), and an instant re-create lands on an object still
        // mid-teardown — AudioHardwareCreateProcessTap returns '!obj'
        // (kAudioHardwareBadObjectError, 560947818). Production never
        // rapid-cycles: the shortest real gap is the 60 s auto-rearm.
        var cycleFailure: String?
        for i in 1...3 {
            do {
                try? await Task.sleep(nanoseconds: 250_000_000)
                try await Task.detached { try tap.start() }.value
                try? await Task.sleep(nanoseconds: 150_000_000)
                await Task.detached { tap.stop() }.value
            } catch {
                cycleFailure = "cycle \(i): \(error)"
                break
            }
        }
        t.check("start/stop x3 completes", cycleFailure == nil, cycleFailure ?? "")

        var after = deviceCount()
        if after != before {
            // coreaudiod tears aggregates down asynchronously under load —
            // give it one settling beat before calling it a leak.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            after = deviceCount()
        }
        t.check("no aggregate devices leaked", after == before,
                "devices \(before) → \(after)")
    }

    /// kAudioHardwarePropertyDevices count — the AudioRecorder.allDeviceIDs
    /// enumeration, reduced to the only number the leak check needs. The
    /// tap's aggregate is private but IS visible to its creating process
    /// (see MicActivityMonitor), which is exactly what makes this work.
    private static func deviceCount() -> Int {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return -1 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    // MARK: - Utterance chunking (pure pieces, ADR 34)

    private static func chunkingSection(_ t: Tally) {
        print("\n  MeetingTranscriber — pause-aligned utterance cutting:")
        typealias MT = MeetingTranscriber
        let fps = MT.framesPerSecond                       // 50 frames/s

        /// Build frame energies directly: `speech` and `gap` in seconds.
        func frames(_ parts: [(Float, TimeInterval)]) -> [Float] {
            parts.flatMap { level, seconds in
                [Float](repeating: level, count: max(1, Int(seconds * Double(fps))))
            }
        }
        let speech: Float = 0.08, quiet: Float = 0.001
        func cut(_ e: [Float], flushing: Bool = false,
                 minS: TimeInterval = 8, maxS: TimeInterval = 24) -> Int? {
            MT.utteranceCut(energies: e, flushing: flushing, minSeconds: minS,
                            maxSeconds: maxS, pauseSeconds: 0.45, pauseRMS: 0.006)
        }

        // Below the minimum nothing is cut — short windows are what produced
        // the fragment-and-hallucinate behavior in the field.
        t.check("under the minimum, keep buffering",
                cut(frames([(speech, 5.0)])) == nil)
        t.check("under the minimum, a stopping meeting still flushes",
                cut(frames([(speech, 5.0)]), flushing: true) == 250)

        // 10 s of speech, a 0.6 s breath, then more speech: cut in the breath.
        let withPause = frames([(speech, 10.0), (quiet, 0.6), (speech, 6.0)])
        if let c = cut(withPause) {
            let seconds = Double(c) / Double(fps)
            t.check("cuts inside the pause, not mid-word",
                    seconds > 10.0 && seconds < 10.6,
                    String(format: "cut at %.2f s (pause spans 10.00-10.60)", seconds))
        } else {
            t.check("cuts inside the pause, not mid-word", false, "no cut offered")
        }

        // A pause BEFORE the minimum is ignored — it must neither cut early
        // nor be "used up": with no later pause the buffer keeps growing.
        t.check("a pause before the minimum never cuts early",
                cut(frames([(speech, 2.0), (quiet, 1.0), (speech, 12.0)])) == nil)
        // …and once a real pause arrives past the minimum, that is the cut.
        let lateP = frames([(speech, 2.0), (quiet, 1.0), (speech, 8.0), (quiet, 0.6), (speech, 5.0)])
        if let c = cut(lateP) {
            let seconds = Double(c) / Double(fps)
            t.check("the first pause past the minimum is the cut",
                    seconds > 11.0 && seconds < 11.6,
                    String(format: "cut at %.2f s (pause spans 11.00-11.60)", seconds))
        } else {
            t.check("the first pause past the minimum is the cut", false, "no cut")
        }

        // Unbroken talker: forced at the maximum, on the quietest frame.
        let relentless = frames([(speech, 40.0)])
        if let c = cut(relentless) {
            let seconds = Double(c) / Double(fps)
            t.check("a talker who never pauses is force-cut at the maximum",
                    seconds > 22.9 && seconds <= 24.0,
                    String(format: "cut at %.2f s", seconds))
        } else {
            t.check("a talker who never pauses is force-cut at the maximum", false, "no cut")
        }

        // The forced cut prefers the quietest frame it can see.
        var dip = frames([(speech, 40.0)])
        dip[Int(23.5 * Double(fps))] = 0.002
        if let c = cut(dip) {
            t.check("the forced cut lands on the quietest frame available",
                    c == Int(23.5 * Double(fps)),
                    "frame \(c) vs dip at \(Int(23.5 * Double(fps)))")
        } else {
            t.check("the forced cut lands on the quietest frame available", false, "no cut")
        }

        // Silence-only buffers still get consumed (the gates drop them after).
        t.check("a silent buffer past the maximum is still cut (gates drop it)",
                cut(frames([(quiet, 30.0)])) != nil)

        // Loudest-window vs whole-chunk average: the regression that deleted
        // real sentences from long utterances.
        let sentenceInSilence = frames([(quiet, 18.0), (0.09, 2.0)])
        let avg = sentenceInSilence.reduce(0, +) / Float(sentenceInSilence.count)
        let loudest = MT.loudestWindowRMS(energies: sentenceInSilence, windowFrames: fps)
        t.check("a sentence inside a long silence survives the gates",
                avg < MT.bleedRMS && loudest > MT.bleedRMS,
                String(format: "whole-chunk avg %.4f would drop it; loudest second %.4f keeps it",
                       avg, loudest))

        // Frame energies: shape and values.
        let e = MT.frameEnergies([Float](repeating: 0.5, count: 16_000), frameSamples: MT.frameSamples)
        t.check("frame energies cover the buffer at 20 ms resolution",
                e.count == 50 && abs(e[0] - 0.5) < 0.001, "\(e.count) frames")
    }

    // MARK: - SpeakerDiarizer (pure pieces, ADR 31)

    private static func diarizationSection(_ t: Tally) {
        print("\n  SpeakerDiarizer — turn alignment, labels, hash stability:")
        typealias Turn = SpeakerDiarizer.SpeakerTurn
        let epoch = Date(timeIntervalSince1970: 1_754_000_000)
        func them(_ text: String, _ start: TimeInterval, _ end: TimeInterval,
                  speaker: Int? = nil) -> MeetingSegment {
            MeetingSegment(id: UUID(), source: .them, text: text, start: start, end: end,
                           capturedAt: epoch, committedAt: epoch, risky: false,
                           speaker: speaker)
        }

        // Renumbering: opaque upstream ids, clusters 0-based by first speech.
        let turns = SpeakerDiarizer.normalizeTurns([
            (speakerId: "spk_B", start: 12.0, end: 18.0),
            (speakerId: "spk_A", start: 0.0, end: 6.0),
            (speakerId: "spk_B", start: 20.0, end: 24.0),
            (speakerId: "spk_A", start: 7.0, end: 11.0),
        ])
        t.check("clusters renumber 0-based by first speech time",
                turns.map(\.cluster) == [0, 0, 1, 1], "\(turns.map(\.cluster))")

        let two = [Turn(cluster: 0, start: 0, end: 10), Turn(cluster: 1, start: 10, end: 20)]

        let straddle = them("straddles the boundary", 8, 13)      // 2 s in c0, 3 s in c1
        t.check("straddling segment goes to the majority-overlap cluster",
                SpeakerDiarizer.assign([straddle], turns: two)[straddle.id] == 1)

        let drifted = them("whisper drift", 9.4, 14.4)            // 0.6 s c0, 4.4 s c1
        t.check("±0.8 s timestamp drift still lands on the right speaker",
                SpeakerDiarizer.assign([drifted], turns: two)[drifted.id] == 1)

        let brush = them("mm-hm", 9.9, 10.2)                      // both overlaps < 0.25 s floor
        t.check("sub-threshold overlap falls back to midpoint containment",
                SpeakerDiarizer.assign([brush], turns: two)[brush.id] == 1)

        let tail = them("after the turn", 20.4, 20.9)             // no overlap, edge 0.65 s away
        t.check("silence-adjacent segment snaps to the nearest turn within 1 s",
                SpeakerDiarizer.assign([tail], turns: two)[tail.id] == 1)

        let orphan = them("orphan", 30, 35)                       // > 1 s from every turn
        t.check("unattributable segment keeps generic Them",
                SpeakerDiarizer.assign([orphan], turns: two)[orphan.id] == nil)

        let mic = seg("me talking", source: .you, start: 2, end: 4)
        t.check("mic segments are never assigned a speaker",
                SpeakerDiarizer.assign([mic], turns: two)[mic.id] == nil)

        // annotate: only assigned .them rebuilt; text/order untouched ⇒ the
        // notes-staleness hash cannot flip. This is the ADR 31 hash pin.
        let transcript = [seg("hello", source: .you, start: 0, end: 4),
                          them("hi there", 4, 9),
                          them("second voice", 10, 15)]
        let hashBefore = transcript.transcriptHash()
        let assignments = SpeakerDiarizer.assign(transcript.filter { $0.source == .them },
                                                 turns: two)
        let annotated = SpeakerDiarizer.annotate(transcript, assignments: assignments)
        t.check("annotate tags only .them segments",
                annotated[0].speaker == nil && annotated[1].speaker == 0
                && annotated[2].speaker == 1)
        t.check("transcriptHash is stable across annotation (notes never go stale)",
                annotated.transcriptHash() == hashBefore)

        t.check("labels resolve You / Them / Speaker N / rename",
                annotated[0].displayLabel() == "You"
                && transcript[1].displayLabel() == "Them"
                && annotated[2].displayLabel() == "Speaker 2"
                && annotated[2].displayLabel(names: [1: "Priya"]) == "Priya")

        // Storage compatibility both ways.
        let legacyLine = #"{"id":"11111111-1111-1111-1111-111111111111","source":"them","#
            + #""text":"old line","start":1,"end":2,"capturedAt":700000000,"#
            + #""committedAt":700000000,"risky":false}"#
        let legacy = try? JSONDecoder().decode(MeetingSegment.self, from: Data(legacyLine.utf8))
        t.check("pre-ADR-31 transcript lines decode (speaker key optional)",
                legacy != nil && legacy?.speaker == nil)
        let roundTripped = (try? JSONEncoder().encode(annotated[2]))
            .flatMap { try? JSONDecoder().decode(MeetingSegment.self, from: $0) }
        t.check("speaker survives a JSONL round-trip", roundTripped?.speaker == 1)

        // Ratings (ADR 35): round-trip, and absent means "never asked".
        let rated = #"{"schemaVersion":1,"startedAt":700000000,"trigger":"manual",""#
            + #"appName":"Zoom","transcriptRating":"up","notesRating":"down"}"#
        let decodedRated = try? JSONDecoder().decode(MeetingMeta.self, from: Data(rated.utf8))
        t.check("thumbs round-trip through meta.json",
                decodedRated?.transcriptRating == .up && decodedRated?.notesRating == .down)
        var blank = MeetingMeta(startedAt: Date(), trigger: "manual", appName: "")
        t.check("an unrated meeting reads as unrated (drives the in-page ask)",
                blank.transcriptRating == nil && blank.notesRating == nil)
        blank.notesRating = .up
        let reencoded = (try? JSONEncoder().encode(blank))
            .flatMap { try? JSONDecoder().decode(MeetingMeta.self, from: $0) }
        t.check("a rating survives an encode/decode cycle", reencoded?.notesRating == .up)

        let newMeta = #"{"schemaVersion":1,"startedAt":700000000,"trigger":"manual","#
            + #""appName":"Zoom","speakerNames":{"0":"Priya"},"speakerCount":2}"#
        let oldMeta = #"{"schemaVersion":1,"startedAt":700000000,"trigger":"manual","appName":"Zoom"}"#
        let decodedNew = try? JSONDecoder().decode(MeetingMeta.self, from: Data(newMeta.utf8))
        t.check("meta speakerNames/speakerCount round-trip",
                decodedNew?.speakerNames?["0"] == "Priya" && decodedNew?.speakerCount == 2)
        t.check("pre-ADR-31 meta decodes",
                (try? JSONDecoder().decode(MeetingMeta.self, from: Data(oldMeta.utf8))) != nil)

        // Grouping + export merge respect the speaker boundary.
        let run = [them("a", 0, 2, speaker: 0), them("b", 2, 4, speaker: 0),
                   them("c", 4, 6, speaker: 1)]
        let rows = MeetingTranscriptView.groupRows(run, names: [1: "Priya"])
        t.check("same speaker continues its group; a new speaker breaks it",
                rows.map(\.isGroupStart) == [true, false, true])
        t.check("row labels resolve renames", rows[2].label == "Priya")
        let merged = MeetingExporter.mergeSegments(run)
        t.check("export merge joins same-speaker runs, refuses cross-speaker",
                merged.count == 2 && merged[0].text == "a b"
                && merged[0].speaker == 0 && merged[1].speaker == 1)
    }

    // MARK: - LIVE chunking A/B (skip-not-fail, ADR 34)

    /// The pin for the rewrite: the SAME speech, through the SAME whisper,
    /// cut the old way (blind 5 s) and the new way (pause-aligned). The old
    /// way lost roughly half the words on a real call; this refuses to let
    /// that regress. Needs a speech fixture — 16 kHz mono WAV via
    /// ZF_SPEECH_FIXTURE (scripts can make one with `say`).
    private static func liveChunkingABSection(_ t: Tally) async {
        print("\n  LIVE — utterance chunking vs the old blind 5 s cut:")
        guard Paths.whisperModelExists else {
            t.skip("chunking A/B", "no whisper model")
            return
        }
        guard let path = ProcessInfo.processInfo.environment["ZF_SPEECH_FIXTURE"],
              let audio = try? SelfTest.loadAudio(path: path), audio.count > 16_000 else {
            t.skip("chunking A/B", "set ZF_SPEECH_FIXTURE to a 16 kHz mono speech WAV")
            return
        }

        let engine = WhisperEngine()
        do { try await engine.loadAndWarmUp(modelPath: Paths.whisperModel.path) } catch {
            t.check("whisper model loads", false, "\(error)")
            return
        }

        /// Feed the fixture through one transcriber configuration.
        func run(label: String,
                 configure: (MeetingTranscriber) -> Void) async -> [MeetingTranscriber.RawChunk] {
            let transcriber = MeetingTranscriber(engine: engine)
            transcriber.tickInterval = 0.2
            transcriber.dictationActive = { false }
            configure(transcriber)
            let box = LockedChunks()
            transcriber.onChunkTranscribed = { box.append($0) }
            let consumer: MeetingAudioConsumer = transcriber
            for start in stride(from: 0, to: audio.count, by: 1_600) {
                let end = min(start + 1_600, audio.count)
                consumer.systemChunk(Array(audio[start..<end]), at: TimeInterval(start) / 16_000)
            }
            transcriber.start()
            await transcriber.stopAndDrain()
            let chunks = box.all().sorted { $0.start < $1.start }
            let text = chunks.map(\.text).joined(separator: " ")
            print("        \(label): \(chunks.count) span(s), \(text.split(separator: " ").count) words")
            return chunks
        }

        // v1: no pause is ever found (pauseRMS 0), so every chunk is a blind
        // 5 s force-cut — bit-for-bit the behavior being replaced.
        let old = await run(label: "old (blind 5 s)") {
            $0.minUtteranceSeconds = 5; $0.maxUtteranceSeconds = 5; $0.pauseRMS = 0
        }
        let new = await run(label: "new (pause-aligned)") { _ in }

        let oldText = old.map(\.text).joined(separator: " ")
        let newText = new.map(\.text).joined(separator: " ")
        let oldWords = oldText.split(separator: " ").count
        let newWords = newText.split(separator: " ").count
        t.check("pause-aligned chunking captures at least as many words as blind 5 s cuts",
                newWords >= oldWords, "\(newWords) vs \(oldWords) words")

        // The timestamp-mapping risk taken by turning whisper timestamps on
        // (ADR 34): with the Silero pre-filter active, spans must still be
        // stamped on the ORIGINAL timeline, not on VAD-compressed time.
        let duration = TimeInterval(audio.count) / 16_000
        let monotonic = zip(new, new.dropFirst()).allSatisfy { $0.start <= $1.start }
        let inWindow = new.allSatisfy { $0.start >= 0 && $0.end <= duration + 0.5 && $0.end > $0.start }
        let reachesEnd = (new.last?.end ?? 0) > duration - 5
        t.check("spans are stamped on the source timeline, in order, inside the audio",
                monotonic && inWindow && reachesEnd,
                String(format: "last span ends %.1f s of %.1f s", new.last?.end ?? 0, duration))
        print("        old: \(oldText.prefix(200))")
        print("        new: \(newText.prefix(200))")
    }

    // MARK: - LIVE diarizer smoke (skip-not-fail)

    private static func liveDiarizerSection(_ t: Tally, scratch: URL) async {
        print("\n  LIVE — offline diarizer over a synthetic 30 s clip:")
        guard Paths.diarizerModelsExist else {
            t.skip("diarizer models load and process", "models not installed — run scripts/setup.sh")
            return
        }

        // Two alternating tones. Not speech — pyannote may legitimately find
        // no voices in it, so the default assertion is only "completes
        // without wedging". Point ZF_DIARIZER_FIXTURE at a real two-speaker
        // WAV (16 kHz mono Int16) for the strict variant.
        let folder = scratch.appendingPathComponent("diar-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = ProcessInfo.processInfo.environment["ZF_DIARIZER_FIXTURE"]
        if let fixture {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: fixture),
                                              to: folder.appendingPathComponent("system.wav"))
        } else {
            var samples: [Float] = []
            for i in 0..<15 { samples += sine(amp: 0.3, seconds: 2.0, hz: i % 2 == 0 ? 220 : 480) }
            try? wavData(samples).write(to: folder.appendingPathComponent("system.wav"))
        }
        let epoch = Date(timeIntervalSince1970: 1_754_000_000)
        let segs = (0..<6).map { i in
            MeetingSegment(id: UUID(), source: .them, text: "chunk \(i)",
                           start: Double(i) * 5, end: Double(i) * 5 + 5,
                           capturedAt: epoch, committedAt: epoch, risky: false)
        }

        let started = Date()
        let outcome = await SpeakerDiarizer.run(folder: folder, segments: segs)
        let elapsed = Date().timeIntervalSince(started)
        let detail = String(format: "%.1f s — ", elapsed)
            + (outcome.map { "\($0.speakerCount) voice(s)" } ?? "no voices found")
        t.check("offline diarizer completes without wedging", elapsed < 240, detail)
        if fixture != nil {
            t.check("fixture clip yields at least one attributed voice",
                    (outcome?.speakerCount ?? 0) >= 1, detail)
        }
    }

    /// Minimal 16 kHz mono Int16 WAV writer (WavSpool's exact header shape).
    private static func wavData(_ samples: [Float]) -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + byteCount)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(16_000); put32(32_000); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(byteCount)
        for s in samples {
            let v = Int16(max(-1.0, min(1.0, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    // MARK: - Shared helpers

    /// Whole-second default dates so ISO-8601 round-trips compare equal.
    private static func seg(_ text: String, source: MeetingSegment.Source = .you,
                            start: TimeInterval = 0, end: TimeInterval = 5,
                            capturedAt: Date? = nil, committedAt: Date? = nil,
                            risky: Bool = false) -> MeetingSegment {
        let epoch = Date(timeIntervalSince1970: 1_754_000_000)
        return MeetingSegment(id: UUID(), source: source, text: text, start: start, end: end,
                              capturedAt: capturedAt ?? epoch.addingTimeInterval(end),
                              committedAt: committedAt ?? epoch.addingTimeInterval(end),
                              risky: risky)
    }

    private static func sine(amp: Float, seconds: Double = 1.0, hz: Double = 440) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { amp * Float(sin(2.0 * Double.pi * hz * Double($0) / 16_000)) }
    }
}

// MARK: - Reporting

private final class Tally {
    var failures = 0
    var checks = 0
    var skips = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        print((ok ? "  ok  " : "FAIL  ") + label + (detail.isEmpty ? "" : " — \(detail)"))
        if !ok { failures += 1 }
    }
    func skip(_ label: String, _ why: String) {
        skips += 1
        print("  SKIP \(label) — \(why)")
    }
}

// MARK: - Detection harness

/// A MeetingDetectionEngine on a scripted clock. Thresholds shrink to
/// 50-300 ms so the wall-clock timers the engine also schedules stay
/// harmless; every decision is driven by advancing the fake clock and
/// calling handle() — the engine re-derives from now() on every path, which
/// is exactly the property this harness exists to lean on.
@MainActor
private final class DetectionHarness {
    final class Clock { var t = Date() }
    let clock = Clock()
    let engine = MeetingDetectionEngine()
    private(set) var starts: [MeetingTrigger] = []
    private(set) var stops: [MeetingStopReason] = []
    var probeHit = false
    var enabledPersonalCallApps: Set<String> = []
    var runningApps: Set<String> = []

    init() {
        let clock = self.clock
        engine.now = { clock.t }
        engine.sustainSeconds = 0.1
        engine.stopAfterInactiveSeconds = 0.15
        engine.processQuitStopSeconds = 0.05
        engine.manualCooldown = 0.3
        engine.autoRearmDelay = 0.2
        engine.postDictationCooldown = 0.1
        engine.browserReprobeInterval = 0.05
        engine.corroborationWindow = 5
        engine.personalCallOutputDwell = 0.1
        engine.browserProbe = { [weak self] completion in completion(self?.probeHit ?? false) }
        engine.enabledPersonalCallApps = { [weak self] in self?.enabledPersonalCallApps ?? [] }
        engine.runningApps = { [weak self] in self?.runningApps ?? [] }
        engine.onShouldStart = { [weak self] trigger in self?.starts.append(trigger) }
        engine.onShouldStop = { [weak self] reason in self?.stops.append(reason) }
    }

    func advance(_ dt: TimeInterval) { clock.t = clock.t.addingTimeInterval(dt) }

    func micUsers(_ users: [MicActivityMonitor.MicUser], attributed: Bool = true) {
        engine.handle(.micUsers(users, attributed: attributed))
    }

    var isPending: Bool { if case .pending = engine.state { return true }; return false }
    var isStopPending: Bool { if case .stopPending = engine.state { return true }; return false }
    var isCooldown: Bool { if case .cooldown = engine.state { return true }; return false }

    /// Kill callbacks and bump the engine's generation so a straggling
    /// real-time timer from this scenario can't touch a later one.
    func teardown() {
        engine.onShouldStart = nil
        engine.onShouldStop = nil
        engine.disarm()
    }
}

// MARK: - Cross-queue collection boxes (chunk/tap callbacks arrive off-main)

private final class LockedChunks {
    private let lock = NSLock()
    private var chunks: [MeetingTranscriber.RawChunk] = []
    func append(_ c: MeetingTranscriber.RawChunk) {
        lock.lock(); chunks.append(c); lock.unlock()
    }
    func all() -> [MeetingTranscriber.RawChunk] {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
