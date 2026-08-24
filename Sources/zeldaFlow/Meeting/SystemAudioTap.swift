import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio

/// Captures everything the Mac plays — the meeting's "Them" channel — via a
/// CoreAudio process tap: CATapDescription → AudioHardwareCreateProcessTap →
/// private aggregate device → IOProc → AVAudioConverter → 16 kHz mono Float32
/// chunks. In-process port of OpenWhispr's helper binary
/// (resources/macos-audio-tap.swift); divergences are marked inline, the
/// biggest being that we exclude our own process from the tap and that a
/// long-lived class needs real synchronization and recovery where a
/// spawn-per-capture helper could shrug and exit.
///
/// Threading: start()/stop()/probePermission serialize on one shared control
/// queue (two live taps would double-capture the same output); conversion and
/// `chunkHandler` run on a dedicated IO queue handed to CoreAudio. Never call
/// stop() from the IO queue — AudioDeviceDestroyIOProcID waits for in-flight
/// callbacks, and a callback waiting on its own destruction never returns.
final class SystemAudioTap {

    enum TapError: Error {
        case permissionDenied(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case deviceNeverBecameAlive
        case formatUnavailable(OSStatus)
        case converterUnavailable
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case noFramesAfterStart
    }

    /// ~100 ms (1600 frames) of 16 kHz mono Float32 per call, on the IO queue
    /// (the stop-flush tail arrives on the control queue — the IOProc is
    /// already destroyed by then). `frameOffset` counts frames since start();
    /// derive timestamps from it, never from clocks — sample counts can't
    /// drift. Do not block here and never call stop() from inside it.
    var chunkHandler: ((_ samples: [Float], _ frameOffset: Int64) -> Void)?

    /// Mid-capture failure after the single automatic restart is spent; the
    /// tap is already stopped when this fires (on the control queue).
    var onError: ((TapError) -> Void)?

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _running
    }

    /// Synchronous bring-up — call off main: the device-alive poll alone may
    /// cost up to 2 s (ported ceiling, see waitForDeviceAlive). Resets the
    /// frame counter to zero. A start while already running is a no-op.
    func start() throws {
        try Self.controlQueue.sync {
            didAutoRestart = false
            try startOnControlQueue(verifyFrames: true, resetOffset: true)
        }
    }

    /// Idempotent, safe from any thread except the IO queue (class comment)
    /// — and not from the control queue itself (sync onto it would deadlock);
    /// onError/chunkHandler callbacks therefore must never call stop().
    func stop() {
        Self.controlQueue.sync { stopOnControlQueue() }
    }

    // MARK: - Tuning

    /// MicActivityMonitor excludes devices whose UID starts with this prefix —
    /// the exact string is load-bearing: our own aggregate must not read as
    /// "another app is holding the mic" and stop the very meeting it serves.
    private static let uidPrefix = "com.zeldalabs.zeldaflow.tap."

    /// 100 ms chunk cadence ported (macos-audio-tap.swift parseConfig:
    /// chunkMilliseconds default 100). The rate diverges from OpenWhispr's
    /// 24 kHz default: chunks feed WhisperEngine directly, so we convert once,
    /// straight to its 16 kHz — 1600 frames per chunk.
    private static let chunkFrames = WhisperEngine.sampleRate / 10

    /// House invariant (not in the port): a start that never delivers frames
    /// is a failed start. 3 s is generous — a live tap delivers its first
    /// IOProc callback within ~100 ms.
    private static let verifyTimeout: TimeInterval = 3.0

    /// Gap between teardown and the automatic restart: coreaudiod needs a
    /// beat after AudioHardwareDestroyProcessTap before the next create
    /// reliably succeeds (~50 ms observed; immediate re-create intermittently
    /// returns kAudioHardwareBadObjectError).
    private static let restartGap: TimeInterval = 0.05

    // MARK: - State

