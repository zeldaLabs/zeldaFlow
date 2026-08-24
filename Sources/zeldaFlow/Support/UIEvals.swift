import AppKit
import ApplicationServices

/// Live check of the "do anything in any app" path: enumerate a real app's
/// menu commands, match spoken phrases against them, and actually press one.
///
/// Uses TextEdit — present on every Mac, safe to open and close, and it has
/// the ordinary File/Edit/Format menus most apps share. Quits it again unless
/// it was already running.
enum UIEvals {
    static func run() -> Int32 {
        print("zeldaFlow UI-control evals — drives a real app through its own menus")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task { @MainActor in
            code = await runAll()
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return code
    }

    @MainActor
    private static func runAll() async -> Int32 {
        guard Permissions.accessibilityTrusted else {
            print("SKIP: Accessibility not granted — this path needs it")
            return 0
        }

        let wasRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        var failures = 0

        _ = await BasicActions.openApp(ZeldaFlowAction(action: "open_app", app: "TextEdit"))
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        guard let textEdit = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            print("FAIL: TextEdit did not launch")
            return 1
        }
        textEdit.activate()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // A document must be open or Format/Edit are disabled — and the
        // matcher deliberately refuses disabled commands, so without this the
        // test measures an app that genuinely can't do anything yet.
        _ = await AppleScriptRunner.run(
            "tell application \"TextEdit\" to make new document with properties {text:\"zeldaFlow\"}")

        // Poll rather than sleep a fixed span: the menu bar populates
        // asynchronously after the document appears, and a fixed wait made this
        // eval fail intermittently on nothing more than machine load.
        var ready = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let probe = UIScout.menuCommands(for: textEdit)
            if probe.contains(where: { $0.title == "Bold" && $0.enabled }) { ready = true; break }
        }
        if !ready {
            print("FAIL: TextEdit's menus never became active")
            return 1
        }

        // 1. Can we see what the app can do?
        let commands = UIScout.menuCommands(for: textEdit)
        print("  discovered \(commands.count) menu commands in TextEdit")
        for c in commands.prefix(8) {
            print("    · \(c.display)\(c.shortcut.map { "  [\($0)]" } ?? "")")
        }
        if commands.count < 20 {
            print("  FAIL: expected a full menu tree, got \(commands.count)")
            failures += 1
        }

        // 2. Does natural phrasing find the right command?
        let phrases: [(said: String, expectLeaf: String)] = [
            ("make it bold", "Bold"),
            ("bold this", "Bold"),
            ("italic", "Italic"),
            ("select all", "Select All"),
            ("paste", "Paste"),
            ("save this", "Save…"),
        ]
        print("\n  matching spoken phrases against real menu items:")
        for (said, expect) in phrases {
            guard let hit = UIMatcher.best(for: said, in: commands) else {
                print("    ✗ \"\(said)\" → no match (expected \(expect))")
                failures += 1
                continue
            }
            let ok = hit.command.title.localizedCaseInsensitiveContains(
                expect.replacingOccurrences(of: "…", with: ""))
            print("    \(ok ? "✓" : "✗") \"\(said)\" → \(hit.command.display)"
                  + "\(hit.confident ? " (confident)" : " (ambiguous → LLM)")")
            if !ok { failures += 1 }
        }

        // Everything below acts through the same focus guard the real pipeline
        // uses: bound to TextEdit, so a stray app switch refuses instead of
        // clicking somewhere else. Re-activated before each step because the
        // eval itself can lose focus between them.
        let ctx = CommandContext(expectedFrontmost: "com.apple.TextEdit")
        // Poll until TextEdit really is frontmost. activate() is a request, not
        // a guarantee — another app finishing its launch can take focus back,
        // and then the focus guard correctly refuses and the eval blames the
        // wrong thing.
        @Sendable @discardableResult func refocus() async -> Bool {
            for _ in 0..<15 {
                textEdit.activate()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == "com.apple.TextEdit" { return true }
            }
            return false
        }

