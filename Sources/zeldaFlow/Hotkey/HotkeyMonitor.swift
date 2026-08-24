import Foundation
import AppKit
import CoreGraphics

@MainActor
protocol HotkeyMonitorDelegate: AnyObject {
    /// Fn went down while idle — try to start capturing immediately so the
    /// first syllable isn't clipped. Return false if no session could start
    /// (engine loading, mic missing…): the monitor then reverts to idle
    /// instead of leaving a phantom session armed.
    ///
    /// Must return promptly. It runs on the main actor, and the gesture the
    /// user is in the middle of is waiting on it.
    func hotkeySessionShouldBegin() -> Bool
    /// Fn released after a hold >= minHoldSeconds: finish push-to-talk.
    func hotkeyHoldEnded()
    /// Short tap with no second tap following: discard the buffered audio.
    func hotkeyTapDiscarded()
    /// Double-tap detected: hands-free mode is now on (keep recording).
    func hotkeyHandsFreeStarted()
    /// While hands-free, Fn pressed again: stop and transcribe.
    func hotkeyHandsFreeEnded()
    /// Triple-tap detected: the session upgraded to command mode.
    func hotkeyCommandModeStarted()
    /// While in command mode, Fn pressed again: stop and run the command.
    func hotkeyCommandEnded()
    /// A confirmation is pending and the user tapped Fn to approve it.
    func confirmationApproved()
    /// A confirmation is pending and the user pressed Esc to cancel it.
    func confirmationCancelled()
    /// Another key was pressed while Fn was held (fn+arrow etc.) — cancel.
    func hotkeySessionDirtied()
    /// Esc pressed while a session or the type bar was live.
    func escapePressed()
}

/// What the state machine decided should happen. The tap callback produces
/// these and hands them to the main actor; it never calls the delegate
/// itself — see the threading note on `HotkeyMonitor`.
private enum HotkeyEffect: Sendable {
    case begin(attempt: Int)
    case holdEnded
    case tapDiscarded
    case handsFreeStarted
    case handsFreeEnded
    case commandModeStarted
    case commandEnded
    case confirmationApproved
    case confirmationCancelled
    case sessionDirtied
    case escapePressed
}

/// Suppressing CGEventTap for the Fn/Globe key.
///
/// Fn produces `.flagsChanged` with keyCode 63 and toggles `.maskSecondaryFn`.
/// Returning nil from the tap swallows the event before HIToolbox sees it, so
/// macOS's own globe action (emoji picker / input source / dictation) never
/// fires. Requires Accessibility permission.
///
/// ## Why the tap has its own thread, and why the callback does no work
///
/// An active head-insert tap sits in front of the whole system's keyboard
/// stream: while its callback runs, *nobody* gets key events, and if the
/// callback overruns macOS's timeout the OS rips the tap out entirely
/// (`.tapDisabledByTimeout`).
///
/// Both used to happen here. The tap's run-loop source was on the **main**
/// run loop and the callback called the delegate **synchronously** — so
/// pressing Fn ran `AudioRecorder.start()` inside the callback. Measured on
/// this machine: 610 ms to build the voice-processing graph plus 218 ms for
/// `engine.start()`, **845 ms cold** (64 ms warm, which is why it only
/// misbehaved "sometimes" — the graph is kept warm for two minutes after a
/// dictation, so only the first press after a pause paid it). For that whole
/// time the keyboard was stalled, a second press landed in the dead window
/// and was lost, and a system under load tipped past the timeout and left the
/// tap disabled until the 5 s watchdog noticed.
///
/// So, two rules hold this file together:
///
///  1. The tap lives on its own `.userInteractive` thread with its own run
///     loop. Nothing the main thread is busy with can delay key handling.
///  2. The callback only reads flags, walks the state machine, and returns
///     the swallow decision — microseconds. Every delegate call is queued to
///     the main actor and happens after the event has already been answered.
///
/// Rule 2 is what forces the mirrors below (`sessionIsLive`, `typeBarIsOpen`,
/// `cachedBinding`): the two decisions the callback *must* make synchronously
/// — swallow this Esc? is a session really live? — used to be answered by
/// asking the main actor, which is exactly the round trip that cannot exist
/// on this path. The main actor pushes those answers in instead.
///
/// State touched from both sides lives under `lock`. The lock is never held
/// across a delegate call.
final class HotkeyMonitor: @unchecked Sendable {
    // Marker on our own synthetic events (Cmd-V) so the tap ignores them.
    // Read from the event-tap callback and TextInserter's off-main event
    // posting — an immutable constant, safe from any isolation.
    nonisolated static let syntheticEventMarker: Int64 = 0x4852_4249  // "HRBI"

