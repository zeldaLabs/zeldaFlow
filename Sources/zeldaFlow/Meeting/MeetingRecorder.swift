import Foundation
import AVFoundation

/// Owns the two capture streams of one meeting: the mic ("You") through its
/// own AudioRecorder — inheriting every ADR 0026 invariant (never open a
/// Bluetooth mic, fail-closed, verify-after-start, minimum ducking) — and
/// system audio ("Them") through SystemAudioTap. Not @MainActor: audio-rate
/// work stays off the main thread; MeetingCenter (main) drives lifecycle.
///
/// Start ordering is fail-closed on the mic and degrade-on-tap: a notetaker
/// without "You" is broken, so a mic failure aborts the meeting; a tap
/// failure degrades to mic-only (half a transcript beats none — and this is
/// not ADR 0026's fail-closed case, which is about refusing an *unsafe
/// device*, not a missing second stream).
final class MeetingRecorder {

    struct CaptureInfo {
        let id: UUID
        let startedAt: Date
        let folder: URL
        let trigger: MeetingTrigger
    }

    struct CaptureResult {
        let durationSeconds: Double
        let health: StreamHealth
    }

    enum StreamHealth: Equatable {
        case dual
        case micOnly(String)   // tap error description

        static func == (a: StreamHealth, b: StreamHealth) -> Bool {
            switch (a, b) {
            case (.dual, .dual): return true
            case (.micOnly, .micOnly): return true
            default: return false
            }
        }
    }

    enum RecorderError: Error, LocalizedError {
        case alreadyCapturing
        case diskFull
        var errorDescription: String? {
            switch self {
            case .alreadyCapturing: return "a meeting is already being recorded"
            case .diskFull: return "not enough free disk space to record a meeting"
            }
        }
    }

    /// A 4 h dual capture spools ~920 MB of Int16 WAV; starting (or
    /// continuing) under this floor risks wedging the user's disk.
    static let minimumFreeBytes: Int64 = 500 * 1024 * 1024

    weak var consumer: MeetingAudioConsumer?
    /// Main queue. Fired when the tap dies mid-meeting (degrade to mic-only).
    var onHealthChange: ((StreamHealth) -> Void)?
    /// Main queue, 0...1 mic RMS ~every 50-100 ms — the pill chip's level bars.
    var levelHandler: ((Float) -> Void)?
    /// Main queue. The recorder asks MeetingCenter to stop the meeting — it
    /// never stops itself, so lifecycle stays in one place.
    var onShouldStop: ((MeetingStopReason) -> Void)?

    private let micRecorder = AudioRecorder()
    private let tap = SystemAudioTap()
    /// Both capture callbacks copy-and-hop here; disk writes and consumer
    /// calls happen here. Audio threads never touch disk.
    private let queue = DispatchQueue(label: "zeldaflow.meeting.pipeline", qos: .userInitiated)
    private let lock = NSLock()

