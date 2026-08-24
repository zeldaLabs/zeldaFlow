import AppKit

/// Checks the multi-step task loop.
///
/// Two halves, and the first matters more. The **safety and termination**
/// checks must hold no matter what the model picks — they're pure code, so a
/// failure there is a real defect. The **live** checks measure how well the
/// model actually selects, which is a quality number that will drift with the
/// model; it's reported rather than pass/fail-ed on a knife edge.
enum TaskEvals {
    static func run() -> Int32 {
        print("zeldaFlow task-loop evals")
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

    /// Drive one real task against the live screen, for `--runtask "<goal>"`.
    ///
    /// Confirmations are always declined here. A test that can complete a
    /// purchase is not a test, and the decline path is the one that has to work
    /// anyway: it proves the gate armed with the right label and that refusing
    /// stops the loop dead.
    static func runLive(goal: String) -> Int32 {
        print("zeldaFlow — running task: \"\(goal)\"")
        print("(confirmations are auto-declined; nothing will be bought or deleted)\n")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task { @MainActor in
            let cleanup = CleanupService(port: 8765)
            guard await cleanup.ensureReady(timeoutSeconds: 30) else {
                print("FAIL: local model isn't running")
                code = 1; sem.signal(); return
            }
            var gated: [String] = []
            let started = Date()
            let outcome = await TaskRunner.run(
                goal: goal, cleanup: cleanup,
                hooks: TaskRunner.Hooks(
                    confirm: { label in
                        print("  🔒 GATE: \(label)")
                        print("     → declining (test mode)")
                        gated.append(label)
                        return false
                    },
                    progress: { print("  → \($0)") },
                    isCancelled: { false }))
            print("\nfinished in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            print("ok=\(outcome.ok)  \(outcome.pillMessage ?? "")")
            if let p = outcome.payload { print("\nsteps:\n\(p)") }
            print("\ngates armed: \(gated.count)")
            code = 0
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return code
    }

    @MainActor
    private static func runAll() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("    \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // 1. Intent: does a sentence enter the loop at all?
        print("\n  task vs command:")
        let openApp = ZeldaFlowAction(action: "open_app", app: "App Store")
        let cases: [(String, ZeldaFlowAction, Bool)] = [
            ("download Slack from the App Store", openApp, true),
            ("find the Notion app in the app store", openApp, true),
            ("open the app store", openApp, false),
            ("just open safari", ZeldaFlowAction(action: "open_app", app: "Safari"), false),
            ("open safari", ZeldaFlowAction(action: "open_app", app: "Safari"), false),
            ("switch to notes", ZeldaFlowAction(action: "open_app", app: "Notes"), false),
            // A completed action must never start a loop.
            ("send an email to priya checking on the report",
             ZeldaFlowAction(action: "send_email", to: "priya"), false),
            ("play some coldplay", ZeldaFlowAction(action: "play_music"), false),
        ]
        for (said, action, want) in cases {
            let got = TaskIntent.looksLikeTask(said, firstAction: action)
            check("\"\(said)\"", got == want, got ? "task" : "one-shot")
        }

        // 2. Candidate building and pruning — the part the model depends on.
        print("\n  candidate pruning:")
        let controls = [
            UIControl(label: "Get", role: "AXButton", enabled: true, ordinal: 0),
            UIControl(label: "Slack", role: "AXButton", enabled: true, ordinal: 0),
            UIControl(label: "Back", role: "AXButton", enabled: true, ordinal: 0),
            UIControl(label: "Search", role: "AXTextField", enabled: true, ordinal: 0),
        ]
        let obs = TaskObservation(appName: "App Store", bundleID: "com.apple.AppStore",
                                  windowTitle: "Slack", controls: controls, menus: [])
        var ledger = TrialLedger()
        var built = TaskCandidates.build(goal: "download Slack from the App Store",
                                         observation: obs, ledger: ledger, typedInto: [:])
        var labels = built.map(\.label)
        check("offers the Get button", labels.contains("click Get"))
        check("drops the link echoing the window title",
              !labels.contains("click Slack"), labels.joined(separator: ", "))
        check("always offers wait", labels.contains { $0.hasPrefix("wait") })

        ledger.record("click:back", ok: false)
        ledger.record("click:back", ok: false)
        built = TaskCandidates.build(goal: "download Slack", observation: obs,
                                     ledger: ledger, typedInto: [:])
        check("withholds a step that failed twice",
              !built.map(\.label).contains("click Back"))

        ledger.record("key:return", ok: true)
        built = TaskCandidates.build(goal: "download Slack", observation: obs,
                                     ledger: ledger, typedInto: [:])
        check("withholds a step that already succeeded",
              !built.map(\.label).contains("press return"))

        // A field whose AX value is the text we typed must not be offered again
        // — this is the prune that measurably flipped the model's answer.
        let filled = [UIControl(label: "Slack", role: "AXTextField", enabled: true, ordinal: 0)]
        let obs2 = TaskObservation(appName: "App Store", bundleID: "com.apple.AppStore",
                                   windowTitle: "Apps", controls: filled, menus: [])
        built = TaskCandidates.build(goal: "download Slack", observation: obs2,
                                     ledger: TrialLedger(), typedInto: ["slack": "Slack"])
        check("doesn't re-type into a field already holding that text",
              !built.map(\.label).contains("type into Slack"),
              built.map(\.label).joined(separator: ", "))

        // 3. Safety — these hold regardless of what the model chooses.
        print("\n  safety invariants:")
        for label in ["Get", "Buy", "Delete", "Install"] {
            let a = ZeldaFlowAction(action: "ui_click", text: label)
            check("clicking \"\(label)\" is gated",
                  ActionGate.alwaysConfirmLabel(for: a) != nil)
        }
        for label in ["Back", "Get Info", "Cancel"] {
            let a = ZeldaFlowAction(action: "ui_click", text: label)
            check("clicking \"\(label)\" runs freely",
                  ActionGate.alwaysConfirmLabel(for: a) == nil)
        }

        // 4. Termination — the loop must always stop, and quickly.
        print("\n  termination (no model, no screen changes):")
        let started = Date()
        var confirmations = 0
        let outcome = await TaskRunner.run(
            goal: "download Slack from the App Store",
            cleanup: CleanupService(port: 1),   // deliberately dead: no planner
            hooks: TaskRunner.Hooks(
                confirm: { _ in confirmations += 1; return false },
                progress: { _ in },
                isCancelled: { false }))
        let elapsed = Date().timeIntervalSince(started)
        check("stops when the planner is unavailable", !outcome.ok, outcome.summary)
        check("stops fast (\(String(format: "%.1f", elapsed))s)", elapsed < 30)
        check("never asked to confirm anything", confirmations == 0)

        // Cancellation must be honoured on the very first check.
        let cancelled = await TaskRunner.run(
            goal: "download Slack", cleanup: CleanupService(port: 1),
            hooks: TaskRunner.Hooks(confirm: { _ in true }, progress: { _ in },
                                    isCancelled: { true }))
        check("honours cancellation immediately", !cancelled.ok,
              cancelled.pillMessage ?? "")

        // 5. Live selection quality, if the local model is up.
        print("\n  live planner (quality signal, not a gate):")
        let live = CleanupService(port: 8765)
        if await live.ensureReady(timeoutSeconds: 20) {
            let scenarios: [(String, String, [String], Int)] = [
                ("on the Slack page",
                 "GOAL: download Slack from the App Store\nAPP: App Store\nWINDOW: Slack\n",
                 ["click Get", "click Back", "wait"], 0),
                ("nothing typed yet",
                 "GOAL: download Slack from the App Store\nAPP: App Store\nWINDOW: Apps\n",
                 ["type into Search", "click Back", "wait"], 0),
                ("wrong app",
                 "GOAL: download Slack from the App Store\nAPP: Finder\nWINDOW: Downloads\n",
                 ["open App Store", "click Back", "wait"], 0),
            ]
            var hits = 0
            for (name, state, options, want) in scenarios {
                let n = await live.selectStep(observation: state, options: options)
                let ok = n == want
                hits += ok ? 1 : 0
                print("    \(ok ? "✓" : "·") \(name): picked "
                      + "\(n.map { options[$0] } ?? "nothing"), wanted \(options[want])")
            }
            print("    selection: \(hits)/\(scenarios.count)")

            if let text = await live.fieldText(
                goal: "download Slack from the App Store", field: "Search", app: "App Store") {
                let ok = text.localizedCaseInsensitiveContains("slack")
                check("extracts what to type", ok, text)
            } else {
                print("    · field text unavailable")
            }
        } else {
            print("    SKIP: local model not running")
        }

        print(failures == 0
              ? "\nOK — task loop is safe, terminates, and prunes correctly"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }
}
