import Foundation

/// Turns the two live audio streams into text chunks, sharing the app's
/// single Whisper context without ever starving dictation.
///
/// Chunking (rewritten 2026-08-09, ADR 34): utterances are cut at natural
/// PAUSES, not on a fixed cadence. v1 sliced blindly every 5 s, which put a
/// boundary in the middle of a word every few seconds — the decoder saw
/// 5 s of context-free audio starting mid-syllable, so words at both edges
/// were mangled or lost ("sum" -> "sam", "gross" -> "grass"), long turns
/// came back as disconnected fragments, and low-information slices invited
/// the initial prompt to be recited back as speech. Measured on a real
/// call: ~1.3 words/s captured against ~2.5 words/s spoken — half the
/// conversation.
///
/// Now a tick only ASKS whether the buffer ends at a good place: at least
/// `minUtteranceSeconds` of audio, cut inside the first pause of
/// `pauseSeconds`, and if a talker never pauses, forced at
/// `maxUtteranceSeconds` on the quietest frame available. Whisper then sees
/// whole utterances bounded by silence — the same shape the dictation path
/// (which transcribes the user accurately) has always fed it.
///
/// Scheduling: every `tickInterval` a tick fires on this file's own queue —
/// never the STT queue. A tick is skipped outright while the user dictates
/// (audio keeps accumulating; nothing is lost), so meeting work never even
/// *enters* the STT queue during dictation and a dictation final only ever
/// waits behind at most one already-in-flight meeting chunk. Measured on
/// Apple Silicon, large-v3-turbo-q8 runs ~10-20x realtime: a 20 s utterance
/// is ~1-2 s of context occupancy, which is also the worst added latency a
/// dictation final can see.
///
/// Falling behind (thermal throttling, RTF >= 1): the in-flight guard skips
/// ticks, backlog grows, and drains happen in `maxUtteranceSeconds` bites —
/// per-audio-second cost *drops* with bigger chunks since whisper's native
/// window is 30 s. No audio is ever dropped; the transcript just lags.
final class MeetingTranscriber: MeetingAudioConsumer {

    struct RawChunk {
        let source: MeetingSegment.Source
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let risky: Bool
    }

    // Ported constants — provenance: OpenWhispr ipcHandlers.js:5006-5013 and
    // :6146-6167 (silence + system-dominant gates), 5738-5741 (warmup).
    static let maxChunkSeconds: TimeInterval = 30.0        // whisper's native window
    static let silenceRMS: Float = 0.0015
    static let silencePeak: Float = 0.05
    static let bleedRMS: Float = 0.018                     // MEETING_MIC_BLEED_RMS_CEILING
    static let bleedPeak: Float = 0.07                     // MEETING_MIC_BLEED_PEAK_CEILING
    static let startupWarmupSeconds: TimeInterval = 1.5    // MEETING_STARTUP_WARMUP_MS
    static let vadTailSeconds: TimeInterval = 0.3          // SYSTEM_VAD_TAIL_MS

    // Utterance chunking (ADR 34). Not ported — the 5 s cadence they use is
    // exactly what these replace.
    static let defaultTickInterval: TimeInterval = 1.0     // how often we ASK, not how big a chunk is
    /// Never cut a chunk shorter than this: whisper needs context, and a
    /// 3-word window is where hallucinated filler comes from.
    static let defaultMinUtterance: TimeInterval = 8.0
    /// Someone who never pauses still gets cut here — bounded latency, and
    /// comfortably inside whisper's 30 s window.
    static let defaultMaxUtterance: TimeInterval = 24.0
    /// A gap this long is a sentence boundary to a listener, and a safe place
    /// to put a decoder boundary.
    static let defaultPauseSeconds: TimeInterval = 0.45
    /// Frame energy below this is "not speech" for cut-finding. Above the
    /// silence floor (0.0015) because room tone and codec hiss sit there —
    /// this looks for a gap in SPEECH, not for digital silence.
    static let defaultPauseRMS: Float = 0.006
    /// 20 ms — fine enough to land inside a 450 ms pause, coarse enough that
    /// scanning a 24 s buffer is a few thousand comparisons.
    static let frameSeconds: TimeInterval = 0.02
    /// A mic chunk whose loudest second reaches this is the user talking
    /// close to the mic, not speaker bleed — never held back as risky.
    static let clearlyUserRMS: Float = 0.05