    private var info: CaptureInfo?
    private var health: StreamHealth = .dual
    private var micSpool: WavSpool?
    private var systemSpool: WavSpool?
    private var activeLoan: MicLoan?
    /// Meeting stopped while a dictation loan was live: the tap is down but
    /// the mic engine keeps running until the loan ends.
    private var micStopDeferred = false
    private var lastDiskCheckOffset: TimeInterval = 0

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return info != nil
    }

    var currentInfo: CaptureInfo? {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    // MARK: - Lifecycle

    /// Synchronous; call off main (MeetingCenter hops to a utility queue).
    func start(id: UUID, trigger: MeetingTrigger, folder: URL) throws -> CaptureInfo {
        lock.lock()
        guard info == nil else { lock.unlock(); throw RecorderError.alreadyCapturing }
        lock.unlock()

        guard Self.freeBytes(at: folder) > Self.minimumFreeBytes else {
            throw RecorderError.diskFull
        }

        // Meetings default to voice-processing AEC regardless of the dictation
        // setting: the far side plays through the speakers and would otherwise
        // land in the "You" channel wholesale. AudioRecorder's own gates still
        // skip VPIO on Bluetooth output (nothing in the room to cancel) and
        // when the default input is Bluetooth (VPIO refuses overrides, -10875).
        micRecorder.voiceProcessing = true
        micRecorder.preferBuiltInMic = AppSettings.shared.preferBuiltInMic

        let mic = WavSpool(url: folder.appendingPathComponent("mic.wav"))
        let system = WavSpool(url: folder.appendingPathComponent("system.wav"))

        micRecorder.levelHandler = { [weak self] level in self?.levelHandler?(level) }
        micRecorder.streamHandler = { [weak self] buffer, frameOffset in
            guard let self else { return }
            let copy = Array(buffer)
            let offset = TimeInterval(frameOffset) / TimeInterval(WhisperEngine.sampleRate)
            self.queue.async { self.handleMic(copy, at: offset) }
        }
        micRecorder.onConfigurationChange = { [weak self] in
            // Mid-meeting device swap kills the engine graph. Unlike a 30 s
            // dictation, a meeting should survive AirPods arriving: restart
            // the mic engine in place; the frame counter continues, so a
            // ~100 ms gap is the whole cost.
            guard let self, self.isCapturing else { return }
            self.queue.async { self.restartMicAfterTopologyChange() }
        }

        // Mic first — fail-closed.
        try micRecorder.start()

        let captureInfo = CaptureInfo(id: id, startedAt: Date(), folder: folder, trigger: trigger)
        lock.lock()
        info = captureInfo
        health = .dual
        micSpool = mic
        systemSpool = system
        micStopDeferred = false
        lastDiskCheckOffset = 0
        lock.unlock()

        // Tap second — degrade on failure, with one retry (transient
        // aggregate-creation failures were observed to clear within 1 s).
        tap.chunkHandler = { [weak self] samples, frameOffset in
            guard let self else { return }
            let offset = TimeInterval(frameOffset) / TimeInterval(WhisperEngine.sampleRate)
            self.queue.async { self.handleSystem(samples, at: offset) }
        }
        tap.onError = { [weak self] error in
            guard let self else { return }
            Log.error("MeetingRecorder: system tap failed mid-meeting: \(error)")
            self.degradeToMicOnly("\(error)")
        }
        startTapWithRetry()
        return captureInfo
    }

    private func startTapWithRetry() {
        queue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            do {
                try self.tap.start()
                Permissions.setSystemAudio(.granted)
            } catch {
                Log.error("MeetingRecorder: tap start failed (\(error)) — retrying in 1 s")
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.isCapturing else { return }
                    do {
                        try self.tap.start()
                        Permissions.setSystemAudio(.granted)
                    } catch {
                        self.degradeToMicOnly("\(error)")
                    }
                }
            }
        }
    }

    private func degradeToMicOnly(_ reason: String) {
        lock.lock()
        guard info != nil, health == .dual else { lock.unlock(); return }
        health = .micOnly(reason)
        lock.unlock()
        DispatchQueue.main.async { self.onHealthChange?(.micOnly(reason)) }
    }

    private func restartMicAfterTopologyChange() {
        guard isCapturing else { return }
        _ = micRecorder.stop()
        do {
            try micRecorder.start()
            Log.info("MeetingRecorder: mic engine restarted after device change")
        } catch {
            // No safe mic left (ADR 0026 fail-closed). The meeting can't hear
            // the user any more — end it rather than record half a call.
            Log.error("MeetingRecorder: mic restart failed (\(error)) — stopping meeting")
            DispatchQueue.main.async { self.onShouldStop?(.micIdle) }
        }
    }

    /// Synchronous; call off main. Finalizes the WAV spools. If a dictation
    /// loan is live, the mic engine keeps running until the loan ends.
    func stop(reason: MeetingStopReason) -> CaptureResult {
        lock.lock()
        guard let current = info else {
            lock.unlock()
            return CaptureResult(durationSeconds: 0, health: .dual)
        }
        info = nil
        let finalHealth = health
        let mic = micSpool
        let system = systemSpool
        micSpool = nil
        systemSpool = nil
        let loanLive = activeLoan != nil
        micStopDeferred = loanLive
        lock.unlock()

        tap.stop()
        if !loanLive {
            micRecorder.stopAndDiscard()
        }
        let duration = Date().timeIntervalSince(current.startedAt)

        // Flush queued chunks before closing the spools, so the WAVs contain
        // everything the consumer saw.
        queue.sync {
            mic?.finalize()
            system?.finalize()
        }
        Log.info("MeetingRecorder: stopped (\(reason.rawValue)) after " +
                 "\(Int(duration)) s, health \(finalHealth == .dual ? "dual" : "mic-only")")
        return CaptureResult(durationSeconds: duration, health: finalHealth)
    }

    // MARK: - Chunk paths (on `queue`)

    private func handleMic(_ samples: [Float], at offset: TimeInterval) {
        lock.lock()
        let spool = micSpool
        let loan = activeLoan
        lock.unlock()
        spool?.append(samples)
        loan?.append(samples)
        consumer?.micChunk(samples, at: offset)
        checkDisk(at: offset)
    }

    private func handleSystem(_ samples: [Float], at offset: TimeInterval) {
        lock.lock()
        let spool = systemSpool
        lock.unlock()
        spool?.append(samples)
        consumer?.systemChunk(samples, at: offset)
    }

    private func checkDisk(at offset: TimeInterval) {
        // Every ~60 s of audio, not every chunk — statfs is cheap but not free.
        guard offset - lastDiskCheckOffset >= 60 else { return }
        lastDiskCheckOffset = offset
        guard let folder = currentInfo?.folder,
              Self.freeBytes(at: folder) <= Self.minimumFreeBytes else { return }
        Log.error("MeetingRecorder: free space under \(Self.minimumFreeBytes / 1_048_576) MB — stopping")
        DispatchQueue.main.async { self.onShouldStop?(.diskFull) }
    }

    private static func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - Mic loan (dictation mid-meeting)

    /// Dictation borrows the meeting's already-converted, already-AEC'd mic
    /// stream instead of opening a second AVAudioEngine on the same device —
    /// two engines mean either double-VPIO (undefined interference) or an
    /// un-cancelled dictation stream. Side effect the user wants anyway:
    /// dictation starts instantly, because the engine is already hot.
    func borrowMicForDictation() -> MicLoan? {
        lock.lock(); defer { lock.unlock() }
        guard info != nil, activeLoan == nil else { return nil }
        let loan = MicLoan { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.activeLoan = nil
            let deferredStop = self.micStopDeferred
            self.micStopDeferred = false
            self.lock.unlock()
            // The meeting ended while dictation was still running off its
            // engine — release the mic now that the loan is done.
            if deferredStop { self.micRecorder.stopAndDiscard() }
        }
        activeLoan = loan
        return loan
    }
}

