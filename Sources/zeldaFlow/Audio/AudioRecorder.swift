import Foundation
import AVFoundation
import CoreAudio

/// Captures microphone audio via AVAudioEngine, converting on the fly to
/// 16 kHz mono Float32 (whisper's input format). Emits RMS levels for the
/// waveform UI. The engine object stays allocated between sessions so
/// start() is cheap.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(WhisperEngine.sampleRate),
                                             channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private var peakLevel: Float = 0
    private let lock = NSLock()
    /// Bringing the graph up and tearing it down both cost hundreds of
    /// milliseconds (measured: 610 ms to build the voice-processing unit,
    /// 218 ms for `engine.start()`). None of that may happen on the caller's
    /// thread — the caller is the hotkey path, and a key press that waits on
    /// CoreAudio is a key press the user experiences as dropped. Serial, so a
    /// stop always lands behind the start it ends, never inside it.
    private let engineQueue = DispatchQueue(label: "com.zeldalabs.zeldaflow.audio-engine",
                                            qos: .userInitiated)
    private var _isRecording = false
    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
    }
    /// Set when the audio topology changes while idle (dock plugged in, a
    /// monitor's USB audio appears, default mic switched): the prepared
    /// graph may reference a device that's gone. The next start() rebuilds
    /// it instead of capturing silence from a dead graph.
    private var needsReset = false

    /// Called on the main queue with a 0...1 level roughly every 50-100 ms.
    var levelHandler: ((Float) -> Void)?
    /// Streaming mode (meeting capture): when set, process() forwards each
    /// converted 16 kHz chunk here INSTEAD of appending to `samples` — an
    /// hour of accumulated Float32 is 230 MB per stream, and a meeting must
    /// not hold it in memory. Called on the render path, post-conversion; the
    /// pointer is valid only for the duration of the call, so the consumer
    /// copies and dispatches immediately. `frameOffset` counts converted
    /// frames since start() — sample counts can't drift, timers can.
    var streamHandler: ((_ samples: UnsafeBufferPointer<Float>, _ frameOffset: Int64) -> Void)?
    private var streamedFrames: Int64 = 0
    /// Called on the main queue when the input device changes mid-capture
    /// (AirPods connect, interface unplugged): the engine graph is dead.
    var onConfigurationChange: (() -> Void)?
    /// Apple voice processing (echo cancellation): subtracts the Mac's own
    /// speaker output from the mic signal, so music playing while you dictate
    /// doesn't reach Whisper. Set before start(); failure to enable is
    /// non-fatal — plain capture continues.
    var voiceProcessing = false
    /// Engine (re)start moment: the VPIO graph fires a spurious
    /// configuration-change right after its first start, which must not
    /// cancel the session (a real device swap that fast is vanishingly rare).
    private var startedAt = Date.distantPast
    /// Pending teardown of the voice-processing unit — see releaseVoiceProcessing().
    private var voiceProcessingRelease: DispatchWorkItem?
    /// When the default input is a Bluetooth headset, capture from the Mac's
    /// built-in mic instead (without touching the system default).
    ///
    /// Opening a Bluetooth mic drags the whole headset out of its high-quality
    /// playback profile into the hands-free one: music pauses, comes back mono
    /// and quiet, then flips again when the mic closes — once per dictation.
    /// There is no way to open a Bluetooth mic without that; the seamless fix
    /// is to not open it. The built-in array is also simply a better mic than
    /// a 24 kHz headset ever is, so Whisper wins twice.
    var preferBuiltInMic = true
    /// How long the voice-processing unit stays warm after a recording stops.
    /// Injectable so the eval doesn't have to wait two minutes.
    var idleReleaseDelay: TimeInterval = 120

    init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let recording = self._isRecording
            let sinceStart = Date().timeIntervalSince(self.startedAt)
            if !recording { self.needsReset = true }
            self.lock.unlock()

            guard recording else { return }
            // The VPIO graph fires a spurious config change right after
            // start; a real device swap kills the engine. Inside the
            // grace window, swallow only while the engine is still alive.
            if sinceStart <= 1.0, self.engine.isRunning { return }
            self.onConfigurationChange?()
        }
    }

    /// Bring the microphone up without blocking the caller. `completion` runs
    /// on the main queue with the failure, if any.
    ///
    /// This is the hotkey path's entry point: the press has to be answered in
    /// microseconds, and a cold start is ~850 ms of CoreAudio work.
    func start(completion: @escaping @Sendable (Error?) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            do { try self.startOnQueue() } catch { failure = error }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// Synchronous start, for evals that want the error and the timing inline.
    func start() throws {
        try engineQueue.sync { try startOnQueue() }
    }

    private func startOnQueue() throws {
        guard !isRecording else { return }
        lock.lock()
        // Recording again before the idle teardown fired — keep the warm
        // voice-processing graph and skip rebuilding it.
        voiceProcessingRelease?.cancel()
        voiceProcessingRelease = nil
        let mustReset = needsReset
        needsReset = false
        samples.removeAll(keepingCapacity: true)
        peakLevel = 0
        streamedFrames = 0
        lock.unlock()
        if mustReset {
            engine.reset()
            Log.info("AudioRecorder: engine reset after idle-time audio device change")
        }

        let input = engine.inputNode

        // Echo cancellation exists to keep the Mac's speakers out of the mic.
        // With output routed to Bluetooth headphones there is no speaker sound
        // in the room to cancel — and engaging the voice-processing unit is
        // exactly what makes dictation audible (voice mode, ducking, profile
        // flips). So on headphones it is skipped outright: the seamless path
        // is the one where nothing about the audio system changes at all.
        let outputIsBluetoothHeadphones = Self.defaultOutputDeviceID().map(Self.isBluetooth)
            ?? false
        let inputIsBluetooth = Self.defaultInputDeviceID().map(Self.isBluetooth) ?? false
        // The voice-processing unit refuses device overrides (-10875), so it
        // can only capture the system default. When that default is a
        // Bluetooth headset, VPIO would open it — the one thing this recorder
        // must never do — so the plain, steerable path is used instead.
        let wantVoiceProcessing = voiceProcessing && !outputIsBluetoothHeadphones
            && !(preferBuiltInMic && inputIsBluetooth)
        if voiceProcessing, outputIsBluetoothHeadphones, !input.isVoiceProcessingEnabled {
            Log.info("AudioRecorder: output is Bluetooth headphones — no speaker bleed " +
                     "to cancel, leaving the audio system untouched")
        }
        if voiceProcessing, !outputIsBluetoothHeadphones, preferBuiltInMic, inputIsBluetooth,
           input.isVoiceProcessingEnabled {
            Log.info("AudioRecorder: default input is a Bluetooth headset — skipping " +
                     "voice processing so capture can be steered off it")
        }
        if input.isVoiceProcessingEnabled != wantVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(wantVoiceProcessing)
            } catch {
                Log.error("AudioRecorder: voice processing \(wantVoiceProcessing) failed: \(error)")
            }
        }
        // The voice-processing unit ducks all other system audio by default —
        // music dips the moment dictation starts. Echo cancellation doesn't
        // need the duck: the AEC subtracts speaker output from the mic signal
        // regardless of how loud it is. Minimum ducking keeps whatever is
        // playing audible while the unit does its real job.
        if input.isVoiceProcessingEnabled {
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        // Re-resolved every start: the default device can have changed while
        // idle. Only the plain capture unit accepts a device override — the
        // voice-processing unit refuses to initialise against an input-only
        // device (-10875) — but the plain unit is exactly the path Bluetooth
        // headphone users are on, so the case that matters is covered.
        if input.isVoiceProcessingEnabled {
            capturedDeviceName = Self.defaultInputDeviceName()
        } else {
            capturedDeviceName = try applyPreferredInputDevice(to: input)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "zeldaFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input available"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        // The VPIO unit exposes a multichannel stream (9 ch observed) whose
        // default down-mix to mono is *silence* — map the real mic (ch 0)
        // explicitly whenever the input isn't already mono.
        if inputFormat.channelCount > 1 {
            converter?.channelMap = [0]
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Leave no orphaned tap behind — a second installTap would crash.
            input.removeTap(onBus: 0)
            throw error
        }
        // The steer is verified, not trusted: prepare()/start() can rebuild
        // the I/O unit and silently revert it to the system default. If that
        // default is the Bluetooth headset, the rule outranks the session.
        if preferBuiltInMic, inputIsBluetooth, !input.isVoiceProcessingEnabled,
           let unit = input.audioUnit {
            var actual = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &actual, &size) == noErr,
               Self.isBluetooth(actual) {
                input.removeTap(onBus: 0)
                engine.stop()
                throw NSError(domain: "zeldaFlow", code: 3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "capture landed on the Bluetooth headset after start — " +
                        "refusing to record from it"])
            }
        }
        lock.lock()
        startedAt = Date()
        _isRecording = true
        lock.unlock()
        Log.info("AudioRecorder: capturing \"\(capturedDeviceName)\" " +
                 "(\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch)")
    }

    /// The device this session is actually capturing from — the override
    /// target when one was applied, else the system default.
    private(set) var capturedDeviceName = "unknown"

    /// Steer the engine's input unit away from a Bluetooth default input.
    /// Engine-local: the system default is never modified, so every other app
    /// still sees the device the user chose. Returns the name of whatever
    /// will be captured.
    ///
    /// Fail-closed: when the default input is Bluetooth and no safe device
    /// can be steered to, this throws rather than letting capture fall back
    /// to the headset. A thrown mic error is a visible, fixable event; the
    /// old best-effort fallback opened the headset and captured 0.00 s,
    /// silently, on every attempt (observed 2026-08-04 when a wedged
    /// coreaudiod answered -10851 to every steer).
    private func applyPreferredInputDevice(to input: AVAudioInputNode) throws -> String {
        let systemDefault = Self.defaultInputDeviceName()
        guard preferBuiltInMic,
              let defaultID = Self.defaultInputDeviceID(),
              Self.isBluetooth(defaultID) else { return systemDefault }
        guard let unit = input.audioUnit else {
            throw Self.noSafeMicError(systemDefault, detail: "audio unit unavailable")
        }
        // Candidates re-enumerated fresh on every attempt: device IDs are
        // invalidated wholesale when coreaudiod restarts or the topology
        // churns, so nothing cached survives contact with this code path.
        var candidates: [AudioDeviceID] = []
        if let builtIn = Self.builtInInputDeviceID() { candidates.append(builtIn) }
        for dev in Self.wiredInputDeviceIDs() where !candidates.contains(dev) {
            candidates.append(dev)
        }
        var lastErr: OSStatus = noErr
        for candidate in candidates where candidate != defaultID {
            var target = candidate
            let err = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &target, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err == noErr {
                let name = Self.deviceName(candidate)
                Log.info("AudioRecorder: default input \"\(systemDefault)\" is Bluetooth — " +
                         "capturing from \"\(name)\" so the headset stays in " +
                         "high-quality audio")
                return name
            }
            lastErr = err
            Log.error("AudioRecorder: couldn't steer capture to " +
                      "\"\(Self.deviceName(candidate))\" (\(err))")
        }
        throw Self.noSafeMicError(systemDefault, detail: "device steering failed (\(lastErr))")
    }

    private static func noSafeMicError(_ headsetName: String, detail: String) -> NSError {
        NSError(domain: "zeldaFlow", code: 2, userInfo: [
            NSLocalizedDescriptionKey:
                "no microphone besides the Bluetooth headset \"\(headsetName)\" could be " +
                "opened (\(detail)) — not opening it. If this persists, restart the " +
                "Mac's audio (sudo killall coreaudiod) or reboot."])
    }

    /// Whether the voice-processing unit is currently in the graph — i.e.
    /// whether the system is still in voice mode because of us.
    var voiceProcessingActive: Bool { engine.inputNode.isVoiceProcessingEnabled }

    /// Whether other-audio ducking is configured to the minimum, so music
    /// keeps playing while the user dictates. Always true where the knob
    /// doesn't exist (pre-14 has no per-app ducking control to misconfigure).
    var duckingMinimised: Bool {
        guard engine.inputNode.isVoiceProcessingEnabled else { return false }
        if #available(macOS 14.0, *) {
            let cfg = engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration
            return !cfg.enableAdvancedDucking.boolValue && cfg.duckingLevel == .min
        }
        return true
    }

    /// Give the microphone back to the rest of the system.
    ///
    /// Apple's voice-processing unit doesn't just filter our input: while it
    /// exists, macOS runs the whole audio stack in voice mode. Output gets
    /// ducked, and Bluetooth headphones drop to the hands-free profile — mono
    /// and much quieter. Stopping the engine is not enough, because the unit
    /// stays in the graph; it has to be switched off explicitly.
    ///
    /// Deferred rather than immediate: tearing the unit down and rebuilding it
    /// costs real start-up latency (measured 1409 ms cold vs 28 ms warm), and
    /// the mic isn't open during that spin-up — a cold start eats the first
    /// word. The first cut of this released after 4 s, which made nearly every
    /// dictation pay the cold start AND cycle the system in and out of voice
    /// mode audibly. Two minutes keeps a working session entirely on the warm
    /// path; with ducking at minimum and Bluetooth mics never opened, the unit
    /// lingering that long has no audible footprint left.
    private func releaseVoiceProcessing() {
        lock.lock()
        voiceProcessingRelease?.cancel()
        lock.unlock()
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording,
                  self.engine.inputNode.isVoiceProcessingEnabled else { return }
            do {
                try self.engine.inputNode.setVoiceProcessingEnabled(false)
                Log.info("AudioRecorder: released voice processing — audio back to normal")
            } catch {
                Log.error("AudioRecorder: couldn't release voice processing: \(error)")
            }
        }
        lock.lock()
        voiceProcessingRelease = work
        lock.unlock()
        // On the engine queue, not main: dropping the unit costs as much as
        // building it, and it must not land in the middle of a start.
        engineQueue.asyncAfter(deadline: .now() + idleReleaseDelay, execute: work)
    }

    /// Stop and return everything captured since start().
    ///
    /// Returns immediately: the samples are already in hand, and clearing
    /// `_isRecording` under the lock stops the render thread appending more.
    /// The graph teardown is queued behind whatever start is still in flight.
    func stop() -> [Float] {
        lock.lock()
        guard _isRecording else { lock.unlock(); return [] }
        _isRecording = false
        let out = samples
        let peak = peakLevel
        samples = []
        lock.unlock()

        engineQueue.async { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.releaseVoiceProcessing()
        }
        // A capture that ran but heard nothing means the default input is a
        // silent device (HDMI audio, a virtual mic) — the classic docked-
        // monitor failure, and previously an invisible one.
        if !out.isEmpty, peak < 0.001 {
            Log.error("AudioRecorder: \(out.count) samples captured but peak level ≈ 0 — " +
                      "\"\(capturedDeviceName)\" delivered silence " +
                      "(did the default mic change?)")
        }
        return out
    }

    // MARK: - CoreAudio device plumbing

    static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector)
        -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, if this machine has one (a Mac mini may not).
    static func builtInInputDeviceID() -> AudioDeviceID? {
        allDeviceIDs().first {
            transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInputStreams($0)
        }
    }

    /// Input-capable devices on trusted wired transports — the safe fallbacks
    /// when the built-in mic can't be steered to. Monitor audio (HDMI /
    /// DisplayPort), virtual devices, AirPlay, and Continuity mics are all
    /// excluded: each is a device that "works" while delivering silence.
    static func wiredInputDeviceIDs() -> [AudioDeviceID] {
        let trusted: Set<UInt32> = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire,
        ]
        return allDeviceIDs().filter { device in
            guard let transport = transportType(device),
                  trusted.contains(transport) else { return false }
            return hasInputStreams(device)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    /// Input side only — the built-in speakers are also "built-in".
    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &nameSize, $0)
        }
        return err == noErr ? (name as String) : "unknown"
    }

    /// Name of the system default input device, for session logs — when a
    /// recording is silent, which device delivered it is the whole story.
    private static func defaultInputDeviceName() -> String {
        defaultInputDeviceID().map { deviceName($0) } ?? "unknown"
    }

    func stopAndDiscard() {
        _ = stop()
    }

    var currentDuration: Double {
        lock.lock(); defer { lock.unlock() }
        // Streaming mode keeps no samples — duration comes from the counter.
        let frames = streamHandler != nil ? streamedFrames : Int64(samples.count)
        return Double(frames) / Double(WhisperEngine.sampleRate)
    }

    /// Copy of the most recent audio, for live-preview transcription while
    /// the recording continues.
    func snapshot(lastSeconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let maxCount = Int(lastSeconds * Double(WhisperEngine.sampleRate))
        if samples.count <= maxCount { return samples }
        return Array(samples.suffix(maxCount))
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else { return }

        let count = Int(out.frameLength)
        let ptr = ch[0]

        // RMS for the waveform, normalized into a useful visual range.
        var sum: Float = 0
        for i in 0..<count { sum += ptr[i] * ptr[i] }
        let rms = sqrt(sum / Float(max(count, 1)))
        let level = min(1.0, rms * 12)

        lock.lock()
        // A buffer can still arrive between stop() and the queued teardown;
        // it belongs to the session that just ended, not the next one.
        guard _isRecording else { lock.unlock(); return }
        let stream = streamHandler
        let offset = streamedFrames
        if stream != nil {
            streamedFrames += Int64(count)
        } else {
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
        }
        if level > peakLevel { peakLevel = level }
        lock.unlock()
        stream?(UnsafeBufferPointer(start: ptr, count: count), offset)
        DispatchQueue.main.async { [weak self] in
            self?.levelHandler?(level)
        }
    }
}