    /// Fired on the tick queue for every non-empty transcribed chunk;
    /// MeetingSession hops to the main actor.
    var onChunkTranscribed: ((RawChunk) -> Void)?
    /// Injected so the transcriber stays eval-testable without AppState.
    var dictationActive: () -> Bool = { false }
    /// Poll cadence — how often the buffer is examined for a cut point.
    /// NOT the chunk length (that is the utterance policy below).
    var tickInterval: TimeInterval = MeetingTranscriber.defaultTickInterval
    var minUtteranceSeconds: TimeInterval = MeetingTranscriber.defaultMinUtterance
    var maxUtteranceSeconds: TimeInterval = MeetingTranscriber.defaultMaxUtterance
    var pauseSeconds: TimeInterval = MeetingTranscriber.defaultPauseSeconds
    var pauseRMS: Float = MeetingTranscriber.defaultPauseRMS

    let systemActivity = SystemActivityTracker()

    private let engine: WhisperEngine
    private let lock = NSLock()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    /// Samples consumed so far per channel — chunk offsets derive from these,
    /// never from timers.
    private var micConsumed: Int64 = 0
    private var systemConsumed: Int64 = 0
    private var micDropped = false

    private let tickQueue = DispatchQueue(label: "zeldaflow.meeting.transcribe", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var stopped = false
    private var warnedBacklog = false

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    // MARK: - MeetingAudioConsumer (called on the recorder's pipeline queue)

    func micChunk(_ samples: [Float], at offset: TimeInterval) {
        lock.lock()
        micBuffer.append(contentsOf: samples)
        lock.unlock()
    }

    func systemChunk(_ samples: [Float], at offset: TimeInterval) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        systemActivity.record(rms: rms, at: offset)
        lock.lock()
        systemBuffer.append(contentsOf: samples)
        lock.unlock()
    }

    // MARK: - Lifecycle

    func start() {
        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Cancels the cadence and drains every remaining buffered sample in
    /// <= 30 s bites. The meeting is over, so the dictation yield no longer
    /// applies — worst case we wait behind one dictation final on the STT
    /// queue, which is exactly the right priority.
    func stopAndDrain() async {
        timer?.cancel()
        timer = nil
        tickQueue.sync { stopped = true }
        while await drainOnce() {}
    }

    private func tick() {
        guard !stopped, !inFlight else { return }
        guard !dictationActive() else { return }
        let backlog = backlogSeconds()
        if backlog > 120, !warnedBacklog {
            warnedBacklog = true
            Log.error("MeetingTranscriber: backlog \(Int(backlog)) s — transcription " +
                      "is slower than realtime on this machine (transcript will lag)")
        }
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.drainOnce()
            self.tickQueue.async { self.inFlight = false }
        }
    }