    private enum State {
        case idle
        case fnHeld(since: Date, dirty: Bool)
        case awaitingSecondTap(generation: Int)
        case handsFree(armedAt: Date)
        case command
    }

    @MainActor weak var delegate: (any HotkeyMonitorDelegate)?
    /// Fired on the main actor when the watchdog recovers a tap that failed
    /// to install at launch, so the UI can clear its "hotkey dead" warning.
    @MainActor var onTapInstalled: (() -> Void)?

    /// Guards everything the tap thread and the main actor both touch.
    private let lock = NSLock()

    // MARK: Lock-guarded state
    private var state: State = .idle
    private var tapGeneration = 0
    /// Bumped on every idle→held transition so a failed start only unwinds
    /// the press that actually failed.
    private var beginAttempt = 0
    /// While true, a bare hotkey tap approves a pending confirmation and Esc
    /// cancels it — the tap swallows both so nothing leaks to the app.
    private var confirming = false
    /// While the user is picking a new key in Settings the tap must stand
    /// down completely: otherwise it swallows the very keypress the recorder
    /// is waiting for (and would start a dictation instead).
    private var suspended = false
    /// Normal keys auto-repeat while held, which would look like a storm of
    /// presses; we only care about the first down and the up.
    private var normalKeyIsDown = false
    /// The bound key. Cached rather than read from `AppSettings` per event:
    /// settings are `@Published` and main-actor-owned, and the callback is
    /// not on the main actor any more.
    private var cachedBinding: HotkeyBinding = .fn
    /// Mirrors of `AppState.phase`, pushed in by `phaseChanged` — see the
    /// class note on why the callback can't ask for these.
    private var sessionIsLive = false
    private var typeBarIsOpen = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The watchdog retries on a 5 s tick; without this the log would gain a
    /// tapCreate error every tick for as long as permission is missing.
    private var loggedTapFailure = false

    // MARK: Tap thread
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapThreadReady = DispatchSemaphore(value: 0)

    /// Gesture timers run here, not on main: a discard that fires late
    /// because the main thread was busy is the same bug this file exists to
    /// remove.
    private static let timerQueue = DispatchQueue(
        label: "com.zeldalabs.zeldaflow.hotkey-timer", qos: .userInteractive)

    private var watchdog: Timer?

    // Forgiving gesture timing: a "tap" is any press under 0.3 s, and the
    // second tap of a double-tap may come up to 0.6 s later. (The original
    // 0.25/0.35 s made hands-free nearly impossible to arm at normal speed.)
    private let minHoldSeconds: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.6
    /// A third tap this soon after hands-free armed upgrades to command mode.
    private let commandUpgradeWindow: TimeInterval = 0.6

    private let escKeyCode: Int64 = 53

    var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    var isSuspended: Bool {
        get { lock.lock(); defer { lock.unlock() }; return suspended }
        set { lock.lock(); suspended = newValue; lock.unlock() }
    }

    /// Start the monitor: create the tap now if possible, and keep a watchdog
    /// running that re-enables a disabled tap, reinstalls a dead one, and —
    /// if Accessibility isn't granted yet (or was revoked) — retries
    /// installation automatically once it is.
    @MainActor
    @discardableResult
    func install() -> Bool {
        updateBinding(AppSettings.shared.hotkey)
        startTapThread()
        startWatchdog()
        return createTap()
    }

    @MainActor
    func uninstall() {
        watchdog?.invalidate()
        watchdog = nil
        teardownTap()
        stopTapThread()
        lock.lock(); state = .idle; lock.unlock()
    }

    /// Enter/leave confirmation mode (AppState drives this around a pending
    /// send-email / send-message confirmation).
    func beginConfirmation() { lock.lock(); confirming = true; lock.unlock() }
    func endConfirmation() { lock.lock(); confirming = false; lock.unlock() }

    /// The bound key changed in Settings. Takes effect on the next event —
    /// no need to tear the tap down.
    func updateBinding(_ binding: HotkeyBinding) {
        lock.lock(); cachedBinding = binding; lock.unlock()
    }