        // 3. Press one for real and confirm the app reacted.
        print("\n  pressing a real menu command:")
        await refocus()
        let outcome = await UIActions.runMenuCommand(
            ZeldaFlowAction(action: "ui_command", text: "Format ▸ Font ▸ Bold"), context: ctx)
        print("    Format ▸ Font ▸ Bold → ok=\(outcome.ok) \(outcome.summary)")
        if !outcome.ok { failures += 1 }

        // 3b. The guard itself: bound to another app, nothing may happen.
        let wrongApp = await UIActions.runMenuCommand(
            ZeldaFlowAction(action: "ui_command", text: "Format ▸ Font ▸ Bold"),
            context: CommandContext(expectedFrontmost: "com.apple.dt.Xcode"))
        print("    focus guard (expects Xcode, TextEdit is front) → "
              + (wrongApp.ok ? "ACTED ANYWAY ✗" : "refused ✓"))
        if wrongApp.ok { failures += 1 }

        // 4. Destructive commands must be gated, always.
        let destructive = commands.first { UIActions.isDestructive($0) }
        if let d = destructive {
            let action = ZeldaFlowAction(action: "ui_command",
                                         text: d.path.joined(separator: " ▸ "),
                                         reason: "destructive")
            let gated = ActionGate.alwaysConfirmLabel(for: action) != nil
            print("\n  destructive gate: \"\(d.title)\" → \(gated ? "gated ✓" : "NOT GATED ✗")")
            if !gated { failures += 1 }
        }

        // 5. Window controls — what menus can't reach. TextEdit's Open panel
        //    has the buttons and the search field every such panel has.
        // These steps need TextEdit genuinely frontmost. If something else on
        // the machine keeps stealing focus, that's the environment, not a
        // defect — say so and skip, rather than reporting a failure the code
        // didn't cause.
        print("\n  reading window controls:")
        if await refocus() {
            _ = await UIActions.runMenuCommand(
                ZeldaFlowAction(action: "ui_command", text: "File ▸ Open…"), context: ctx)
            try? await Task.sleep(nanoseconds: 1_800_000_000)

            let controls = UIControls.inFocusedWindow(of: textEdit)
            print("    discovered \(controls.count) controls in the Open panel")
            for c in controls.prefix(8) { print("      · \(c.display)") }
            if controls.isEmpty {
                print("    FAIL: expected buttons and fields in an open panel")
                failures += 1
            }
            if !controls.contains(where: { $0.kind == "button" }) {
                print("    FAIL: no buttons found")
                failures += 1
            }

            // Click a real button to dismiss the panel.
            let cancelled = await UIActions.click(
                ZeldaFlowAction(action: "ui_click", text: "Cancel"), context: ctx)
            print("    ui_click \"Cancel\" → ok=\(cancelled.ok) \(cancelled.summary)")
            if !cancelled.ok { failures += 1 }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } else {
            print("    SKIP: couldn't keep TextEdit frontmost (something else has focus)")
        }

