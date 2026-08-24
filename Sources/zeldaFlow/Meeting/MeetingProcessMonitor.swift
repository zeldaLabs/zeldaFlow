import AppKit

/// Launch/terminate tracking for the native meeting clients (Zoom, Teams,
/// Webex, FaceTime) — the port of the darwin path of OpenWhispr's
/// meetingProcessDetector.js (_startDarwin: the same two NSWorkspace
/// notifications instead of its 30 s polling fallback, plus an initial scan
/// of what is already running at start()).
///
/// Role: with per-process mic attribution this is no longer needed to
/// corroborate that a meeting exists. It survives for the auto-stop
/// accelerator — the triggering app quitting ends the meeting without the
/// 30 s mic-idle wait (MeetingStopReason.appQuit) — and for the eval, which
/// drives onLaunch/onTerminate directly.
final class MeetingProcessMonitor {
    /// Bundle ID of the app; both fire on the main queue (the observers are
    /// registered with `queue: .main`, matching the codebase's convention of
    /// main-queue callbacks for lifecycle events).
    var onLaunch: ((String) -> Void)?
    var onTerminate: ((String) -> Void)?

    /// Personal-call apps (FaceTime, WhatsApp) are always tracked here;
    /// whether their launch may *start* a meeting is the detection engine's
    /// call (their settings toggles). Keeping the monitor setting-free means
    /// flipping a toggle mid-run changes behavior instantly, with no monitor
    /// restart. Ported: meetingProcessDetector.js:7-13 also watches its full
    /// BUNDLE_ID_MAP unconditionally. Unlike the JS (which folds both Teams
    /// bundle IDs into one "teams" key) the set keeps bundle IDs distinct —
    /// the auto-stop accelerator must match the exact ID that triggered the
    /// meeting.
    private let watched = MeetingApps.native.union(MeetingApps.personalCall)
    private var observers: [NSObjectProtocol] = []
    private(set) var runningMeetingApps: Set<String> = []

    func start() {
        guard observers.isEmpty else { return }   // idempotent, like the JS start()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in self?.handle(note, running: true) })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in self?.handle(note, running: false) })

        // Initial scan (ported: _initialScanDarwin) — the notifications only
        // report transitions, so a Zoom that was already open when zeldaFlow
        // started would otherwise be invisible until it quit. Silent seed, no
        // onLaunch: nothing "happened", the world just already looked so.
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, watched.contains(id) {
                runningMeetingApps.insert(id)
            }
        }
        if !runningMeetingApps.isEmpty {
            Log.info("MeetingProcessMonitor: already running: \(runningMeetingApps.sorted().joined(separator: ", "))")
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
        runningMeetingApps = []
    }

    deinit { stop() }

    private func handle(_ note: Notification, running: Bool) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, watched.contains(id) else { return }
        // Transition-only, like _updateDetection (meetingProcessDetector.js:
        // 225-239): Zoom relaunches itself after updates and Teams respawns
        // processes under the same bundle ID — repeats must not re-fire.
        if running {
            guard runningMeetingApps.insert(id).inserted else { return }
            Log.info("MeetingProcessMonitor: launched \(id)")
            onLaunch?(id)
        } else {
            guard runningMeetingApps.remove(id) != nil else { return }
            Log.info("MeetingProcessMonitor: terminated \(id)")
            onTerminate?(id)
        }
    }
}