    /// AppState mirrors its phase here on every change, so the tap thread can
    /// answer "is a session actually live?" and "should this Esc be
    /// swallowed?" without a round trip to the main actor.
    func phaseChanged(recording: Bool, typeBarOpen: Bool) {
        lock.lock()
        sessionIsLive = recording
        typeBarIsOpen = typeBarOpen
        lock.unlock()
    }

    /// Programmatic hands-free toggle (menu item).
    @MainActor
    func toggleHandsFreeFromMenu() {
        lock.lock()
        let current = state
        lock.unlock()

        switch current {
        case .handsFree:
            lock.lock(); state = .idle; lock.unlock()
            delegate?.hotkeyHandsFreeEnded()
        case .idle:
            // Only arm hands-free if a session actually started.
            guard delegate?.hotkeySessionShouldBegin() == true else { return }
            lock.lock(); state = .handsFree(armedAt: Date()); lock.unlock()
            delegate?.hotkeyHandsFreeStarted()
        default:
            break
        }
    }

    /// Programmatic command-mode start (menu item).
    @MainActor
    func startCommandFromMenu() {
        lock.lock()
        guard case .idle = state else { lock.unlock(); return }
        lock.unlock()

        guard delegate?.hotkeySessionShouldBegin() == true else { return }
        lock.lock(); state = .command; lock.unlock()
        delegate?.hotkeyCommandModeStarted()
    }

    /// Called by AppState when a session ends for reasons the monitor didn't
    /// initiate (error, max duration, Esc, mic hot-swap) so our state doesn't
    /// go stale.
    func sessionWasReset() {
        lock.lock()
        state = .idle
        // Cancel any pending double-tap discard: that session is gone.
        tapGeneration += 1
        lock.unlock()
    }

    // MARK: - Tap thread

    /// A run loop of our own, so a busy main thread can never delay — or
    /// time out — the system's keyboard stream.
    private func startTapThread() {
        guard tapThread == nil else { return }
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            // A port with no traffic is what keeps the run loop from
            // returning immediately when the tap source isn't attached yet.
            RunLoop.current.add(NSMachPort(), forMode: .common)
            self.tapThreadReady.signal()
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.zeldalabs.zeldaflow.hotkey-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        // The run loop must exist before install() can attach a source to it.
        // Bounded: this runs on main at launch, and a hang here would be a
        // worse bug than the one this file is fixing. createTap() falls back
        // to the main run loop if the thread never showed up.
        if tapThreadReady.wait(timeout: .now() + 2) == .timedOut {
            Log.error("HotkeyMonitor: tap thread didn't come up within 2s")
        }
    }

    private func stopTapThread() {
        tapThread?.cancel()
        lock.lock()
        let rl = tapRunLoop
        tapRunLoop = nil
        lock.unlock()
        if let rl { CFRunLoopWakeUp(rl) }  // let the cancelled thread notice
        tapThread = nil
    }

    // MARK: - Tap lifecycle

    private func createTap() -> Bool {
        lock.lock()
        let alreadyInstalled = tap != nil
        lock.unlock()
        guard !alreadyInstalled else { return true }

        // keyUp is needed too: a non-modifier binding (F13, caps lock…)
        // reports its release there rather than through flagsChanged.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // The watchdog retries every 5 s until the user grants access, so
            // log the failure once rather than filling the log with it.
            lock.lock()
            let shouldLog = !loggedTapFailure
            loggedTapFailure = true
            lock.unlock()
            if shouldLog {
                Log.error("HotkeyMonitor: tapCreate failed (Accessibility not granted?) — "
                          + "retrying every 5s, will log again once it succeeds")
            }
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        lock.lock()
        loggedTapFailure = false
        tap = newTap
        runLoopSource = source
        let rl = tapRunLoop
        lock.unlock()

        // Attaching to the tap thread's run loop — not the main one — is the
        // whole point; see the class note.
        if let rl {
            CFRunLoopAddSource(rl, source, .commonModes)
            CFRunLoopWakeUp(rl)
        } else {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            Log.error("HotkeyMonitor: tap thread missing — falling back to the main run loop")
        }
        CGEvent.tapEnable(tap: newTap, enable: true)
        Log.info("HotkeyMonitor: event tap installed on its own run loop")
        return true
    }

    private func teardownTap() {
        lock.lock()
        let source = runLoopSource
        let oldTap = tap
        let rl = tapRunLoop
        runLoopSource = nil
        tap = nil
        lock.unlock()

        if let source {
            CFRunLoopRemoveSource(rl ?? CFRunLoopGetMain(), source, .commonModes)
        }
        if let oldTap {
            CGEvent.tapEnable(tap: oldTap, enable: false)
        }
    }

