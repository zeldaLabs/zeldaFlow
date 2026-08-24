import AppKit
import ApplicationServices

/// Pull-based corroboration for browser meetings: does any running browser
/// have a window whose title matches MeetingApps.browserTitlePatterns? A
/// browser window's AX title is its active tab's title, so this catches
/// Meet/Zoom/Teams-on-the-web without tab-level AX (Safari doesn't expose
/// tabs' titles to AX, Chromium only behind a flag).
///
/// Known miss, accepted: a meeting in a *background* tab of a window whose
/// active tab is something else is invisible here — manual start covers it.
enum BrowserMeetingProbe {
    /// Same per-element cap as ScreenContext.axCallTimeout: the AX default is
    /// ~6 s per message to an unresponsive app, and a busy renderer answering
    /// slowly across a handful of windows would otherwise hold the probe for
    /// half a minute. 0.25 s bounds each hop.
    private static let axCallTimeout: Float = 0.25

    /// Dedicated serial queue (ScreenContext convention): AX attribute reads
    /// block on IPC to the target app and must never run on the main thread.
    /// Serial also single-files overlapping probes, so a browser that answers
    /// slowly can't stack concurrent walks against itself.
    private static let queue = DispatchQueue(label: "zeldaflow.meeting-browser-probe",
                                             qos: .utility)

    /// Async: walks the windows (kAXWindowsAttribute → kAXTitleAttribute) of
    /// running apps whose bundle ID is in MeetingApps.browsers; completion on
    /// the main queue.
    static func meetingTabVisible(completion: @escaping (Bool) -> Void) {
        queue.async {
            let found = meetingTabVisibleSync()
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// Synchronous variant for the detection engine's corroboration path,
    /// called ON the probe queue via the async wrapper — do not call from
    /// main (one hung browser can cost windows × 0.25 s).
    static func meetingTabVisibleSync() -> Bool {
        // Exact membership, not browserFor's prefix match: only the main
        // browser process registers with NSWorkspace and owns AX windows —
        // Chromium helpers hold the mic, not windows.
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, MeetingApps.browsers.contains(id) else { continue }
            if hasMeetingWindow(pid: app.processIdentifier, bundleID: id) { return true }
        }
        return false
    }

    private static func hasMeetingWindow(pid: pid_t, bundleID: String) -> Bool {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, axCallTimeout)
        var winsRef: CFTypeRef?
        // Without the Accessibility grant this returns .apiDisabled and the
        // probe degrades to "no" — same silent-failure posture as
        // ScreenContext, which the detection engine treats as inconclusive.
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else { return false }
        for window in windows {
            // The timeout doesn't transfer between refs — cap each one
            // (local token write, no IPC; ScreenContext does the same).
            AXUIElementSetMessagingTimeout(window, axCallTimeout)
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            if let hit = MeetingApps.browserTitlePatterns.first(where: { title.contains($0) }) {
                // Log the pattern, not the title — window titles carry
                // meeting names and zeldaFlow's log stays content-free.
                Log.info("BrowserMeetingProbe: '\(hit)' matched in \(MeetingApps.displayName(forBundleID: bundleID))")
                return true
            }
        }
        return false
    }
}