        // Typing goes against the document window, not the panel: an open
        // panel's search box only becomes a text field once clicked, so
        // testing there would have quietly skipped this path entirely.
        print("\n  typing into a field:")
        if await refocus() {
            let typed = await UIActions.type(
                ZeldaFlowAction(action: "ui_type", text: "typed by zeldaFlow"), context: ctx)
            print("    ui_type → ok=\(typed.ok) \(typed.summary)")
            if !typed.ok {
                print("    FAIL: could not type into TextEdit's document")
                failures += 1
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } else {
            print("    SKIP: couldn't keep TextEdit frontmost")
        }

        // 6. Money and destruction always ask first, whatever the model said.
        print("\n  purchase/destructive click gate:")
        for label in ["Get", "Buy", "Delete"] {
            let a = ZeldaFlowAction(action: "ui_click", text: label)
            let gated = ActionGate.alwaysConfirmLabel(for: a) != nil
            print("    \"\(label)\" → \(gated ? "gated ✓" : "NOT GATED ✗")")
            if !gated { failures += 1 }
        }
        for label in ["Get Info", "Cancel", "Done"] {
            let a = ZeldaFlowAction(action: "ui_click", text: label)
            let gated = ActionGate.alwaysConfirmLabel(for: a) != nil
            print("    \"\(label)\" → \(gated ? "over-gated ✗" : "runs freely ✓")")
            if gated { failures += 1 }
        }

        if !wasRunning { textEdit.terminate() }

        failures += await breadthCheck()

        print(failures == 0
              ? "\nOK — app control works through menus and window controls"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }

    /// One app proves the mechanism; it doesn't prove the coverage. This walks
    /// a spread of real apps on this Mac — Apple's, third-party, document-based
    /// and not — and checks each one exposes a command tree that ordinary
    /// phrasing actually resolves against.
    ///
    /// Enumerate and match only. Nothing is pressed: verifying breadth is not
    /// worth sending mail or changing settings on someone's machine.
    @MainActor
    private static func breadthCheck() -> Int {
        // Deliberately not TextEdit. Each phrase is what a person would say,
        // and the expected leaf is what that app really calls it.
        let apps: [(bundle: String, name: String, probes: [(String, String)])] = [
            ("com.apple.Safari", "Safari",
             [("new tab", "New Tab"), ("open a private window", "New Private Window")]),
            ("com.apple.finder", "Finder",
             [("new folder", "New Folder"), ("empty the trash", "Empty Trash")]),
            ("com.apple.Notes", "Notes",
             [("new note", "New Note"), ("new folder", "New Folder")]),
            ("com.apple.mail", "Mail",
             [("get new mail", "Get All New Mail"), ("new message", "New Message")]),
            ("com.apple.iCal", "Calendar",
             [("new event", "New Event"), ("go to today", "Today")]),
            ("com.apple.reminders", "Reminders",
             [("new reminder", "New Reminder"), ("new list", "New List")]),
            ("com.apple.Preview", "Preview",
             [("zoom in", "Zoom In"), ("rotate left", "Rotate Left")]),
            ("com.apple.systempreferences", "System Settings",
             [("minimize the window", "Minimize")]),
            ("com.apple.AppStore", "App Store",
             [("reload the page", "Reload Page"), ("minimize", "Minimize")]),
            ("com.apple.ScreenContinuity", "iPhone Mirroring", []),
            ("com.apple.Music", "Music",
             [("play", "Play"), ("next track", "Next")]),
            ("com.apple.Terminal", "Terminal",
             [("new window", "New Window")]),
        ]

        print("\n\n  breadth: every app's own command tree, not just TextEdit")
        var failures = 0
        var covered = 0

        for app in apps {
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: app.bundle).first else {
                print("    · \(app.name) — not running, skipped")
                continue
            }
            let commands = UIScout.menuCommands(for: running)
            guard !commands.isEmpty else {
                print("    ✗ \(app.name) — running but exposed no commands")
                failures += 1
                continue
            }
            covered += 1
            let enabled = commands.filter(\.enabled).count
            print("    · \(app.name): \(commands.count) commands (\(enabled) available now)")

            // Trailing ellipses and stray punctuation are presentation, not
            // identity: "Empty Trash…" is the Empty Trash command.
            func norm(_ s: String) -> String {
                s.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }

            for (said, expectLeaf) in app.probes {
                // Only judge a probe when the app really has that exact command
                // enabled right now. Matching loosely here was worse than
                // useless: "Play" found "Playlists" and then blamed the matcher
                // for not selecting a command the app never had available.
                guard commands.contains(where: {
                    norm($0.title) == norm(expectLeaf) && $0.enabled
                }) else {
                    print("        · \"\(said)\" — \(expectLeaf) not available, skipped")
                    continue
                }
                guard let hit = UIMatcher.best(for: said, in: commands) else {
                    print("        ✗ \"\(said)\" → no match (expected \(expectLeaf))")
                    for c in UIMatcher.shortlist(for: said, in: commands, limit: 3) {
                        print("            considered: \(c.display)"
                              + (c.enabled ? "" : " [disabled]"))
                    }
                    failures += 1
                    continue
                }
                let ok = norm(hit.command.title) == norm(expectLeaf)
                print("        \(ok ? "✓" : "✗") \"\(said)\" → \(hit.command.display)")
                if !ok { failures += 1 }
            }
        }

        print("    — checked \(covered) running apps")
        print("      (a backgrounded app greys out most of its menus, so many probes"
              + " skip here; the self-match pass below is the real coverage signal)")
        if covered < 3 {
            print("    NOTE: few apps were running, so this says little. "
                  + "Open Safari, Mail and Notes and re-run for a real signal.")
        }

        failures += selfMatchCheck(apps.map { ($0.bundle, $0.name) })
        return failures
    }

