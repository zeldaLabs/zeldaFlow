import Foundation
import CoreAudio
import AVFoundation

/// Watches WHO is holding the microphone — the sensor behind meeting
/// auto-start ("Zoom just opened the mic") and auto-stop (`.micIdle`: the
/// holder let go and stayed quiet). Port of OpenWhispr's
/// resources/macos-mic-listener.swift, upgraded from that file's boolean
/// MIC_ACTIVE/MIC_INACTIVE to per-process attribution:
///
///  - Tier 1 (primary): CoreAudio audio-process objects (macOS 14.4+,
///    kAudioHardwarePropertyProcessObjectList) name every HAL client and
///    say per client whether it is running input — pid + bundle ID, exactly
///    what the trigger logic needs to tell Zoom from Music.app.
///  - Tier 2 (fallback): the original's device-level detection, ported
///    near-verbatim (enumeration lines 31-103, running check 107-120,
///    hot-plug reconcile 155-183). Engaged only when tier 1 errors or
///    reports an empty client list while AVCaptureDevice says the mic is
///    authorized and in use — i.e. the process API is demonstrably lying.
///    Attribution degrades to a single anonymous MicUser(pid: -1).
///
/// Threading: CoreAudio dispatches listener blocks on the queue we hand it,
/// so all state is confined to one private serial queue; `onChange` hops to
/// main. Emission happens only on set transitions (sorted-array compare),
/// matching the original's edge-triggered MIC_ACTIVE/MIC_INACTIVE contract.
final class MicActivityMonitor {

    struct MicUser: Equatable {
        let pid: pid_t
        let bundleID: String?   // nil in the tier-2 fallback (and for unbundled binaries)
        /// The same process is also running audio OUTPUT — the signal that
        /// tells a WhatsApp call (input+output) from a voice-note recording
        /// (input only), ADR 33. Always false on the tier-2 fallback.
        /// Defaulted so every pre-existing constructor site stays valid.
        var runningOutput: Bool = false
    }

    /// Fired on the main queue on every change to the filtered holder set.
    /// Never contains our own pid — see the exclusion notes below.
    var onChange: (([MicUser]) -> Void)?

    // MARK: - Ported / spec constants

    /// ported: macos-mic-listener.swift:290 — listeners can miss events
    /// (the original grew this heartbeat for exactly that reason); it is
    /// also our safety net for the macOS 27 beta's stale HAL notifications.
    private static let heartbeatInterval: TimeInterval = 5
    /// The meeting tap's private aggregate device IS visible to its creating
    /// process and has input streams, so it reads as a running input device
    /// the entire meeting — a phantom always-on mic that would keep every
    /// meeting alive forever (.micIdle could never fire). Excluded at the
    /// source, by UID prefix, so no downstream consumer can forget to.
    private static let tapUIDPrefix = "com.zeldalabs.zeldaflow.tap."

    // MARK: - State (all confined to `queue`)

    private let queue = DispatchQueue(label: "com.zeldalabs.zeldaflow.mic-activity")
    /// Exclusion 1: zeldaFlow's own dictation capture must never look like a
    /// meeting participant, or pressing the hotkey would start a meeting.
    /// Filtering by pid here makes self-triggering structurally impossible.
    /// (This also covers the tap aggregate in tier 1: the process running
    /// input through that aggregate is us.)
    private let ownPID = getpid()
    private var started = false
    private var fallbackEngaged = false
    private var heartbeat: DispatchSourceTimer?
    private var lastEmitted: [MicUser] = []
    private var lastUnfiltered: [MicUser] = []

    // Tier 1: process objects currently carrying an IsRunningInput listener.
    private var processObjects: Set<AudioObjectID> = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processInputListener: AudioObjectPropertyListenerBlock?

