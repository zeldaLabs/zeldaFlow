import AppKit

/// A snapshot of what's on screen, small enough to hand to a 4096-token model
/// every single step.
///
/// The size discipline is the whole point. Safari alone publishes 416 menu
/// commands; serialising them raw would fill the context before the goal was
/// even stated. So menus are filtered to what the *goal* plausibly needs
/// (UIMatcher does the ranking) and controls are capped. A realistic snapshot
/// lands around 130 tokens, which leaves the planner room to actually think.
struct TaskObservation {
    let appName: String
    let bundleID: String?
    let windowTitle: String?
    let controls: [UIControl]
    let menus: [MenuCommand]

    /// Read the frontmost app's current state, ranked against the goal.
    @MainActor
    static func capture(goal: String, maxControls: Int = 18, maxMenus: Int = 10)
        -> TaskObservation {
        let front = NSWorkspace.shared.frontmostApplication
        let name = front?.localizedName ?? "unknown"

        // Ours doesn't count: if zeldaFlow's own pill is frontmost there is
        // nothing to observe, and driving our own UI would be a loop.
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return TaskObservation(appName: name, bundleID: front?.bundleIdentifier,
                                   windowTitle: nil, controls: [], menus: [])
        }

        let controls = Array(UIControls.inFocusedWindow(of: front)
            .filter(\.enabled)
            .prefix(maxControls))

        // Rank the whole tree against the goal, then keep the top few. A menu
        // command the goal has no words in common with is noise here.
        let all = UIScout.menuCommands(for: front).filter(\.enabled)
        let ranked = UIMatcher.shortlist(for: goal, in: all, limit: maxMenus)

        return TaskObservation(appName: name, bundleID: front?.bundleIdentifier,
                               windowTitle: UIControls.focusedWindowTitle(of: front),
                               controls: controls, menus: ranked)
    }

    /// The compact form handed to the planner.
    func serialized(goal: String, step: Int, maxSteps: Int, history: [String]) -> String {
        var out = "GOAL: \(goal)\nSTEP: \(step) of \(maxSteps)\nAPP: \(appName)\n"
        if let t = windowTitle, !t.isEmpty { out += "WINDOW: \(t)\n" }

        if controls.isEmpty {
            out += "\nCONTROLS: (none visible)\n"
        } else {
            out += "\nCONTROLS:\n"
            for c in controls { out += "[\(c.kind)] \(c.label)\n" }
        }
        if !menus.isEmpty {
            out += "\nMENUS (relevant):\n"
            for m in menus { out += "\(m.path.joined(separator: " > "))\n" }
        }
        if !history.isEmpty {
            out += "\nDONE SO FAR:\n"
            // Only the recent past. Older steps stop being informative and the
            // budget is better spent on what's on screen right now.
            for (i, h) in history.suffix(6).enumerated() {
                out += "\(history.count - min(history.count, 6) + i + 1). \(h)\n"
            }
        }
        return out
    }

    /// Identity of the visible state, for detecting "nothing changed".
    ///
    /// Deliberately excludes the step number and history: two iterations that
    /// leave the screen identical must produce the same fingerprint, or a stuck
    /// loop looks like progress forever.
    var fingerprint: String {
        var s = "\(bundleID ?? appName)|\(windowTitle ?? "")|"
        s += controls.map { "\($0.kind):\($0.label)" }.joined(separator: ",")
        return s
    }

    /// True when there is genuinely nothing to act on — no controls and no
    /// menus. Usually means the app is still launching.
    var isEmpty: Bool { controls.isEmpty && menus.isEmpty }
}