    private static let controlQueue = DispatchQueue(label: "zeldaflow.meeting.tap-control",
                                                    qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "zeldaflow.meeting.tap-io", qos: .userInitiated)

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(WhisperEngine.sampleRate),
                                             channels: 1, interleaved: false)!

    // Control-queue-owned CoreAudio objects. Each ID zeroes after its destroy
    // so a double-stop is a no-op (ported shape, macos-audio-tap.swift:75-99).
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var didAutoRestart = false

    // IO-queue-owned while running; the control queue touches them only when
    // no IOProc exists (before start, and after DestroyIOProcID has
    // synchronized with in-flight callbacks) — that barrier is what makes
    // lockless access sound here.
    private var pending: [Float] = []
    private var frameOffset: Int64 = 0

    // Cross-queue flags. The original reads `stopping` unsynchronized — fine
    // for a helper process about to exit, not for a class that starts again;
    // divergence: everything the IO queue reads is behind this lock.
    private let stateLock = NSLock()
    private var _running = false
    private var _stopping = false
    private var _sawFrames = false
    /// Bumped on every start and stop; stale watchdog / recovery closures
    /// compare generations and become no-ops instead of killing a new session.
    private var generation: UInt64 = 0

    // MARK: - Start / stop (control queue)

    private func startOnControlQueue(verifyFrames: Bool, resetOffset: Bool) throws {
        guard !isRunning else { return }
        stateLock.lock()
        generation &+= 1
        let gen = generation
        _stopping = false
        _sawFrames = false
        stateLock.unlock()
        if resetOffset { frameOffset = 0 }
        pending.removeAll(keepingCapacity: true)

        do {
            try createTap()
            try createAggregate(tapUID: copyTapUID())
            try waitForDeviceAlive()
            try buildConverter()
            try installIOProc()
            installAliveListener(generation: gen)
            let status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw Self.mapped(status) { .startFailed($0) } }
        } catch {
            teardownOnControlQueue(flush: false)
            if case TapError.permissionDenied = error {
                // Reconcile the inferred-permission cache on every real start:
                // 'nope' from any step is TCC saying no (see probePermission).
                Permissions.setSystemAudio(.denied)
            }
            throw error
        }

        stateLock.lock(); _running = true; stateLock.unlock()
        Log.info("SystemAudioTap: started (tap \(tapID), aggregate \(aggregateID))")

        if verifyFrames {
            // Zero FRAMES, not zero amplitude — a silent Mac still delivers
            // zero-valued frames, so this never fires on mere silence.
            Self.controlQueue.asyncAfter(deadline: .now() + Self.verifyTimeout) { [weak self] in
                guard let self, self.currentGeneration() == gen, self.isRunning else { return }
                self.stateLock.lock(); let saw = self._sawFrames; self.stateLock.unlock()
                guard !saw else { return }
                Log.error("SystemAudioTap: no frames within \(Self.verifyTimeout) s of start")
                self.stopOnControlQueue()
                self.onError?(.noFramesAfterStart)
            }
        }
    }

    private func stopOnControlQueue() {
        stateLock.lock()
        let wasRunning = _running
        _running = false
        _stopping = true
        generation &+= 1
        stateLock.unlock()
        teardownOnControlQueue(flush: wasRunning)
        if wasRunning { Log.info("SystemAudioTap: stopped") }
    }

    /// Ported teardown order (macos-audio-tap.swift stop(), lines 75-99):
    /// AudioDeviceStop → AudioDeviceDestroyIOProcID (synchronizes with
    /// in-flight IO callbacks — after it returns nothing else touches
    /// `pending`) → destroy aggregate → destroy tap → flush the tail.
    private func teardownOnControlQueue(flush: Bool) {
        stateLock.lock(); _stopping = true; stateLock.unlock()

        if aggregateID != 0 { AudioDeviceStop(aggregateID, ioProcID) }
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        removeAliveListener()
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        converter = nil
        sourceFormat = nil

        if flush, !pending.isEmpty {
            // Ported flushPendingPCM: the tail shorter than one chunk still
            // reaches the consumer — the last words of a meeting live here.
            let tail = pending
            pending = []
            chunkHandler?(tail, frameOffset)
            frameOffset += Int64(tail.count)
        } else {
            pending.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - CoreAudio object construction (control queue)

    private func createTap() throws {
        // Divergence from the port: exclude our own process. zeldaFlow plays
        // feedback sounds (dictation chimes); OpenWhispr's plain global tap
        // would put those into the "Them" channel and Whisper would dutifully
        // transcribe our own chime. If pid translation fails we degrade to
        // the ported global shape — worse transcript beats no meeting.
        var excluded: [AudioObjectID] = []
        if let own = Self.ownProcessObject() {
            excluded = [own]
        } else {
            Log.error("SystemAudioTap: cannot translate own pid; tap will include our own output")
        }
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = Self.uidPrefix + "output"
        desc.uuid = UUID()
        desc.isPrivate = true                              // ported: invisible to HAL device lists
        desc.muteBehavior = CATapMuteBehavior.unmuted      // ported: the user keeps hearing the call

        var newTapID = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else { throw Self.mapped(status) { .tapCreationFailed($0) } }
        tapID = newTapID
    }

    /// Ported: getTapUID (macos-audio-tap.swift:287-302). A tap whose UID
    /// can't be read can't join an aggregate, so failure maps to
    /// tapCreationFailed — the tap exists but is unusable.
    private func copyTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let unmanaged else {
            throw Self.mapped(status) { .tapCreationFailed($0) }
        }
        return unmanaged.takeRetainedValue() as String
    }

    /// Dictionary ported key-for-key (createAggregateDevice,
    /// macos-audio-tap.swift:101-118); only the name/UID prefix differs —
    /// see `uidPrefix` for why the exact string matters.
    private func createAggregate(tapUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.uidPrefix + "aggregate",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var deviceID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else { throw Self.mapped(status) { .aggregateCreationFailed($0) } }
        aggregateID = deviceID
    }

    /// Ported verbatim: 20 polls × 100 ms on kAudioDevicePropertyDeviceIsAlive
    /// (macos-audio-tap.swift:120-145). The aggregate usually reports alive on
    /// the first poll; the 2 s ceiling covers coreaudiod under load.
    private func waitForDeviceAlive() throws {
        var address = Self.aliveAddress
        for _ in 0..<20 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &alive) == noErr,
               alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TapError.deviceNeverBecameAlive
    }

    /// Ported: configureConverter (macos-audio-tap.swift:147-170), one
    /// AVAudioConverter hop from the tap's native format (kAudioTapProperty-
    /// Format ASBD) to 16 kHz mono Float32.
    private func buildConverter() throws {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw Self.mapped(status) { .formatUnavailable($0) } }
        guard let source = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: source, to: targetFormat) else {
            throw TapError.converterUnavailable
        }
        sourceFormat = source
        converter = conv
    }

    private func installIOProc() throws {
        guard let sourceFormat, let converter else { throw TapError.converterUnavailable }
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handleIO(inputData, sourceFormat: sourceFormat, converter: converter)
        }
        guard status == noErr, let procID else {
            throw Self.mapped(status) { .ioProcCreationFailed($0) }
        }
        ioProcID = procID
    }

    // MARK: - IO path (IO queue)

    private func handleIO(_ inputData: UnsafePointer<AudioBufferList>,
                          sourceFormat: AVAudioFormat,
                          converter: AVAudioConverter) {
        stateLock.lock()
        let bail = _stopping
        stateLock.unlock()
        if bail { return }

        let list = UnsafeMutablePointer(mutating: inputData)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                  bufferListNoCopy: list,
                                                  deallocator: nil),
              sourceBuffer.frameLength > 0 else { return }

        // First frames prove both that the tap is live (verify watchdog) and
        // that TCC actually let us have them — granted is recorded here, not
        // at AudioDeviceStart, so a start that never delivers frames cannot
        // overwrite a denied verdict in the cache.
        stateLock.lock()
        let firstFrames = !_sawFrames
        _sawFrames = true
        stateLock.unlock()
        if firstFrames { Permissions.setSystemAudio(.granted) }

        // Ported conversion loop (macos-audio-tap.swift:212-236): +32 frame
        // headroom absorbs resampler rounding, floor of 32 keeps a degenerate
        // tiny buffer allocatable; single-shot input closure (.haveData then
        // .noDataNow) so one IOProc buffer is at most one convert pass.
        let sourceRate = max(sourceFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                            frameCapacity: max(capacity, 32)) else { return }

        var provided = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let convertError {
            // Divergence from the port (which emitted a JSON error line and
            // dropped the buffer): schedule teardown + one restart. Cannot
            // stop from here — DestroyIOProcID would wait on this callback.
            Log.error("SystemAudioTap: convert failed mid-capture: \(convertError.localizedDescription)")
            let gen = currentGeneration()
            Self.controlQueue.async { [weak self] in
                self?.recoverOnControlQueue(surfacing: .converterUnavailable, generation: gen)
            }
            return
        }
        guard status == .haveData || status == .inputRanDry else { return }   // ported

        let frames = Int(output.frameLength)
        guard frames > 0, let channel = output.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))

        while pending.count >= Self.chunkFrames {
            let chunk = Array(pending.prefix(Self.chunkFrames))
            pending.removeFirst(Self.chunkFrames)
            chunkHandler?(chunk, frameOffset)
            frameOffset += Int64(Self.chunkFrames)
        }
    }

    // MARK: - Mid-capture recovery (control queue)

    /// One automatic stop → ~50 ms gap → start per session before failures
    /// surface: transient coreaudiod hiccups (device died, converter wedged)
    /// otherwise kill an hour-long meeting over a 150 ms glitch. The frame
    /// counter is preserved across the restart so downstream timestamps stay
    /// monotonic; the real audio gap is the price of the glitch, not of us.
    private func recoverOnControlQueue(surfacing failure: TapError, generation gen: UInt64) {
        guard currentGeneration() == gen, isRunning else { return }   // stale request
        stopOnControlQueue()
        guard !didAutoRestart else {
            Log.error("SystemAudioTap: failure recurred after automatic restart — surfacing")
            onError?(failure)
            return
        }
        didAutoRestart = true
        Thread.sleep(forTimeInterval: Self.restartGap)
        do {
            try startOnControlQueue(verifyFrames: true, resetOffset: false)
            Log.info("SystemAudioTap: automatic restart succeeded, frame offset preserved")
        } catch let error as TapError {
            onError?(error)
        } catch {
            onError?(failure)
        }
    }

    /// Divergence from the port (a short-lived helper never outlives its
    /// device): watch the aggregate's alive flag so a coreaudiod restart or
    /// device teardown mid-meeting triggers recovery instead of silence.
    private func installAliveListener(generation gen: UInt64) {
        var address = Self.aliveAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on controlQueue (registered below), so recovery may
            // run inline.
            guard let self, self.currentGeneration() == gen, self.isRunning else { return }
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.aliveAddress
            let status = AudioObjectGetPropertyData(self.aggregateID, &addr, 0, nil, &size, &alive)
            if status != noErr || alive == 0 {
                Log.error("SystemAudioTap: aggregate died mid-capture (status \(status), alive \(alive))")
                self.recoverOnControlQueue(surfacing: .deviceNeverBecameAlive, generation: gen)
            }
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, Self.controlQueue, listener) == noErr {
            aliveListener = listener
        }
    }

    private func removeAliveListener() {
        guard let aliveListener else { return }
        if aggregateID != 0 {
            var address = Self.aliveAddress
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address,
                                                   Self.controlQueue, aliveListener)
        }
        self.aliveListener = nil
    }

    // MARK: - Permission inference

    /// No TCC query API exists for system-audio capture, so run a real
    /// start/stop cycle and infer (OpenWhispr's inference, inferErrorCode,
    /// macos-audio-tap.swift:373-378): frames delivered ⇒ granted;
    /// kAudioHardwareIllegalOperationError ('nope', 1852797029) at any step ⇒
    /// denied; nothing within `timeout` ⇒ unknown. The 60 s default exists
    /// because tap creation blocks while the TCC consent dialog is on screen
    /// — the timeout is really "how long the user gets to click Allow".
    /// Granted/denied verdicts persist via Permissions.setSystemAudio; a
    /// timeout persists nothing (it proves nothing, and overwriting a known
    /// verdict with unknown would re-prompt the user for no reason).
    /// Completion is delivered on the main queue, exactly once.
    static func probePermission(timeout: TimeInterval = 60,
                                completion: @escaping (Permissions.SystemAudioPermission) -> Void) {
        let once = FinishOnce()
        func finish(_ result: Permissions.SystemAudioPermission) {
            once.run { DispatchQueue.main.async { completion(result) } }
        }
        // Separate watchdog rather than a deadline inside the probe body: the
        // body itself can block inside AudioHardwareCreateProcessTap while
        // the consent dialog is up, and the caller still deserves an answer.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            finish(.unknown)
        }
        controlQueue.async {
            let tap = SystemAudioTap()
            let framesSeen = DispatchSemaphore(value: 0)
            tap.chunkHandler = { _, _ in framesSeen.signal() }
            do {
                // verifyFrames off: the 3 s watchdog would cut the probe short
                // while the user is still reading the consent dialog.
                try tap.startOnControlQueue(verifyFrames: false, resetOffset: true)
            } catch {
                tap.stopOnControlQueue()
                if case TapError.permissionDenied = error {
                    finish(.denied)     // cache already reconciled by start
                } else {
                    finish(.unknown)    // hardware trouble, not a TCC verdict
                }
                return
            }
            let got = framesSeen.wait(timeout: .now() + timeout) == .success
            tap.stopOnControlQueue()
            if got { finish(.granted) } // cache already reconciled by handleIO
            else { finish(.unknown) }
        }
    }

    // MARK: - Helpers

    /// Ported: inferErrorCode (macos-audio-tap.swift:373-378). TCC denial
    /// surfaces as kAudioHardwareIllegalOperationError from whichever call
    /// hits it first, so every OSStatus check funnels through here before
    /// becoming a step-specific error.
    private static func mapped(_ status: OSStatus, _ fallback: (OSStatus) -> TapError) -> TapError {
        status == kAudioHardwareIllegalOperationError ? .permissionDenied(status) : fallback(status)
    }

    /// getpid() → HAL process object, for the tap's exclusion list.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid: pid_t = getpid()
        var object = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                       &size, &object)
        }
        guard status == noErr, object != 0 else { return nil }
        return object
    }

    private static var aliveAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }
}

/// Completion-once guard for probePermission: the timeout watchdog and the
/// probe body race, and the loser must stay silent.
private final class FinishOnce {
    private let lock = NSLock()
    private var fired = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}