    // MARK: - Event handling
    //
    // Runs on the tap thread. Everything here is non-blocking by
    // construction: no delegate calls, no settings reads, no allocation
    // beyond a tiny effects array. See the class note.

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let current = tap; lock.unlock()
            if let current { CGEvent.tapEnable(tap: current, enable: true) }
            // Worth knowing about: with a non-blocking callback a timeout
            // should now be impossible, so one in the log means something
            // else on this thread is stalling.
            Log.error("HotkeyMonitor: tap disabled by "
                      + (type == .tapDisabledByTimeout ? "timeout" : "user input")
                      + " — re-enabled")
            return nil
        }

        var effects: [HotkeyEffect] = []
        var swallow = false

        lock.lock()
        if suspended {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let binding = cachedBinding

        switch type {
        case .flagsChanged:
            guard binding.isModifier,
                  event.getIntegerValueField(.keyboardEventKeycode) == binding.keyCode else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            // For a modifier, "down" means our flag is now set. Left/right
            // variants share a flag, so also require the keycode match above —
            // that's what keeps left ⌥ usable when right ⌥ is the hotkey.
            let isDown = (event.flags.rawValue & binding.flagMask) != 0
            if confirming {
                // A tap (press edge) approves the pending send.
                if isDown { effects.append(.confirmationApproved) }
            } else {
                effects = transition(down: isDown)
            }
            // Always swallow bare transitions of the bound key: this is what
            // prevents the system action (globe/emoji for Fn). Combos still
            // work — those events carry the modifier flag themselves.
            swallow = true

        case .keyUp:
            guard !binding.isModifier,
                  event.getIntegerValueField(.keyboardEventKeycode) == binding.keyCode else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
            normalKeyIsDown = false
            if !confirming { effects = transition(down: false) }
            swallow = true

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
                lock.unlock()
                return Unmanaged.passUnretained(event)  // our own Cmd-V
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // A non-modifier binding arrives here rather than in flagsChanged.
            if !binding.isModifier, keyCode == binding.keyCode {
                // Ignore auto-repeat: holding the key must read as one press.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !normalKeyIsDown {
                    normalKeyIsDown = true
                    if confirming {
                        effects.append(.confirmationApproved)
                    } else {
                        effects = transition(down: true)
                    }
                }
                swallow = true
            } else if keyCode == escKeyCode {
                if confirming {
                    effects.append(.confirmationCancelled)
                    swallow = true
                } else if sessionIsLive || typeBarIsOpen {
                    // Answered from the mirror rather than by asking the main
                    // actor — the round trip is what this file can't do.
                    state = .idle
                    effects.append(.escapePressed)
                    swallow = true
                }
            } else if case .fnHeld(let since, let dirty) = state, !dirty {
                // fn+arrow / fn+delete etc: user wants the combo, not dictation.
                state = .fnHeld(since: since, dirty: true)
                effects.append(.sessionDirtied)
            }

        default:
            break
        }
        lock.unlock()

        deliver(effects)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// The gesture state machine. Caller holds `lock`; returns what the main
    /// actor should do about it.
    private func transition(down: Bool) -> [HotkeyEffect] {
        let now = Date()
        switch (state, down) {
        case (.idle, true):
            // Optimistic: arm the hold now and let the main actor confirm.
            // Waiting for the answer is what used to stall the keyboard for
            // up to 845 ms; `failedToBegin` unwinds it if the session can't
            // actually start.
            beginAttempt += 1
            state = .fnHeld(since: now, dirty: false)
            return [.begin(attempt: beginAttempt)]

        case (.awaitingSecondTap, true):
            // Second tap inside the window. Recording has been running since
            // the first tap — but only arm hands-free if it's actually live.
            tapGeneration += 1
            if sessionIsLive {
                state = .handsFree(armedAt: now)
                return [.handsFreeStarted]
            }
            // Nothing recording (session failed to start): treat this press
            // as a fresh attempt.
            state = .idle
            return transition(down: true)

        case (.handsFree(let armedAt), true):
            if now.timeIntervalSince(armedAt) < commandUpgradeWindow {
                // Third tap of a rapid triple-tap: upgrade the running
                // session to command mode. (Stopping hands-free this soon
                // after arming it would be meaningless anyway.)
                state = .command
                return [.commandModeStarted]
            }
            // Press while hands-free: stop and transcribe.
            state = .idle
            return [.handsFreeEnded]

        case (.command, true):
            // Press while in command mode: stop and run the command.
            state = .idle
            return [.commandEnded]

        case (.fnHeld(let since, let dirty), false):
            if dirty {
                state = .idle
                return []
            }
            if now.timeIntervalSince(since) >= minHoldSeconds {
                state = .idle
                return [.holdEnded]
            }
            // Might be the first tap of a double-tap: wait before discarding.
            tapGeneration += 1
            let generation = tapGeneration
            state = .awaitingSecondTap(generation: generation)
            Self.timerQueue.asyncAfter(deadline: .now() + doubleTapWindow) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard case .awaitingSecondTap(let g) = self.state, g == generation else {
                    self.lock.unlock()
                    return
                }
                self.state = .idle
                self.lock.unlock()
                self.deliver([.tapDiscarded])
            }
            return []

        case (.handsFree, false), (.command, false), (.awaitingSecondTap, false),
             (.idle, false), (.fnHeld, true):
            return []  // release edges we don't act on / duplicate transitions
        }
    }

    /// Test seam for `--evalhotkey`: feed an event down the exact path the
    /// tap thread uses, and report whether it was swallowed. The non-blocking
    /// guarantee in the class note is only worth anything if something keeps
    /// measuring it.
    func handleForEval(type: CGEventType, event: CGEvent) -> Bool {
        handle(type: type, event: event) == nil
    }

    /// The session couldn't start after all — unwind the press that armed it,
    /// unless something newer has already moved the machine on.
    private func failedToBegin(attempt: Int) {
        lock.lock()
        if beginAttempt == attempt {
            state = .idle
            normalKeyIsDown = false
            tapGeneration += 1  // cancel a pending double-tap discard
        }
        lock.unlock()
    }

    // MARK: - Delivering effects to the main actor

    private func deliver(_ effects: [HotkeyEffect]) {
        guard !effects.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let delegate = self.delegate else { return }
                for effect in effects {
                    self.apply(effect, to: delegate)
                }
            }
        }
    }

    @MainActor
    private func apply(_ effect: HotkeyEffect, to delegate: any HotkeyMonitorDelegate) {
        switch effect {
        case .begin(let attempt):
            if !delegate.hotkeySessionShouldBegin() { failedToBegin(attempt: attempt) }
        case .holdEnded:            delegate.hotkeyHoldEnded()
        case .tapDiscarded:         delegate.hotkeyTapDiscarded()
        case .handsFreeStarted:     delegate.hotkeyHandsFreeStarted()
        case .handsFreeEnded:       delegate.hotkeyHandsFreeEnded()
        case .commandModeStarted:   delegate.hotkeyCommandModeStarted()
        case .commandEnded:         delegate.hotkeyCommandEnded()
        case .confirmationApproved: delegate.confirmationApproved()
        case .confirmationCancelled: delegate.confirmationCancelled()
        case .sessionDirtied:       delegate.hotkeySessionDirtied()
        case .escapePressed:        delegate.escapePressed()
        }
    }

    // MARK: - Watchdog
    // macOS silently disables taps under load and kills them when
    // Accessibility is revoked. The watchdog re-enables/reinstalls dead taps
    // (preserving in-flight session state) and retries installation once
    // Accessibility is (re-)granted. With the callback no longer blocking,
    // this is a backstop rather than the recovery path it used to be.

    @MainActor
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogTick()
            }
        }
    }

    @MainActor
    private func watchdogTick() {
        lock.lock(); let current = tap; lock.unlock()

        guard let current else {
            // Retry unconditionally rather than gating on AXIsProcessTrusted():
            // after a signature change macOS can report "trusted" while still
            // refusing the tap, and vice versa. The call is cheap; success is
            // the only signal that actually matters.
            if createTap() {
                Log.info("HotkeyMonitor: tap installed on retry")
                onTapInstalled?()
            }
            return
        }
        guard !CGEvent.tapIsEnabled(tap: current) else { return }
        Log.info("HotkeyMonitor: tap was disabled, re-enabling")
        CGEvent.tapEnable(tap: current, enable: true)
        guard !CGEvent.tapIsEnabled(tap: current) else { return }

        Log.error("HotkeyMonitor: re-enable failed, reinstalling tap")
        lock.lock(); let saved = state; lock.unlock()
        teardownTap()
        if createTap() {
            lock.lock(); state = saved; lock.unlock()  // don't kill a live session
        }
    }
}
