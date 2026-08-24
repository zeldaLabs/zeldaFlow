import Foundation
import AVFoundation

/// End-to-end pipeline check without a microphone: WAV file → WhisperEngine
/// (with VAD) → optional Gemma cleanup → stdout. Returns a process exit code.
enum SelfTest {
    static func run(wavPath: String?) -> Int32 {
        print("zeldaFlow selftest")
        print("  whisper model: \(Paths.whisperModel.path) " +
              "(\(Paths.whisperModelExists ? "found" : "MISSING"))")
        print("  vad model:     \(Paths.vadModel.path) " +
              "(\(Paths.vadModelExists ? "found" : "missing — optional"))")
        print("  cleanup model: \(Paths.cleanupModel.path) " +
              "(\(Paths.cleanupModelExists ? "found" : "missing — optional"))")
        guard Paths.whisperModelExists else {
            print("FAIL: whisper model missing")
            return 1
        }

        let engine = WhisperEngine()
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let t0 = Date()
                try await engine.loadAndWarmUp(modelPath: Paths.whisperModel.path)
                print("  model load+warmup: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

                guard let wavPath else {
                    print("OK (no wav given — engine loads and warms up)")
                    sem.signal()
                    return
                }

                let samples = try loadAudio(path: wavPath)
                print("  audio: \(samples.count) samples " +
                      "(\(String(format: "%.2f", Double(samples.count) / 16000)) s)")

                let t1 = Date()
                let prompt = AppSettings.shared.whisperPrompt
                let raw = try await engine.transcribe(
                    samples: samples,
                    language: AppSettings.shared.language,
                    prompt: prompt,
                    vadModelPath: Paths.vadModelExists ? Paths.vadModel.path : nil)
                print("  transcribe: \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                print("RAW: \(raw)")

                // Production applies the hallucination scrubber before the
                // text ever reaches the user; the harness must too, or it
                // reports on a pipeline nobody actually runs.
                let filtered = HallucinationFilter.scrubFinal(raw, prompt: prompt)
                if filtered != raw { print("FILTERED: \(filtered)") }

                if filtered.isEmpty {
                    print("FAIL: empty transcript")
                    exitCode = 2
                    sem.signal()
                    return
                }

                // Cleanup via llama-server if one is reachable.
                let cleanup = CleanupService(port: AppSettings.shared.llamaPort)
                cleanup.start()
                for _ in 0..<180 {
                    if cleanup.statusSnapshot == .ready { break }
                    if case .failed = cleanup.statusSnapshot { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if cleanup.statusSnapshot == .ready {
                    let t2 = Date()
                    if let cleaned = await cleanup.cleanup(filtered, dictionary: AppSettings.shared.dictionaryWords) {
                        print("  cleanup: \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
                        print("CLEANED: \(cleaned)")
                    } else {
                        print("  cleanup: fell back to raw")
                    }
                } else {
                    print("  cleanup: unavailable (\(cleanup.statusSnapshot)) — skipped")
                }
                cleanup.stop()
                print("OK")
            } catch {
                print("FAIL: \(error)")
                exitCode = 3
            }
            sem.signal()
        }

        // The async work uses no main-actor UI; block main until done.
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return exitCode
    }

    /// Load any audio file AVFoundation can read, converted to 16 kHz mono Float32.
    static func loadAudio(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "zeldaFlow", code: 10)
        }
        try file.read(into: inBuf)

        if file.processingFormat == target, let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "zeldaFlow", code: 11)
        }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "zeldaFlow", code: 12)
        }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let ch = outBuf.floatChannelData else {
            throw err ?? NSError(domain: "zeldaFlow", code: 13)
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
