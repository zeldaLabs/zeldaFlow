import Foundation

// MARK: - Signals

/// One observation entering the auto-start/auto-stop state machine. All
/// signals arrive on the main actor (MicActivityMonitor and NSWorkspace both
/// deliver there); evals call handle() directly with a scripted clock.
enum MeetingSignal: Equatable {
    /// Who holds the microphone right now. `attributed: true` means per-
    /// process attribution worked and pids/bundle IDs are real. `false` is
    /// the degraded tier-2 signal — only device-level "some process holds
    /// the mic" (OpenWhispr has the same split: per-pid MIC_START/MIC_STOP
    /// on Windows vs a bare IOAudioEngineState bit on the macOS polling
    /// path; ported: audioActivityDetector.js).
    case micUsers([MicActivityMonitor.MicUser], attributed: Bool)
    case appLaunched(bundleID: String)
    case appTerminated(bundleID: String)

    /// Manual ==: MicActivityMonitor.MicUser is not required to be
    /// Equatable, so compare the identity fields directly. runningOutput is
    /// part of the comparison because an output flip on the same holder IS
    /// a distinct signal (the WhatsApp call-vs-voice-note dwell, ADR 33).
    static func == (l: MeetingSignal, r: MeetingSignal) -> Bool {
        switch (l, r) {
        case let (.micUsers(a, x), .micUsers(b, y)):
            return x == y && a.count == b.count
                && zip(a, b).allSatisfy {
                    $0.pid == $1.pid && $0.bundleID == $1.bundleID
                        && $0.runningOutput == $1.runningOutput
                }
        case let (.appLaunched(a), .appLaunched(b)): return a == b
        case let (.appTerminated(a), .appTerminated(b)): return a == b
        default: return false
        }
    }
}

// MARK: - Engine

/// The auto-start/auto-stop state machine (ADR 0027). OpenWhispr detects and
/// then PROMPTS; zeldaFlow deliberately diverges: detection starts recording
/// with no prompt, so corroboration is stricter — only a KNOWN meeting app
/// HOLDING the mic can trigger (attributed tier). Mere app-running plus
/// device-level mic heuristics is the tier-2 fallback, never the default.
///
/// START policy (the load-bearing table):
///   armed -> pending    a MicUser's bundleID passes MeetingApps
///                       .isMeetingCapable (personal-call apps gated by their
///                       settings toggles), user is not dictating, no
///                       cooldown is running. Browser holders additionally
///                       need a browserProbe hit — probed at pending entry,
///                       re-probed every browserReprobeInterval up to
///                       corroborationWindow.
///   pending -> start    the SAME holder (same pid, or same resolved
///                       browser — Chrome helper pids churn) held for
///                       >= sustainSeconds AND corroboration passed.
///   output dwell        holders in MeetingApps.outputCorroboration
///                       (WhatsApp) corroborate ONLY by showing mic input
///                       AND audio output concurrently for
///                       personalCallOutputDwell — a voice-note recording is
///                       input-only and expires the corroboration window;
///                       playback is output-only and never enters pending
///                       (ADR 33).
///   tier-2 fallback     attributed == false: sustained device-level mic
///                       activity corroborated by a native meeting app
///                       running (appLaunched/Terminated + runningApps()) or
///                       a browser probe hit. Output-dwell apps NEVER
///                       corroborate tier-2 — an all-day chat app running is
///                       not evidence of a call. Accepts the Teams-idle
///                       false positive only because the degraded tier has
///                       nothing better to attribute with.
///   NEVER started by    unknown bundle IDs (Voice Memos, dictation apps),
///                       personal-call apps whose toggle is off, anything
///                       while userDictating or within postDictationCooldown
///                       after (ported: meetingDetectionEngine.js).
@MainActor
final class MeetingDetectionEngine {
    enum State: Equatable {
        case disarmed
        case armed
        case pending(since: Date, holder: MicActivityMonitor.MicUser)     // sustain + corroboration window
        case capturing(since: Date, holder: MicActivityMonitor.MicUser)
        case stopPending(inactiveSince: Date)                             // still capturing; countdown
        case cooldown(until: Date)

