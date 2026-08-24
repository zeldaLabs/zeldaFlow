import Foundation
import whisper

/// In-process whisper.cpp wrapper. One resident context (Metal, ~1.2 GB for
/// large-v3-turbo-q8_0); all inference serialized on a dedicated queue —
/// whisper contexts are not safe for concurrent whisper_full calls.
final class WhisperEngine {
    enum EngineError: LocalizedError {
        case modelNotFound(String)
        case loadFailed
        case notLoaded
        case inferenceFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let p): return "Whisper model not found at \(p)"
            case .loadFailed: return "Failed to load the Whisper model"
            case .notLoaded: return "Whisper engine not loaded yet"
            case .inferenceFailed(let c): return "Transcription failed (code \(c))"
            }
        }
    }

    static let sampleRate = 16_000

    /// One decoded span of audio. Dictation only ever wants the joined text;
    /// the meeting path wants the spans, because whisper's own segmentation
    /// is where real sentence boundaries come from (ADR 34).
    struct Segment {
        let text: String
        /// Seconds from the START of the samples handed to transcribe.
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Decode profile. `.dictation` is the shipped behavior, unchanged — one
    /// short utterance, bounded latency, no re-decodes. `.meeting` trades
    /// latency for correctness on long unattended audio (ADR 34).
    struct Options {
        /// Let whisper emit timestamped segments instead of one blob.
        /// Timestamp tokens also pace the decoder: without them an early EOT
        /// silently discards the rest of the window.
        var timestamps = false
        /// whisper's own self-correction: on a failed entropy / logprob /
        /// compression-ratio check it re-decodes the window at a higher
        /// temperature. Disabled for dictation (latency), essential for
        /// meetings — with it off, a repetition loop like "I was going to go
        /// to the balance sheet and I was going to go to the balance sheet"
        /// is accepted and stored verbatim.
        var temperatureFallback = false
        /// Drop a decoded span whose no-speech probability exceeds this.
        /// With one span per window this is an all-or-nothing kill switch,
        /// which is why the meeting path both raises it AND emits spans.
        var noSpeechDrop: Float = 0.75

        static let dictation = Options()
        static let meeting = Options(timestamps: true, temperatureFallback: true,
                                     noSpeechDrop: 0.9)
    }

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "zeldaflow.stt", qos: .userInitiated)
    private(set) var isLoaded = false

    /// The C log callback below can't capture state; these live here instead.
    /// whisper derives the Core ML path as "<model>.bin" → "<model>-encoder
    /// .mlmodelc"; loadLocked stashes it so the callback can tell "not
    /// installed" (fine, expected) from "installed but failed to load"
    /// (a corrupt/partial install worth surfacing).
    private static var coreMLFallbackNoted = false
    private static var expectedCoreMLPath: String?

    init() {
        // Route whisper/ggml logs away from stderr; keep errors in our log.
        whisper_log_set({ level, text, _ in
            guard let text, level == GGML_LOG_LEVEL_ERROR else { return }
            let msg = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }
            // The Core ML ANE encoder is an optional install; whisper reports
            // its absence at error level on every load and then falls back to
            // Metal. Note it once — as a hint when absent, loudly when a
            // present encoder fails to load.
            if msg.contains("failed to load Core ML model") {
                if !WhisperEngine.coreMLFallbackNoted {
                    WhisperEngine.coreMLFallbackNoted = true
                    if let path = WhisperEngine.expectedCoreMLPath,
                       FileManager.default.fileExists(atPath: path) {
                        Log.error("whisper: Core ML encoder present at \(path) but failed " +
                                  "to load — possibly a partial install; delete it and " +
                                  "re-run scripts/setup.sh (using Metal meanwhile)")
                    } else {
                        Log.info("whisper: Core ML encoder not installed — encoder runs on " +
                                 "Metal (scripts/setup.sh downloads the Neural Engine version)")
                    }
                }
                return
            }
            Log.error("whisper: \(msg)")
        }, nil)
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    /// Load the model and run a short warm-up so the first real dictation
    /// doesn't pay Metal graph compilation (~1-3 s on first inference).
    func loadAndWarmUp(modelPath: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.loadLocked(modelPath: modelPath)
                    // 1 s of quiet noise, VAD off, forces encoder+decoder warm-up.
                    var noise = [Float](repeating: 0, count: WhisperEngine.sampleRate)
                    for i in 0..<noise.count {
                        noise[i] = Float.random(in: -0.001...0.001)
                    }
                    _ = try? self.transcribeLocked(samples: noise, language: "en",
                                                   prompt: nil, vadModelPath: nil)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func transcribe(samples: [Float], language: String, prompt: String?,
                    vadModelPath: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let text = try self.transcribeLocked(samples: samples, language: language,
                                                         prompt: prompt, vadModelPath: vadModelPath)
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Timestamped spans — the meeting path's entry point.
    func transcribeSegments(samples: [Float], language: String, prompt: String?,
                            vadModelPath: String?,
                            options: Options) async throws -> [Segment] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let segments = try self.transcribeLocked(
                        samples: samples, language: language, prompt: prompt,
                        vadModelPath: vadModelPath, options: options)
                    cont.resume(returning: segments)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-confined implementation

    private func loadLocked(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw EngineError.modelNotFound(modelPath)
        }
        let base = modelPath.hasSuffix(".bin") ? String(modelPath.dropLast(4)) : modelPath
        WhisperEngine.expectedCoreMLPath = base + "-encoder.mlmodelc"
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw EngineError.loadFailed
        }
        ctx = c
        isLoaded = true
        Log.info("WhisperEngine: model loaded (\(modelPath))")
    }

    /// String form — the dictation path, byte-for-byte the shipped behavior.
    private func transcribeLocked(samples: [Float], language: String, prompt: String?,
                                  vadModelPath: String?) throws -> String {
        try transcribeLocked(samples: samples, language: language, prompt: prompt,
                             vadModelPath: vadModelPath, options: .dictation)
            .map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeLocked(samples: [Float], language: String, prompt: String?,
                                  vadModelPath: String?,
                                  options: Options) throws -> [Segment] {
        guard let ctx else { throw EngineError.notLoaded }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        params.no_context = true
        params.no_timestamps = !options.timestamps
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true          // suppress non-speech tokens
        params.temperature = 0
        // Dictation: no fallback re-decodes, bounded latency. Meetings: the
        // ladder is whisper's only defence against repetition loops and
        // truncated decodes, and an unattended recording can afford it.
        params.temperature_inc = options.temperatureFallback ? 0.2 : 0
        if options.temperatureFallback {
            params.entropy_thold = 2.4
            params.logprob_thold = -1.0
        }
        params.no_speech_thold = 0.6
        params.detect_language = false
        // Transcribe in the spoken language/script — NEVER translate to
        // English (Spanish in, Spanish out).
        params.translate = false

        // C strings must stay alive for the duration of whisper_full.
        let langC = strdup(language)
        defer { free(langC) }
        params.language = UnsafePointer(langC)

        var promptC: UnsafeMutablePointer<CChar>?
        if let prompt, !prompt.isEmpty {
            promptC = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptC)
            params.carry_initial_prompt = true
        }
        defer { if let promptC { free(promptC) } }

        // Silero VAD pre-filter: the decoder never sees silence, which is the
        // single biggest fix for "Thank you." style hallucinations.
        var vadC: UnsafeMutablePointer<CChar>?
        if let vadModelPath, FileManager.default.fileExists(atPath: vadModelPath) {
            vadC = strdup(vadModelPath)
            params.vad = true
            params.vad_model_path = UnsafePointer(vadC)
            params.vad_params = whisper_vad_default_params()
        }
        defer { if let vadC { free(vadC) } }

        let status = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard status == 0 else { throw EngineError.inferenceFailed(status) }

        let duration = TimeInterval(samples.count) / TimeInterval(Self.sampleRate)
        var out: [Segment] = []
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            // Drop spans the model itself thinks are non-speech.
            if whisper_full_get_segment_no_speech_prob(ctx, i) > options.noSpeechDrop { continue }
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: raw)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // whisper reports centiseconds; with no_timestamps they are 0.
            // Clamp into the window: VAD remapping and the odd runaway
            // timestamp must never produce a span outside the audio we sent.
            var start = TimeInterval(whisper_full_get_segment_t0(ctx, i)) / 100
            var end = TimeInterval(whisper_full_get_segment_t1(ctx, i)) / 100
            if !options.timestamps || end <= start || start < 0 || start > duration {
                start = 0
                end = duration
            }
            out.append(Segment(text: text, start: max(0, start), end: min(duration, end)))
        }
        return out
    }
}