/// A dictation session running off the meeting's mic stream. Accumulates
/// 16 kHz Float32 exactly as AudioRecorder does, from the same tap point, so
/// AppState's finish path (snapshot / live preview / final transcription)
/// works unchanged.
final class MicLoan {
    private var samples: [Float] = []
    private let lock = NSLock()
    private var ended = false
    private let onEnd: () -> Void

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    /// Called by MeetingRecorder on the pipeline queue.
    func append(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        samples.append(contentsOf: chunk)
    }

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return !ended
    }

    var currentDuration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Double(WhisperEngine.sampleRate)
    }

    func snapshot(lastSeconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let maxCount = Int(lastSeconds * Double(WhisperEngine.sampleRate))
        if samples.count <= maxCount { return samples }
        return Array(samples.suffix(maxCount))
    }

    func end() -> [Float] {
        lock.lock()
        let out = samples
        let wasEnded = ended
        ended = true
        samples = []
        lock.unlock()
        if !wasEnded { onEnd() }
        return out
    }

    func endAndDiscard() {
        _ = end()
    }
}

/// Append-only 16 kHz mono Int16 WAV writer. The header is written with
/// placeholder sizes and patched on finalize; a crash leaves a repairable
/// file (the bootstrap sweep calls repairHeader, deriving sizes from the
/// file length). Int16, not Float32: 115 MB/hour/stream instead of 230.
final class WavSpool {
    private let url: URL
    private var handle: FileHandle?
    private var dataBytes: UInt32 = 0

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        guard let handle else {
            Log.error("WavSpool: cannot open \(url.lastPathComponent) for writing")
            return
        }
        handle.write(Self.header(dataBytes: 0))
    }

    /// Called on the meeting pipeline queue only.
    func append(_ samples: [Float]) {
        guard let handle else { return }
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var i = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &i) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        dataBytes &+= UInt32(data.count)
    }

    func finalize() {
        guard let handle else { return }
        try? handle.seek(toOffset: 0)
        handle.write(Self.header(dataBytes: dataBytes))
        try? handle.close()
        self.handle = nil
    }

    /// Patch the header of a crash-orphaned spool from its on-disk length.
    static func repairHeader(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > 44,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.seek(toOffset: 0)
        handle.write(header(dataBytes: UInt32(size - 44)))
        try? handle.close()
        Log.info("WavSpool: repaired header of \(url.lastPathComponent) (\(size) bytes)")
    }

    private static func header(dataBytes: UInt32) -> Data {
        let sampleRate: UInt32 = UInt32(WhisperEngine.sampleRate)
        let byteRate: UInt32 = sampleRate * 2
        var d = Data()
        func put(_ s: String) { d.append(contentsOf: s.utf8) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put("RIFF"); put32(36 &+ dataBytes); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(sampleRate); put32(byteRate); put16(2); put16(16)
        put("data"); put32(dataBytes)
        return d
    }
}