        static func == (l: State, r: State) -> Bool {
            switch (l, r) {
            case (.disarmed, .disarmed), (.armed, .armed): return true
            case let (.pending(a, u), .pending(b, v)),
                 let (.capturing(a, u), .capturing(b, v)):
                return a == b && u.pid == v.pid && u.bundleID == v.bundleID
            case let (.stopPending(a), .stopPending(b)): return a == b
            case let (.cooldown(a), .cooldown(b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .disarmed
    var onShouldStart: ((MeetingTrigger) -> Void)?
    var onShouldStop: ((MeetingStopReason) -> Void)?
    var onStateChange: ((State) -> Void)?          // UI/eval observation

    // Injectable thresholds, the AudioRecorder.idleReleaseDelay precedent:
    // --evalmeeting shrinks all of them and drives now() so the whole machine
    // runs in ~2 s wall time.
    /// Ported: SUSTAINED_EVENT_DRIVEN_MS = 2 * 1000 (audioActivityDetector.js).
    var sustainSeconds: TimeInterval = 2.0
    /// How long a browser may hold the mic before we stop probing for a
    /// meeting tab. 2 min covers slow lobby -> call transitions; past that a
    /// mic-holding browser with no meeting tab is a dictation site, not a call.
    var corroborationWindow: TimeInterval = 120
    var browserReprobeInterval: TimeInterval = 5
    /// 30 s, not instant — brief mic releases happen on route changes: an
    /// AirPods reconnect mid-call drops and re-acquires the app's mic hold
    /// (observed 3-10 s gap), and stopping there would split one meeting.
    var stopAfterInactiveSeconds: TimeInterval = 30
    /// Safari releases the mic on MUTE (WebKit tears the capture down), so
    /// for a browser-held capture "mic idle 30 s" cannot tell muted-and-
    /// listening from hung-up. At the stop deadline the probe breaks the
    /// tie: meeting tab still visible → defer and re-check; tab gone →
    /// stop. Bounded, because a leave page whose title still matches must
    /// not hold a silent recording open until the 4 h cap.
    var browserMuteHold: TimeInterval = 600
    /// A quit process cannot rejoin the same call; the 5 s only covers
    /// crash-then-instant-relaunch before we finalize.
    var processQuitStopSeconds: TimeInterval = 5
    /// Ported: COOLDOWN_MS = 5 * 60 * 1000 (audioActivityDetector.js) — a
    /// manual stop is a dismissal; don't re-trigger on the same call.
    var manualCooldown: TimeInterval = 300
    /// Ported: INACTIVE_RESET_MS = 60 * 1000 (audioActivityDetector.js).
    var autoRearmDelay: TimeInterval = 60
    /// Ported: the 2500 ms post-recording setTimeout in setUserRecording
    /// (meetingDetectionEngine.js) — the dictation mic teardown itself looks
    /// like activity for a beat.
    var postDictationCooldown: TimeInterval = 2.5
    var maxMeetingSeconds: TimeInterval = 4 * 3600
    /// How long an output-corroboration holder (WhatsApp) must show mic
    /// input AND audio output concurrently before it counts as a call. The
    /// 5 s mic-monitor heartbeat quantizes this, so the effective trigger is
    /// ~10-15 s — ringback plus the first exchange, never a voice note.
    var personalCallOutputDwell: TimeInterval = 10
    var now: () -> Date = Date.init                // injected clock for evals
    /// Injected BrowserMeetingProbe.meetingTabVisible. Fail-closed default:
    /// an unwired probe corroborates nothing, so a browser can never
    /// auto-start on mic hold alone.
    var browserProbe: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    /// Personal-call apps the user has opted in (each has its own toggle).
    /// Closure-read on every decision, so flipping a toggle mid-run applies
    /// instantly with no re-arm.
    var enabledPersonalCallApps: () -> Set<String> = {
        var enabled: Set<String> = []
        if AppSettings.shared.meetingDetectFaceTime { enabled.insert(MeetingApps.facetime) }
        if AppSettings.shared.meetingDetectWhatsApp { enabled.insert(MeetingApps.whatsapp) }
        return enabled
    }
    /// Currently running app bundle IDs, for tier-2 corroboration (apps
    /// launched before we armed never produced an appLaunched signal).
    var runningApps: () -> Set<String> = { [] }

    // MARK: Private state

    /// Bumped on every transition; timers capture it and ignore stale fires
    /// (ported: the _startGeneration/_isStale pattern, audioActivityDetector.js).
    private var generation: UInt64 = 0
    private var userDictating = false
    private var dictationCooldownUntil = Date.distantPast
    /// Survives capturing <-> stopPending so a mic blip resumes the SAME
    /// meeting with its original start (back-to-back hysteresis).
    private var captureContext: (since: Date, holder: MicActivityMonitor.MicUser)?
    /// True when the holder identity cannot be matched per-process (tier-2
    /// or manual start): "holder active" then means "any mic activity".
    private var deviceLevelHolder = false
    private var pendingCorroborated = false
    private var pendingTier2 = false
    private var pendingTrigger: MeetingTrigger?
    /// The pending holder is an output-corroboration app (WhatsApp): only
    /// the input+output dwell may corroborate it — never the browser probe.
    private var pendingNeedsOutputDwell = false
    /// Accumulated input+output concurrency for the pending holder, and when
    /// it was last observed. Accumulated rather than "unbroken since X": the
    /// mic monitor publishes on CHANGE plus a 5 s heartbeat, so a steady call
    /// emits few snapshots and a single output-false reading (a talk-spurt
    /// gap) must not throw the whole run away. Scattered blips still can't
    /// add up — a gap longer than outputConcurrencyGapReset starts over.
    private var outputConcurrentAccum: TimeInterval = 0
    private var lastOutputConcurrentAt: Date?
    /// 3x, not 2x: at 2x the "sighting exactly one heartbeat apart" case sits
    /// exactly on the boundary and loses to floating-point drift.
    private var outputConcurrencyGapReset: TimeInterval { personalCallOutputDwell * 3 }
    private var startFired = false
    private var stopFired = false
    private var holderQuit = false
    private var lastProbeAt = Date.distantPast
    private var probeInFlightGen: UInt64?
    /// The mute-defer hold can re-probe for many minutes; log it once.
    private var stopDeferLogged = false
    /// Meeting-capable apps seen launching while armed; unioned with
    /// runningApps() for tier-2. Launch alone NEVER triggers — process
    /// detection is context-only, exactly to avoid the FaceTime-running-in-
    /// the-background false positive (ported: meetingDetectionEngine.js
    /// _bindListeners comment).
    private var launchedMeetingApps: Set<String> = []
    /// A holder whose corroboration window expired without a probe hit stays
    /// latched out until it releases the mic — otherwise the same continuous
    /// hold re-enters pending forever and probes every 5 s indefinitely
    /// (ported: the hasPrompted latch, audioActivityDetector.js).
    private var exhaustedHolder: MicActivityMonitor.MicUser?

    private var dictationSuppressed: Bool {
        userDictating || now() < dictationCooldownUntil
    }
    private var currentStopDelay: TimeInterval {
        holderQuit ? processQuitStopSeconds : stopAfterInactiveSeconds
    }

    // MARK: Lifecycle

    func arm() {
        guard case .disarmed = state else { return }
        Log.info("MeetingDetection: armed")
        transition(to: .armed)
    }

    func disarm() {
        Log.info("MeetingDetection: disarmed")
        resetDetectionScratch()
        captureContext = nil
        exhaustedHolder = nil
        launchedMeetingApps.removeAll()
        transition(to: .disarmed)
    }

    /// MeetingCenter confirms capture began (auto or manual) -> capturing.
    func meetingDidStart() {
        stopFired = false
        holderQuit = false
        let holder: MicActivityMonitor.MicUser
        if case .pending(_, let h) = state {
            holder = h
            deviceLevelHolder = pendingTier2
        } else {
            // Manual start: no attributed holder exists. pid -1 can never
            // match a real MicUser, so stop tracking degrades to device
            // level: the meeting ends only when the whole mic goes quiet.
            holder = MicActivityMonitor.MicUser(pid: -1, bundleID: nil)
            deviceLevelHolder = true
        }
        captureContext = (now(), holder)
        transition(to: .capturing(since: now(), holder: holder))
    }

    /// MeetingCenter reports the meeting ended. Manual stop = the user
    /// declined this call: 5 min cooldown. Auto stop: 60 s, just enough to
    /// not re-trigger on the dying call's mic tail.
    func meetingWasStopped(manually: Bool) {
        resetDetectionScratch()
        captureContext = nil
        if case .disarmed = state { return }   // disarmed mid-meeting stays disarmed
        transition(to: .cooldown(until: now().addingTimeInterval(
            manually ? manualCooldown : autoRearmDelay)))
    }

    /// Suppress starts while dictating and for postDictationCooldown after
    /// (ported: setUserRecording, both source files). A capture in progress
    /// is untouched — dictating during a meeting must not stop it.
    func setUserDictating(_ active: Bool) {
        userDictating = active
        if active {
            // Ported: setUserRecording clears the sustained timer — a
            // pending detection dies rather than firing mid-dictation.
            if case .pending = state { abandonPending() }
        } else {
            dictationCooldownUntil = now().addingTimeInterval(postDictationCooldown)
            // Ported: the _flushNotificationQueue pattern — a meeting app
            // that grabbed the mic during dictation produced no NEW signal,
            // so replay the last snapshot once the cooldown lapses.
            schedule(after: postDictationCooldown) { [weak self] in
                guard let self, case .armed = self.state,
                      let (users, attributed) = self.lastMicSnapshot else { return }
                self.considerStart(users, attributed: attributed)
            }
        }
    }

    private var lastMicSnapshot: ([MicActivityMonitor.MicUser], Bool)?

    // MARK: The single entry point

    func handle(_ signal: MeetingSignal) {
        expireCooldownIfDue()
        switch signal {
        case .micUsers(let users, let attributed):
            lastMicSnapshot = (users, attributed)
            handleMicUsers(users, attributed: attributed)
        case .appLaunched(let bundleID):
            // Set membership, deliberately: the old `facetime.contains(...)`
            // was String.contains — a SUBSTRING test that would have admitted
            // "com.apple" or any WhatsApp appex suffix once more IDs joined.
            if MeetingApps.native.contains(bundleID)
                || MeetingApps.personalCall.contains(bundleID) {
                launchedMeetingApps.insert(bundleID)
            }
            if case .pending = state, pendingTier2, !pendingCorroborated { corroborateTier2() }
        case .appTerminated(let bundleID):
            launchedMeetingApps.remove(bundleID)
            handleAppTerminated(bundleID)
        }
    }

    // MARK: Mic signal

    private func handleMicUsers(_ users: [MicActivityMonitor.MicUser], attributed: Bool) {
        // The exhausted latch clears the moment its holder lets go — a FRESH
        // mic acquisition deserves a fresh corroboration window.
        if attributed, let ex = exhaustedHolder,
           !users.contains(where: { sameHolder($0, ex) }) {
            exhaustedHolder = nil
        }

        switch state {
        case .armed:
            considerStart(users, attributed: attributed)

        case .pending(_, let holder):
            if pendingTier2, attributed {
                // Attribution recovered mid-window: the strict tier
                // supersedes the guess — and if the attributed list shows
                // the holder was never meeting-capable (Voice Memos), the
                // reconsideration correctly declines.
                abandonPending()
                considerStart(users, attributed: true)
            } else if holderActive(holder, in: users, attributed: attributed) {
                if pendingNeedsOutputDwell { trackOutputConcurrency(holder, in: users) }
                if pendingTier2, !pendingCorroborated { corroborateTier2() }
                probeIfDue()
                reevaluatePending()
            } else {
                abandonPending()
                considerStart(users, attributed: attributed)  // holder swap in one signal
            }

        case .capturing(_, let holder):
            checkMaxDuration()
            if !holderActive(holder, in: users, attributed: attributed) {
                enterStopPending()
            }

        case .stopPending(let inactiveSince):
            checkMaxDuration()
            guard let ctx = captureContext, !stopFired else { return }
            let resumed: MicActivityMonitor.MicUser?
            if deviceLevelHolder || !attributed {
                resumed = users.isEmpty ? nil : ctx.holder
            } else {
                resumed = users.first { sameHolder($0, ctx.holder) }
            }
            if let holder = resumed {
                // Same meeting resuming (AirPods came back) — restore the
                // ORIGINAL start so duration and the 4 h cap stay honest.
                captureContext = (ctx.since, holder)
                holderQuit = false
                transition(to: .capturing(since: ctx.since, holder: holder))
            } else {
                checkStopDeadline()   // shares the browser mute-defer path
            }

        case .disarmed, .cooldown:
            break
        }
    }

    private func handleAppTerminated(_ bundleID: String) {
        func matches(_ holder: MicActivityMonitor.MicUser) -> Bool {
            if holder.bundleID == bundleID { return true }
            guard let hb = holder.bundleID,
                  let hBrowser = MeetingApps.browserFor(bundleID: hb),
                  let tBrowser = MeetingApps.browserFor(bundleID: bundleID) else { return false }
            return hBrowser == tBrowser
        }
        switch state {
        case .pending(_, let holder) where matches(holder):
            abandonPending()
        case .capturing(_, let holder) where matches(holder):
            // A dead process cannot hold the mic — enter the countdown now
            // rather than waiting for the monitor to confirm the release.
            holderQuit = true
            enterStopPending()
        case .stopPending(let inactiveSince):
            guard let ctx = captureContext, matches(ctx.holder) else { return }
            holderQuit = true   // accelerates the running countdown to 5 s
            if now().timeIntervalSince(inactiveSince) >= currentStopDelay {
                fireStop(.appQuit)
            } else {
                schedule(after: inactiveSince.addingTimeInterval(currentStopDelay)
                    .timeIntervalSince(now())) { [weak self] in self?.checkStopDeadline() }
            }
        default:
            break
        }
    }

    // MARK: Start path

    private func considerStart(_ users: [MicActivityMonitor.MicUser], attributed: Bool) {
        guard case .armed = state, !dictationSuppressed else { return }

        if attributed {
            let enabled = enabledPersonalCallApps()
            let candidates = users.filter { u in
                guard let b = u.bundleID else { return false }
                if let ex = exhaustedHolder, sameHolder(u, ex) { return false }
                return MeetingApps.isMeetingCapable(bundleID: b,
                                                    enabledPersonalCalls: enabled)
            }
            // A native app holding the mic IS a call; a browser holding it
            // might be — prefer certainty when both hold at once.
            guard let holder = candidates.first(where: {
                $0.bundleID.flatMap { MeetingApps.browserFor(bundleID: $0) } == nil
            }) ?? candidates.first, let bundleID = holder.bundleID else { return }

            let isBrowser = MeetingApps.browserFor(bundleID: bundleID) != nil
            let needsOutputDwell = MeetingApps.outputCorroboration.contains(bundleID)
            pendingTier2 = false
            deviceLevelHolder = false
            pendingNeedsOutputDwell = needsOutputDwell
            // A holder already emitting output when it grabs the mic starts
            // its dwell clock immediately (ringback counts).
            outputConcurrentAccum = 0
            lastOutputConcurrentAt = (needsOutputDwell && holder.runningOutput) ? now() : nil
            pendingCorroborated = !isBrowser && !needsOutputDwell
            startFired = false
            probeInFlightGen = nil
            lastProbeAt = .distantPast
            pendingTrigger = MeetingTrigger(
                kind: isBrowser ? .autoBrowser : .autoApp,
                bundleID: bundleID,
                appName: MeetingApps.displayName(forBundleID: bundleID))
            transition(to: .pending(since: now(), holder: holder))
            if needsOutputDwell {
                corroborateOutputDwell()
            } else {
                probeIfDue()
            }
            tryFireStart()   // evals may set sustainSeconds = 0
        } else {
            guard let holder = users.first else { return }
            pendingTier2 = true
            deviceLevelHolder = true
            pendingCorroborated = false
            startFired = false
            probeInFlightGen = nil
            lastProbeAt = .distantPast
            pendingTrigger = nil
            transition(to: .pending(since: now(), holder: holder))
            corroborateTier2()
        }
    }

    /// Tier-2 corroboration: device-level mic activity means nothing by
    /// itself — require a native meeting app running (or a browser probe
    /// hit). This tier accepts the Teams-idle false positive: a native app
    /// merely running in the background while the user holds an unrelated
    /// call will trigger. Acceptable only here, where attribution is gone.
    private func corroborateTier2() {
        guard case .pending = state, !pendingCorroborated else { return }
        // Output-dwell apps are excluded: without attribution we cannot see
        // input+output concurrency, and "anonymous mic + WhatsApp merely
        // running" would fire on every voice note with the toggle on.
        let nativeSet = MeetingApps.native.union(
            enabledPersonalCallApps().subtracting(MeetingApps.outputCorroboration))
        if let b = launchedMeetingApps.union(runningApps()).first(where: nativeSet.contains) {
            pendingCorroborated = true
            pendingTrigger = MeetingTrigger(kind: .autoApp, bundleID: b,
                                            appName: MeetingApps.displayName(forBundleID: b))
            tryFireStart()
        } else {
            probeIfDue()
        }
    }

    private func probeIfDue() {
        // Output-dwell holders never browser-probe: a Meet tab open in some
        // window must not corroborate a WhatsApp voice note.
        guard case .pending = state, !pendingCorroborated, !pendingNeedsOutputDwell,
              probeInFlightGen == nil,
              now().timeIntervalSince(lastProbeAt) >= browserReprobeInterval else { return }
        lastProbeAt = now()
        let gen = generation
        probeInFlightGen = gen
        browserProbe { [weak self] hit in
            Task { @MainActor [weak self] in self?.probeDidReturn(hit, gen: gen) }
        }
    }

    private func probeDidReturn(_ hit: Bool, gen: UInt64) {
        if probeInFlightGen == gen { probeInFlightGen = nil }
        guard gen == generation, case .pending(let since, let holder) = state,
              !pendingCorroborated else { return }
        if hit {
            pendingCorroborated = true
            if pendingTier2 {
                // The probe knows a meeting tab is visible, not which
                // browser holds the mic; "" appName is the contract's
                // unknown value (MeetingRecord.appName).
                pendingTrigger = MeetingTrigger(
                    kind: .autoBrowser, bundleID: holder.bundleID,
                    appName: holder.bundleID.map { MeetingApps.displayName(forBundleID: $0) } ?? "")
            }
            tryFireStart()
        } else if now().timeIntervalSince(since) + browserReprobeInterval < corroborationWindow {
            schedule(after: browserReprobeInterval) { [weak self] in self?.probeIfDue() }
        }
    }

    /// WhatsApp-style corroboration (ADR 33): the pending holder counts as a
    /// call only after mic input AND audio output ran concurrently for
    /// personalCallOutputDwell. Both edges are polled snapshots from
    /// MicActivityMonitor; the timer here only re-derives from now(), same
    /// as every other threshold.
    private func trackOutputConcurrency(_ holder: MicActivityMonitor.MicUser,
                                        in users: [MicActivityMonitor.MicUser]) {
        guard !pendingCorroborated else { return }
        // Output silent right now: pause accumulating, never discard it.
        guard users.first(where: { sameHolder($0, holder) })?.runningOutput ?? false else { return }
        let t = now()
        if let last = lastOutputConcurrentAt {
            let gap = t.timeIntervalSince(last)
            // A long silence between sightings is a different event, not a
            // continuing call — start the run over.
            outputConcurrentAccum = gap > outputConcurrencyGapReset ? 0 : outputConcurrentAccum + gap
        }
        lastOutputConcurrentAt = t
        corroborateOutputDwell()
    }

    private func corroborateOutputDwell() {
        guard case .pending(_, let holder) = state, pendingNeedsOutputDwell,
              !pendingCorroborated, lastOutputConcurrentAt != nil else { return }
        if outputConcurrentAccum >= personalCallOutputDwell {
            pendingCorroborated = true
            tryFireStart()
            return
        }
        // No new snapshot may ever arrive — the monitor publishes on CHANGE,
        // and a steady call changes nothing. Re-derive from the last snapshot
        // when the remaining dwell elapses; an unchanged snapshot IS evidence
        // the holder still has both streams open.
        schedule(after: personalCallOutputDwell - outputConcurrentAccum) { [weak self] in
            guard let self, case .pending = self.state,
                  let (users, attributed) = self.lastMicSnapshot, attributed else { return }
            self.trackOutputConcurrency(holder, in: users)
        }
    }

    /// Every path that could complete the start funnel converges here and
    /// re-derives from now() — timer fires, probe hits, and eval-driven
    /// handle() calls all reach the same decision without waiting.
    private func tryFireStart() {
        guard case .pending(let since, _) = state, !startFired, pendingCorroborated,
              let trigger = pendingTrigger, !dictationSuppressed,
              now().timeIntervalSince(since) >= sustainSeconds else { return }
        startFired = true
        Log.info("MeetingDetection: start (\(trigger.appName), \(trigger.kind.rawValue))")
        onShouldStart?(trigger)
    }

    private func reevaluatePending() {
        guard case .pending(let since, let holder) = state else { return }
        if !pendingCorroborated,
           now().timeIntervalSince(since) >= corroborationWindow {
            // Held the mic for the whole window with no corroboration: latch
            // this holder out until it releases, or we'd probe it forever.
            Log.info("MeetingDetection: corroboration window expired, holder latched")
            exhaustedHolder = holder
            abandonPending()
            return
        }
        tryFireStart()
    }

    private func abandonPending() {
        resetDetectionScratch()
        transition(to: .armed)
    }

    private func resetDetectionScratch() {
        pendingCorroborated = false
        pendingTier2 = false
        pendingTrigger = nil
        pendingNeedsOutputDwell = false
        outputConcurrentAccum = 0
        lastOutputConcurrentAt = nil
        startFired = false
        stopFired = false
        holderQuit = false
        deviceLevelHolder = false
        probeInFlightGen = nil
        lastProbeAt = .distantPast
        stopDeferLogged = false
    }

    // MARK: Stop path

    private func enterStopPending() {
        guard !stopFired else { return }
        transition(to: .stopPending(inactiveSince: now()))
    }

    private func checkStopDeadline() {
        guard case .stopPending(let inactiveSince) = state, !stopFired,
              now().timeIntervalSince(inactiveSince) >= currentStopDelay else { return }
        // Browser mute-defer: a quit process can't be a mute, and past the
        // bounded hold mic-idle wins even with a matching tab still open.
        if !holderQuit,
           let ctx = captureContext, let b = ctx.holder.bundleID,
           MeetingApps.browserFor(bundleID: b) != nil,
           now().timeIntervalSince(inactiveSince) < browserMuteHold {
            guard probeInFlightGen == nil else { return }   // answer pending — wait, don't fire
            let gen = generation
            probeInFlightGen = gen
            browserProbe { [weak self] hit in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.probeInFlightGen == gen { self.probeInFlightGen = nil }
                    guard self.generation == gen, case .stopPending = self.state,
                          !self.stopFired else { return }
                    if hit {
                        if !self.stopDeferLogged {
                            self.stopDeferLogged = true
                            Log.info("MeetingDetection: mic idle but meeting tab still open — deferring stop (mute?)")
                        }
                        self.schedule(after: self.browserReprobeInterval * 2) { [weak self] in
                            self?.checkStopDeadline()
                        }
                    } else {
                        self.fireStop(.micIdle)
                    }
                }
            }
            return
        }
        fireStop(holderQuit ? .appQuit : .micIdle)
    }

    private func checkMaxDuration() {
        guard let ctx = captureContext, !stopFired,
              now().timeIntervalSince(ctx.since) >= maxMeetingSeconds else { return }
        fireStop(.maxDuration)
    }

    private func fireStop(_ reason: MeetingStopReason) {
        stopFired = true
        Log.info("MeetingDetection: stop (\(reason.rawValue))")
        onShouldStop?(reason)
        // State moves on when MeetingCenter reports back via meetingWasStopped.
    }

    // MARK: Holder identity

    private func holderActive(_ holder: MicActivityMonitor.MicUser,
                              in users: [MicActivityMonitor.MicUser],
                              attributed: Bool) -> Bool {
        // Unattributed snapshot, or a holder we never could attribute:
        // any activity counts. Fail open on the monitor degrading
        // mid-meeting — a spurious stop loses the transcript's tail;
        // over-capturing loses 30 s of silence.
        if deviceLevelHolder || !attributed { return !users.isEmpty }
        return users.contains { sameHolder($0, holder) }
    }

    /// Same pid, or same RESOLVED browser: Chrome renders each Meet call in
    /// helper processes whose pids churn across route changes, so the
    /// browser identity, not the pid, is the stable name of a browser call.
    private func sameHolder(_ a: MicActivityMonitor.MicUser,
                            _ b: MicActivityMonitor.MicUser) -> Bool {
        if a.pid == b.pid { return true }
        guard let ab = a.bundleID, let bb = b.bundleID,
              let aBrowser = MeetingApps.browserFor(bundleID: ab),
              let bBrowser = MeetingApps.browserFor(bundleID: bb) else { return false }
        return aBrowser == bBrowser
    }

    // MARK: Transitions and timers

    private func expireCooldownIfDue() {
        if case .cooldown(let until) = state, now() >= until {
            transition(to: .armed)
        }
    }

    /// Every transition bumps the generation, killing all timers of the old
    /// state; the new state schedules only what it needs. Timer bodies
    /// re-derive from now() so a scripted clock plus direct handle() calls
    /// reach identical decisions without any wall-clock waiting.
    private func transition(to newState: State) {
        generation &+= 1
        state = newState
        onStateChange?(newState)
        switch newState {
        case .pending(let since, _):
            schedule(after: since.addingTimeInterval(sustainSeconds)
                .timeIntervalSince(now())) { [weak self] in self?.reevaluatePending() }
            if !pendingCorroborated {
                schedule(after: since.addingTimeInterval(corroborationWindow)
                    .timeIntervalSince(now())) { [weak self] in self?.reevaluatePending() }
            }
        case .capturing(let since, _):
            schedule(after: since.addingTimeInterval(maxMeetingSeconds)
                .timeIntervalSince(now())) { [weak self] in self?.checkMaxDuration() }
        case .stopPending(let inactiveSince):
            schedule(after: inactiveSince.addingTimeInterval(currentStopDelay)
                .timeIntervalSince(now())) { [weak self] in self?.checkStopDeadline() }
            if let ctx = captureContext {   // the 4 h cap keeps counting here
                schedule(after: ctx.since.addingTimeInterval(maxMeetingSeconds)
                    .timeIntervalSince(now())) { [weak self] in self?.checkMaxDuration() }
            }
        case .cooldown(let until):
            schedule(after: until.timeIntervalSince(now())) { [weak self] in
                self?.expireCooldownIfDue()
            }
        case .disarmed, .armed:
            break
        }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                body()
            }
        }
    }
}