    private func backlogSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let rate = Double(WhisperEngine.sampleRate)
        return max(Double(micBuffer.count), Double(systemBuffer.count)) / rate
    }

    // MARK: - Draining

    /// System first, then mic — deliberate (ported ordering): the system
    /// transcript must land first so it can confirm/drop held-back mic echo
    /// before the mic chunk of the same window is even judged.
    /// Returns true when any samples were consumed.
    private func drainOnce() async -> Bool {
        let didSystem = await drainChannel(.them)
        let didMic = await drainChannel(.you)
        return didSystem || didMic
    }

    private func drainChannel(_ source: MeetingSegment.Source) async -> Bool {
        let rate = Double(WhisperEngine.sampleRate)

        // Snapshot without copying (Swift arrays are copy-on-write) so the
        // cut scan runs outside the lock — the audio pipeline queue keeps
        // appending while we think.
        lock.lock()
        let buffer = source == .you ? micBuffer : systemBuffer
        let startSamples = source == .you ? micConsumed : systemConsumed
        let flushing = stopped
        lock.unlock()
        guard !buffer.isEmpty else { return false }

        let energies = Self.frameEnergies(buffer, frameSamples: Self.frameSamples)
        guard let cutFrame = Self.utteranceCut(
                energies: energies, flushing: flushing,
                minSeconds: minUtteranceSeconds, maxSeconds: maxUtteranceSeconds,
                pauseSeconds: pauseSeconds, pauseRMS: pauseRMS)
        else { return false }               // keep buffering — not a good place to cut

        let n = min(cutFrame * Self.frameSamples, buffer.count)
        guard n > 0 else { return false }
        let chunk = Array(buffer.prefix(n))

        // Re-lock to consume: the buffer only ever grows at the tail, so
        // dropping the first n samples is still exactly this chunk.
        lock.lock()
        switch source {
        case .you:
            micBuffer.removeFirst(min(n, micBuffer.count))
            micConsumed += Int64(n)
        case .them:
            systemBuffer.removeFirst(min(n, systemBuffer.count))
            systemConsumed += Int64(n)
        }
        lock.unlock()

        let start = TimeInterval(startSamples) / rate
        let end = start + TimeInterval(chunk.count) / rate

        var peak: Float = 0
        for s in chunk {
            let a = abs(s)
            if a > peak { peak = a }
        }
        // Loudest one-second window, NOT the whole-chunk average. A 20 s
        // utterance is mostly silence around the words; averaging over it
        // drags a real sentence under the gates and deletes it.
        let loudest = Self.loudestWindowRMS(energies: Array(energies.prefix(cutFrame)),
                                            windowFrames: Self.framesPerSecond)

        // Silence gate, both channels (ported: rms < 0.0015 && peak < 0.05).
        if loudest < Self.silenceRMS, peak < Self.silencePeak { return true }

        let paddedSpeaking = systemActivity.isSystemSpeaking(
            from: start - Self.vadTailSeconds, to: end + Self.vadTailSeconds)

        // System-dominant mic gate (ported): a quiet mic chunk while the far
        // side speaks is speaker bleed, not the user — skip it before whisper
        // ever sees it.
        //
        // Logged, because this is the one place audio is deleted before it
        // can become text: it leaves no segment, no holdback entry and no
        // tombstone, so an over-eager threshold here is invisible in the
        // transcript and undiagnosable after the spools are gone.
        if source == .you, loudest < Self.bleedRMS, peak < Self.bleedPeak, paddedSpeaking {
            Log.info(String(format: "MeetingTranscriber: dropped %.1f s of mic as far-side " +
                                    "bleed (loudest second %.4f < %.4f)",
                            end - start, loudest, Self.bleedRMS))
            return true
        }

        let prompt = Self.decodePrompt(for: source)
        let language = AppSettings.shared.language
        let vad = Paths.vadModelExists ? Paths.vadModel.path : nil
        let spans: [WhisperEngine.Segment]
        do {
            spans = try await engine.transcribeSegments(samples: chunk, language: language,
                                                        prompt: prompt, vadModelPath: vad,
                                                        options: .meeting)
        } catch {
            Log.error("MeetingTranscriber: \(source) chunk failed: \(error)")
            return true
        }

        // Risky = "might be far-side echo", which buys a 6 s holdback and
        // eligibility for retraction. Under utterance chunking a 20 s window
        // almost always overlaps SOME far-side speech, so `paddedSpeaking`
        // alone would flag every single mic chunk (it did: every mic segment
        // in the field transcript was risky). Loud, close-mic speech is the
        // user by definition — only quiet-and-overlapping stays suspect.
        let risky = source == .you
            && (start < Self.startupWarmupSeconds
                || (paddedSpeaking && loudest < Self.clearlyUserRMS))

        // One emission per whisper span, not per window (ADR 34): the spans
        // are real sentences with real times, so the transcript timeline
        // stops being a scheduler artefact — and one bad span no longer
        // takes a 24 s utterance down with it.
        for span in spans {
            // Per-channel scrub asymmetry: "You" is the user's words — a
            // false drop is silent data loss, so only scrubFinal. "Them" is
            // other people's audio where caption furniture is near-certain
            // hallucination — preview-junk aggression applies.
            let text: String
            switch source {
            case .you: text = HallucinationFilter.scrubFinal(span.text, prompt: prompt)
            case .them: text = HallucinationFilter.scrubMeetingSystem(span.text, prompt: prompt)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            onChunkTranscribed?(RawChunk(source: source, text: trimmed,
                                         start: start + span.start,
                                         end: min(end, start + span.end),
                                         risky: risky))
        }
        return true
    }

    /// Per-channel prompt asymmetry, mirroring the scrub asymmetry: the
    /// user's glossary helps decode the user, but injected into the far side
    /// it becomes hallucinated vocabulary in other people's speech.
    ///
    /// The far side gets NO prompt at all (ADR 34). whisper is asked to carry
    /// the initial prompt into every decode window, and on a low-information
    /// window it recites the prompt as speech — a real call came back with
    /// "there is a meeting conversation" four times, straight out of the old
    /// punctuation-steering string. Nothing to carry, nothing to recite; and
    /// a whole utterance punctuates itself without steering.
    nonisolated static func decodePrompt(for source: MeetingSegment.Source) -> String {
        source == .them ? "" : AppSettings.shared.whisperPrompt
    }

    // MARK: - Utterance cutting (pure — the eval surface)

    static let frameSamples = Int(MeetingTranscriber.frameSeconds * Double(WhisperEngine.sampleRate))
    static let framesPerSecond = Int(1.0 / MeetingTranscriber.frameSeconds)

    /// RMS per 20 ms frame. A trailing partial frame is included so the tail
    /// of the buffer is never invisible to the cut search.
    nonisolated static func frameEnergies(_ samples: [Float], frameSamples: Int) -> [Float] {
        guard frameSamples > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / frameSamples + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameSamples, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            out.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        return out
    }

    /// Loudest sliding `windowFrames` window, as RMS. Used instead of a
    /// whole-chunk average wherever a gate decides to DROP audio.
    nonisolated static func loudestWindowRMS(energies: [Float], windowFrames: Int) -> Float {
        guard !energies.isEmpty else { return 0 }
        let w = max(1, min(windowFrames, energies.count))
        // Mean of squares over the window (energies are already RMS values).
        var running: Float = 0
        for i in 0..<w { running += energies[i] * energies[i] }
        var best = running
        var i = w
        while i < energies.count {
            running += energies[i] * energies[i] - energies[i - w] * energies[i - w]
            if running > best { best = running }
            i += 1
        }
        return (best / Float(w)).squareRoot()
    }

    /// Where the next utterance should end, in FRAMES, or nil to keep
    /// buffering. The whole point of the rewrite: boundaries land in pauses,
    /// never mid-word.
    ///
    /// - `flushing` (the meeting stopped) takes whatever is there.
    /// - Below `minSeconds` nothing is cut: short windows are what produced
    ///   fragments and hallucinated filler.
    /// - Otherwise the first pause of `pauseSeconds` past the minimum wins,
    ///   cut mid-pause so both sides keep a little silence padding.
    /// - A talker who never pauses is force-cut at `maxSeconds`, on the
    ///   quietest frame in the preceding second so the damage is a syllable
    ///   at worst.
    nonisolated static func utteranceCut(energies: [Float], flushing: Bool,
                                         minSeconds: TimeInterval, maxSeconds: TimeInterval,
                                         pauseSeconds: TimeInterval, pauseRMS: Float) -> Int? {
        guard !energies.isEmpty else { return nil }
        let fps = Double(framesPerSecond)
        let minF = Int(minSeconds * fps)
        let maxF = Int(maxSeconds * fps)
        let pauseF = max(1, Int(pauseSeconds * fps))

        if energies.count < minF { return flushing ? energies.count : nil }

        let limit = min(energies.count, maxF)
        var runStart = -1
        for i in 0..<limit {
            if energies[i] < pauseRMS {
                if runStart < 0 { runStart = i }
                if i >= minF, i - runStart + 1 >= pauseF {
                    return max(minF, i - pauseF / 2)
                }
            } else {
                runStart = -1
            }
        }

        guard energies.count >= maxF || flushing else { return nil }
        // Forced cut: pick the quietest frame in the last second we can see.
        let from = max(minF, limit - framesPerSecond)
        guard from < limit else { return limit }
        var best = from
        var bestEnergy = Float.greatestFiniteMagnitude
        for j in from..<limit where energies[j] < bestEnergy {
            bestEnergy = energies[j]
            best = j
        }
        return best
    }
}