    // Tier 2: input devices currently carrying a RunningSomewhere listener.
    private var inputDevices: Set<AudioDeviceID> = []
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var deviceRunningListener: AudioObjectPropertyListenerBlock?

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.fallbackEngaged = false
            self.lastEmitted = []
            self.lastUnfiltered = []
            // Tier selection happens once, at start: if the process-object
            // list is unreadable, or empty while AVCaptureDevice can see the
            // mic being held, the API is broken and device-level detection
            // takes over. An empty list with the mic genuinely idle is NOT
            // suspicious — coreaudiod only lists processes that are clients.
            if let list = Self.readObjectIDs(AudioObjectID(kAudioObjectSystemObject),
                                             kAudioHardwarePropertyProcessObjectList),
               !(list.isEmpty && Self.micAuthorizedAndInUse()) {
                self.startTier1()
            } else {
                self.engageFallback(reason: "process-object list unavailable at start")
            }
            // ported: macos-mic-listener.swift:289-294 (5 s repeating timer).
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.heartbeatInterval,
                           repeating: Self.heartbeatInterval)
            timer.setEventHandler { [weak self] in self?.recompute() }
            timer.resume()
            self.heartbeat = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.started = false
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.tearDownTier1()
            self.tearDownTier2()
            self.fallbackEngaged = false
            self.lastEmitted = []
            self.lastUnfiltered = []
        }
    }

    /// The last emitted (filtered, sorted) holder set.
    var currentUsers: [MicUser] { queue.sync { lastEmitted } }

    /// False when running on the tier-2 fallback: holders are then a single
    /// anonymous MicUser(pid: -1) and app-name attribution must not be trusted.
    var attributionAvailable: Bool { queue.sync { !fallbackEngaged } }

    /// Debug/eval hook: unfiltered holders including our own pid. Evals
    /// verify the underlying API sees us dictating while onChange never
    /// includes us — so this recomputes live rather than serving a cache
    /// that could be up to one heartbeat (5 s) stale.
    var debugUnfilteredUsers: [MicUser] {
        queue.sync {
            guard started else { return [] }
            recompute()
            return lastUnfiltered
        }
    }

    // MARK: - Tier 1: audio-process objects

    private func startTier1() {
        // One shared block per property: RemovePropertyListenerBlock only
        // unregisters the identical block instance, so each is created once.
        let inputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recompute()
        }
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // ported: macos-mic-listener.swift:155-183 — reconcile listeners
            // on list change, then re-check: a vanished process may have been
            // the active holder (that is how .micIdle sees "Zoom quit").
            self?.recompute()
        }
        processInputListener = inputListener
        processListListener = listListener
        var listAddr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listListener)
        if status != noErr {
            Log.error("MicActivityMonitor: process-list listener failed (\(status)); heartbeat-only reconcile")
        }
        recompute()
    }

    private func recomputeTier1() {
        guard let list = Self.readObjectIDs(AudioObjectID(kAudioObjectSystemObject),
                                            kAudioHardwarePropertyProcessObjectList) else {
            engageFallback(reason: "process-object enumeration failed")
            return
        }
        if list.isEmpty && Self.micAuthorizedAndInUse() {
            engageFallback(reason: "empty process list while mic in use")
            return
        }
        // Reconcile IsRunningInput listeners with the live process set.
        let newSet = Set(list)
        if let listener = processInputListener {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            for obj in newSet.subtracting(processObjects) {
                let status = AudioObjectAddPropertyListenerBlock(obj, &addr, queue, listener)
                if status != noErr {
                    Log.error("MicActivityMonitor: input listener on process \(obj) failed (\(status))")
                }
            }
            for obj in processObjects.subtracting(newSet) {
                // Best effort — the process object may already be gone.
                AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, listener)
            }
        }
        processObjects = newSet
        var users: [MicUser] = []
        for obj in processObjects {
            guard (Self.readUInt32(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                  let pid = Self.readPID(obj) else { continue }
            // Output state is read by POLL (heartbeat + any input-listener
            // fire), never trusted to its own listener — IsRunningOutput
            // listeners are documented-flaky on Apple's own forums, and the
            // 5 s heartbeat already recomputes everything.
            let output = (Self.readUInt32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            users.append(MicUser(pid: pid,
                                 bundleID: Self.readString(obj, kAudioProcessPropertyBundleID),
                                 runningOutput: output))
        }
        publish(unfiltered: users)
    }

    private func tearDownTier1() {
        if let listener = processInputListener {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            for obj in processObjects {
                AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, listener)
            }
        }
        if let listener = processListListener {
            var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        processObjects = []
        processInputListener = nil
        processListListener = nil
    }

    // MARK: - Tier 2: device-level fallback (ported: macos-mic-listener.swift)

    /// One-way door: a HAL that lied about process objects once will lie
    /// again, and flapping between tiers would flap attributionAvailable
    /// under the trigger logic. stop()/start() retries tier 1.
    private func engageFallback(reason: String) {
        guard !fallbackEngaged else { return }
        fallbackEngaged = true
        Log.error("MicActivityMonitor: device-level fallback (\(reason)) — per-process attribution off")
        tearDownTier1()
        let runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recompute()
        }
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.recompute()
        }
        deviceRunningListener = runningListener
        deviceListListener = listListener
        // ported: macos-mic-listener.swift:221-236 — hot-plug listener on the
        // system object's device list.
        var listAddr = Self.address(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listListener)
        if status != noErr {
            Log.error("MicActivityMonitor: device-list listener failed (\(status)); heartbeat-only reconcile")
        }
        recompute()
    }

    private func recomputeTier2() {
        // ported: macos-mic-listener.swift:161-180 — reconcile per-device
        // listeners against the live list, then re-check state (a removed
        // device may have been the active one).
        let newSet = Set(Self.inputCapableDevices())
        if let listener = deviceRunningListener {
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            for id in newSet.subtracting(inputDevices) {
                let status = AudioObjectAddPropertyListenerBlock(id, &addr, queue, listener)
                if status != noErr {
                    Log.error("MicActivityMonitor: running listener on device \(id) failed (\(status))")
                }
            }
            for id in inputDevices.subtracting(newSet) {
                AudioObjectRemovePropertyListenerBlock(id, &addr, queue, listener)
            }
        }
        inputDevices = newSet
        // ported: macos-mic-listener.swift:107-129 — OR of RunningSomewhere
        // over input devices; who is running it is unknowable at this level.
        let active = inputDevices.contains { Self.isDeviceRunning($0) }
        publish(unfiltered: active ? [MicUser(pid: -1, bundleID: nil)] : [])
    }

    private func tearDownTier2() {
        if let listener = deviceRunningListener {
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            for id in inputDevices {
                AudioObjectRemovePropertyListenerBlock(id, &addr, queue, listener)
            }
        }
        if let listener = deviceListListener {
            var addr = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        inputDevices = []
        deviceRunningListener = nil
        deviceListListener = nil
    }

    // MARK: - Shared recompute / emit

    private func recompute() {
        guard started else { return }
        fallbackEngaged ? recomputeTier2() : recomputeTier1()
    }

    private func publish(unfiltered: [MicUser]) {
        let sortedAll = unfiltered.sorted {
            $0.pid != $1.pid ? $0.pid < $1.pid : ($0.bundleID ?? "") < ($1.bundleID ?? "")
        }
        lastUnfiltered = sortedAll
        let filtered = sortedAll.filter { $0.pid != ownPID }
        guard filtered != lastEmitted else { return }
        lastEmitted = filtered
        let label = filtered.isEmpty ? "(none)"
            : filtered.map { "\($0.bundleID ?? "?")#\($0.pid)\($0.runningOutput ? "+out" : "")" }
                .joined(separator: " ")
        Log.info("MicActivityMonitor: mic holders -> \(label)")
        DispatchQueue.main.async { [weak self] in
            // onChange is read here, on main, where it is also set.
            self?.onChange?(filtered)
        }
    }

    // MARK: - CoreAudio property plumbing (fileprivate helpers)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// ported: macos-mic-listener.swift:31-66 (generalized: the same
    /// size-then-data dance reads both the device list and the process list).
    private static func readObjectIDs(_ objectID: AudioObjectID,
                                      _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    private static func readUInt32(_ objectID: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readString(_ objectID: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        let string = cf as String
        // kAudioProcessPropertyBundleID hands back "" for unbundled binaries;
        // MicUser models that as nil, not empty.
        return string.isEmpty ? nil : string
    }

    /// ported: macos-mic-listener.swift:107-120.
    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        (readUInt32(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) > 0
    }

    /// ported: macos-mic-listener.swift:31-103 — device enumeration filtered
    /// to input-capable via the input-scope stream configuration — plus the
    /// two source-level exclusions this port adds.
    private static func inputCapableDevices() -> [AudioDeviceID] {
        guard let devices = readObjectIDs(AudioObjectID(kAudioObjectSystemObject),
                                          kAudioHardwarePropertyDevices) else {
            Log.error("MicActivityMonitor: device enumeration failed")
            return []
        }
        return devices.filter { deviceID in
            // Exclusion 2: our meeting tap's private aggregate by UID prefix,
            // and aggregate-transport devices generally — at this tier there
            // is no pid to tell "our tap is running" from "a real mic is",
            // and any aggregate wrapping an input reads as one more phantom.
            if let uid = readString(deviceID, kAudioDevicePropertyDeviceUID),
               uid.hasPrefix(tapUIDPrefix) { return false }
            if readUInt32(deviceID, kAudioDevicePropertyTransportType)
                == kAudioDeviceTransportTypeAggregate { return false }
            // ported: macos-mic-listener.swift:69-102. Deviation: the buffer
            // is allocated at the reported streamSize, not one AudioBufferList
            // — the original under-allocates for devices with >1 stream and
            // only got away with it by reading just the first buffer.
            var streamAddr = address(kAudioDevicePropertyStreamConfiguration,
                                     scope: kAudioObjectPropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return false }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(streamSize),
                alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &streamSize, raw) == noErr
            else { return false }
            let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self).pointee
            return bufferList.mNumberBuffers > 0 && bufferList.mBuffers.mNumberChannels > 0
        }
    }

    /// The tier-2 engagement guard: only distrust an empty tier-1 list when
    /// the OS itself says some app is holding the (authorized) mic.
    /// AVFoundation is imported for this check alone.
    private static func micAuthorizedAndInUse() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        return AVCaptureDevice.default(for: .audio)?.isInUseByAnotherApplication ?? false
    }
}