    /// Hand-picked probes only test the phrasings I thought of. This tests the
    /// matcher against every command each app actually publishes: speak a
    /// command's own name and it must come back.
    ///
    /// A command that can't be selected by its own title can't be selected at
    /// all, so a miss here is a genuine hole — across thousands of real menu
    /// items rather than the dozen I happened to write down.
    @MainActor
    private static func selfMatchCheck(_ apps: [(bundle: String, name: String)]) -> Int {
        print("\n  self-match: every command in every app, by its own name")
        var total = 0, hits = 0, ambiguous = 0
        var misses: [String] = []

        for app in apps {
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: app.bundle).first else { continue }
            let commands = UIScout.menuCommands(for: running)
            let enabled = commands.filter(\.enabled)

            // Only titles that are unique among enabled commands. A duplicate
            // title is legitimately ambiguous, so scoring it as a miss would
            // penalise correct behaviour.
            //
            // "Unique" has to mean unique *to the matcher*: Finder ships both
            // "Empty Trash" and "Empty Trash…", and Safari's history had two
            // entries differing only by an invisible U+200E. Nothing could tell
            // those apart from the spoken words alone.
            func key(_ s: String) -> String {
                s.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            var counts: [String: Int] = [:]
            for c in enabled { counts[key(c.title), default: 0] += 1 }

            var appTotal = 0, appHits = 0
            for c in enabled where counts[key(c.title)] == 1 {
                // Titles that are pure punctuation or a single filler word have
                // nothing to match on; they're reachable by path, not by name.
                guard c.title.count > 2,
                      c.title.rangeOfCharacter(from: .letters) != nil else { continue }
                total += 1; appTotal += 1
                guard let hit = UIMatcher.best(for: c.title, in: commands) else {
                    if misses.count < 12 { misses.append("\(app.name): \(c.display)") }
                    continue
                }
                if hit.command == c {
                    hits += 1; appHits += 1
                    if !hit.confident { ambiguous += 1 }
                } else if misses.count < 12 {
                    misses.append("\(app.name): \(c.display) → got \(hit.command.display)")
                }
            }
            if appTotal > 0 {
                let pct = appTotal == 0 ? 0 : appHits * 100 / appTotal
                print("    · \(app.name): \(appHits)/\(appTotal) (\(pct)%)")
            }
        }

        guard total > 0 else {
            print("    no running apps to check")
            return 0
        }
        let pct = hits * 100 / total
        print("    — \(hits)/\(total) commands resolve by their own name (\(pct)%), "
              + "\(ambiguous) of those deferred to the model as ambiguous")
        for m in misses { print("      ✗ \(m)") }

        // A hole here means commands the user simply cannot reach by voice.
        if pct < 95 {
            print("    FAIL: expected ≥95% self-match")
            return 1
        }
        return 0
    }
}
