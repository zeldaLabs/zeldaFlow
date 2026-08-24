import AppKit
import ApplicationServices

/// Presses the Play button on the Music page that `open location` just
/// opened. Music's AppleScript `play` can only resume the existing queue —
/// it cannot start the page's track — so the only way to actually play a
/// catalog song is to press the page's own Play control, exactly like the
/// user would. Every press is verified against the expected track name;
/// a press that starts the wrong thing is paused and undone.
enum MusicUIDriver {
    private struct Candidate {
        let element: AXUIElement
        let label: String
        let y: CGFloat
        let inContent: Bool   // below the toolbar/transport strip
    }

    /// Press play-button candidates until the expected track is confirmed
    /// playing. Returns "Track — Artist" on success.
    static func pressPlayAndVerify(expected: String) async -> String? {
        var candidates = await Task.detached { collectCandidates() }.value
        if candidates.isEmpty {
            // Page may still be rendering (or the window was just reopened).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            candidates = await Task.detached { collectCandidates() }.value
        }
        Log.info("MusicUIDriver: \(candidates.count) play candidates: " +
                 candidates.prefix(6).map { "\($0.label)@\(Int($0.y))\($0.inContent ? "c" : "t")" }
                     .joined(separator: ", "))
        for candidate in candidates.prefix(4) {
            let err = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
            Log.info("MusicUIDriver: pressed \"\(candidate.label)\" (err \(err.rawValue))")
            guard err == .success else { continue }
            if let label = await AppleMusicCatalog.verifyPlaying(expected: expected, attempts: 5) {
                return label
            }
            // Wrong queue may have started — stop it before the next try.
            _ = await AppleScriptRunner.run("""
            tell application "Music"
                if player state is playing then pause
            end tell
            """)
        }
        return nil
    }

    // MARK: - AX walk

    private static func collectCandidates() -> [Candidate] {
        guard let music = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music").first else { return [] }
        let app = AXUIElementCreateApplication(music.processIdentifier)
        guard let windows: [AXUIElement] = copyValue(app, kAXWindowsAttribute) else {
            Log.info("MusicUIDriver: no AX windows (accessibility not granted?)")
            return []
        }

        var buttons: [(el: AXUIElement, label: String, y: CGFloat)] = []
        var everyLabel: [String] = []
        var visited = 0
        var windowTop: CGFloat = 0

        for window in windows {
            if let origin = position(of: window) { windowTop = origin.y }
            walk(window, depth: 0, visited: &visited) { el in
                guard role(of: el) == kAXButtonRole as String else { return }
                let label = self.label(of: el)
                if !label.isEmpty { everyLabel.append(label) }
                let l = label.lowercased()
                guard l == "play" || l.hasPrefix("play ") else { return }
                let y = position(of: el)?.y ?? 0
                buttons.append((el, label, y))
            }
        }

        if buttons.isEmpty {
            // Self-diagnosing: record what the tree actually contains so the
            // log tells us what to match next time.
            Log.info("MusicUIDriver: no Play button among \(everyLabel.count) labeled buttons: " +
                     everyLabel.prefix(30).joined(separator: " | "))
            return []
        }

        // The page's Play button sits in the content area; the transport
        // strip hugs the top of the window and only resumes the old queue.
        let contentThreshold = windowTop + 110
        return buttons
            .map { Candidate(element: $0.el, label: $0.label, y: $0.y,
                             inContent: $0.y >= contentThreshold) }
            .sorted { a, b in
                if a.inContent != b.inContent { return a.inContent }
                return a.y < b.y
            }
    }

    private static func walk(_ element: AXUIElement, depth: Int, visited: inout Int,
                             _ visit: (AXUIElement) -> Void) {
        guard depth < 30, visited < 8000 else { return }
        visited += 1
        visit(element)
        guard let children: [AXUIElement] = copyValue(element, kAXChildrenAttribute) else { return }
        for child in children {
            walk(child, depth: depth + 1, visited: &visited, visit)
        }
    }

    // MARK: - AX helpers

    private static func copyValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? T
    }

    private static func role(of el: AXUIElement) -> String {
        copyValue(el, kAXRoleAttribute) ?? ""
    }

    private static func label(of el: AXUIElement) -> String {
        if let d: String = copyValue(el, kAXDescriptionAttribute), !d.isEmpty { return d }
        if let t: String = copyValue(el, kAXTitleAttribute), !t.isEmpty { return t }
        return ""
    }

    private static func position(of el: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
