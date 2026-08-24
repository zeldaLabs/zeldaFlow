import Foundation

/// Registry of what counts as a meeting app. Pure data + string matching —
/// the detection engine, process monitor and browser probe all consult this
/// one table, so supporting a new app is a one-file change.
enum MeetingApps {
    /// Native meeting clients. Ported: meetingProcessDetector.js:7-13
    /// (BUNDLE_ID_MAP, minus FaceTime which is gated below). Teams appears
    /// twice because the classic Electron client and "new Teams" ship under
    /// different bundle IDs and can be installed side by side.
    static let native: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
    ]

    /// FaceTime is a personal call, not usually a meeting anyone wants notes
    /// of — opt-in via settings.meetingDetectFaceTime, default OFF. OpenWhispr
    /// reached the same conclusion the hard way: its engine demoted process
    /// detections to context-only specifically to stop FaceTime false
    /// positives (meetingDetectionEngine.js:50-51).
    static let facetime = "com.apple.FaceTime"

    /// WhatsApp Desktop (Mac Catalyst). Verified 2026-08: call audio plays in
    /// the MAIN process — the WebRTC/libopus stack is in SharedModules.framework
    /// loaded by the main executable — so exact bundle-ID equality is the whole
    /// attribution story, and it naturally excludes the persistent
    /// .Intents/.ServiceExtension appexes and Sparkle XPCs (ADR 33).
    static let whatsapp = "net.whatsapp.WhatsApp"

    /// Personal-call apps: each opt-in behind its own settings toggle,
    /// default OFF — the FaceTime rationale above, generalized.
    static let personalCall: Set<String> = [facetime, whatsapp]

    /// Personal-call apps whose mic-in-use alone must NOT read as a call:
    /// WhatsApp's mic also records voice notes and camera videos. The call
    /// signature is mic input AND audio output on the same process, sustained
    /// (MeetingDetectionEngine.personalCallOutputDwell). FaceTime is absent
    /// deliberately — its mic use is only ever a call, and its shipped
    /// detection path must not change.
    static let outputCorroboration: Set<String> = [whatsapp]

    /// Browsers whose windows can host the Meet/Zoom/Teams/Webex web clients.
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
    ]

    /// Window-title fragments that mark a browser window's active tab as a
    /// meeting. Both "Meet – " (en dash — what Google actually emits) and
    /// "Meet - " (hyphen) are listed because the title separator differs by
    /// browser; " | Zoom" is the web client's tab-title suffix.
    static let browserTitlePatterns = [
        "Meet – ", "Meet - ", "Google Meet", "Zoom Meeting",
        "Microsoft Teams", "Webex", " | Zoom",
    ]

    /// Prefix match, not equality: Chromium browsers open the mic from a
    /// helper ("com.google.Chrome.helper.renderer"), so per-process mic
    /// attribution reports the helper's bundle ID, never the browser's own.
    /// Safari is the extreme case: capture lives in WebKit's out-of-line GPU
    /// process, whose bundle ID ("com.apple.WebKit.GPU") shares no prefix
    /// with Safari's at all. Any WKWebView app spawns the same helpers, so
    /// this can misattribute a non-Safari embedder — safe because a browser
    /// holder never starts without a probe-corroborated meeting window title.
    static func browserFor(bundleID: String) -> String? {
        if bundleID.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        return browsers.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// Human name for the meeting record. Native names ported:
    /// meetingProcessDetector.js:15-20 (BUNDLE_APP_NAMES). For browsers the
    /// service is unknowable from the bundle ID alone, so the browser's own
    /// name is the honest answer; unknown IDs yield "" (MeetingRecord.appName
    /// documents "" as its unknown value).
    static func displayName(forBundleID id: String) -> String {
        switch id {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams", "com.microsoft.teams2": return "Microsoft Teams"
        case "com.cisco.webexmeetingsapp": return "Webex"
        case facetime: return "FaceTime"
        case whatsapp: return "WhatsApp"
        default: break
        }
        switch browserFor(bundleID: id) {
        case "com.google.Chrome": return "Chrome"
        case "com.apple.Safari": return "Safari"
        case "company.thebrowser.Browser": return "Arc"
        case "com.microsoft.edgemac": return "Edge"
        case "com.brave.Browser": return "Brave"
        case "org.mozilla.firefox": return "Firefox"
        case "com.vivaldi.Vivaldi": return "Vivaldi"
        default: return ""
        }
    }

    /// native ∪ (personal-call apps the user enabled) ∪ browsers-by-prefix.
    static func isMeetingCapable(bundleID: String,
                                 enabledPersonalCalls: Set<String>) -> Bool {
        if native.contains(bundleID) { return true }
        if enabledPersonalCalls.contains(bundleID) { return true }
        return browserFor(bundleID: bundleID) != nil
    }
}
