import AppKit

/// Runs a multi-step task: look at the screen, do one thing, look again — until
/// the goal is met, the budget runs out, or nothing is changing.
///
/// The shape of this loop was decided by measurement against the actual local
/// model, not by taste, and two results drove everything:
///
/// **The model cannot be trusted to generate a step.** Asked to emit one freely
/// it scored 3/6 on realistic screens: it invented labels, and when its
/// chain-of-thought ran long it returned nothing at all. Given a numbered list
/// of real options it scored 4/6 and never once chose out of range in 20 runs.
/// So the loop builds the options and the model only points at one.
///
/// **The model cannot recognise that it has finished.** Offered exactly two
/// choices — "wait" and "done" — on a screen where the task was visibly
/// complete, it chose "wait". Every time. So completion is decided here, in
/// code, from observable facts; the model is never asked.
///
/// What follows from that: the candidate builder is the product, and the LLM is
/// a ranker of last resort. The safety properties don't depend on it at all.
@MainActor
enum TaskRunner {
    static let maxSteps = 12
    static let wallClock: TimeInterval = 150
    /// Consecutive identical screens before calling it stuck. Two is too eager
    /// — a page still loading legitimately looks the same twice.
    static let sameScreenStrikes = 3

    struct Hooks {
        /// Ask the user to approve one step. False on Esc or timeout.
        let confirm: (String) async -> Bool
        /// Narrate into the pill so the user can watch it work.
        let progress: (String) -> Void
        /// True once this command has been superseded or cancelled.
        let isCancelled: () -> Bool
    }

    /// Why the loop stopped. Every one of these is decided in code.
    enum Stop {
        case completedGatedAction(String)   // clicked Get/Buy/Delete — that was the task
        case completedGoal(String)          // ran the command the goal named
        case nothingLeftToTry
        case screenStopped(String)
        case stepCap
        case outOfTime
        case cancelled
        case declined
        case plannerUnavailable

        var ok: Bool {
            switch self {
            case .completedGatedAction, .completedGoal: return true
            default: return false
            }
        }
    }

    static func run(goal: String, cleanup: CleanupService,
                    hooks: Hooks) async -> ActionOutcome {
        var ledger = TrialLedger()
        var typedInto: [String: String] = [:]
        var history: [String] = []
        var lastFingerprint: String?
        var strikes = 0
        var justTyped = false
        let deadline = Date().addingTimeInterval(wallClock)

        Log.info("task: \"\(goal)\"")

        for step in 1...maxSteps {
            if hooks.isCancelled() { return finish(.cancelled, goal, history) }
            if Date() > deadline { return finish(.outOfTime, goal, history) }

            let obs = TaskObservation.capture(goal: goal)

            // Nothing changed? Apps are slow, so allow a couple of rounds —
            // then stop rather than keep clicking at a frozen screen.
            if obs.fingerprint == lastFingerprint {
                strikes += 1
                if strikes >= sameScreenStrikes {
                    return finish(.screenStopped(obs.appName), goal, history)
                }
            } else {
                strikes = 0
            }
            lastFingerprint = obs.fingerprint

            let candidates = TaskCandidates.build(goal: goal, observation: obs,
                                                  ledger: ledger, typedInto: typedInto,
                                                  justTyped: justTyped)
            // Only "wait" left means there is nothing real to do.
            guard candidates.contains(where: { $0.signature != "wait" }) else {
                return finish(.nothingLeftToTry, goal, history)
            }

            let rendered = obs.serialized(goal: goal, step: step,
                                          maxSteps: maxSteps, history: history)
            guard let n = await cleanup.selectStep(
                    observation: rendered, options: candidates.map(\.label)) else {
                // A miss here is a wasted step, not a wrong action. Retry once
                // via the next iteration rather than abandoning the task.
                history.append("(couldn't choose a step)")
                if step >= 2, history.suffix(2).allSatisfy({ $0.hasPrefix("(couldn't") }) {
                    return finish(.plannerUnavailable, goal, history)
                }
                continue
            }
            if hooks.isCancelled() { return finish(.cancelled, goal, history) }

            let chosen = candidates[n]

            if case .wait = chosen.kind {
                hooks.progress("Waiting…")
                history.append("waited")
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }

            // Build the executable action. Typing needs its text, which comes
            // from a second constrained call — the model is reliable at
            // extracting "Slack" from the goal (6/6) and unreliable at
            // producing it as part of a larger free-form answer.
            guard let action = await materialise(chosen, goal: goal, app: obs.appName,
                                                 cleanup: cleanup,
                                                 typedInto: &typedInto) else {
                ledger.record(chosen.signature, ok: false)
                history.append("\(chosen.label) -> couldn't prepare")
                continue
            }

            // The same gate a one-shot command gets. Automation is not consent:
            // reaching a Buy button by itself is exactly when to stop and ask.
            var wasGated = false
            if let label = ActionGate.alwaysConfirmLabel(for: action) {
                wasGated = true
                hooks.progress("Confirm?")
                guard await hooks.confirm(label) else {
                    return finish(.declined, goal, history)
                }
                if hooks.isCancelled() { return finish(.cancelled, goal, history) }
            }

            hooks.progress(chosen.label)

            // Bind each step to the app that was actually observed, so focus
            // moving between looking and acting refuses instead of clicking in
            // whatever window arrived. Opening an app is exempt: changing the
            // frontmost app is the whole point of it.
            let ctx: CommandContext
            if case .openApp = chosen.kind {
                ctx = CommandContext(expectedFrontmost: nil)
            } else {
                ctx = CommandContext(expectedFrontmost: obs.bundleID)
            }

            let result = await ActionExecutor.run(action, context: ctx)
            ledger.record(chosen.signature, ok: result.ok)
            if case .type = chosen.kind { justTyped = result.ok } else { justTyped = false }
            history.append("\(chosen.label) -> \(result.ok ? "ok" : "failed")")
            Log.info("task step \(step): \(chosen.label) -> \(result.ok ? "ok" : "failed")")

            // A gated action succeeding IS the task: the user asked to download
            // an app and we clicked Get with their approval. Carrying on from
            // here is how an agent ends up clicking things nobody asked for.
            if wasGated, result.ok {
                return finish(.completedGatedAction(chosen.label), goal, history)
            }
            // Running the very thing the goal named is equally an ending.
            if chosen.isGoalMatch, result.ok {
                return finish(.completedGoal(chosen.label), goal, history)
            }

            await settle(after: chosen.kind)
        }

        return finish(.stepCap, goal, history)
    }

    // MARK: - Steps

    /// Turn a chosen candidate into a runnable action, fetching typed text.
    private static func materialise(_ c: TaskCandidate, goal: String, app: String,
                                    cleanup: CleanupService,
                                    typedInto: inout [String: String]) async
        -> ZeldaFlowAction? {
        switch c.kind {
        case .openApp(let name):
            return ZeldaFlowAction(action: "open_app", app: name)
        case .click(let control):
            return ZeldaFlowAction(action: "ui_click", text: control.label)
        case .menu(let m):
            return ZeldaFlowAction(action: "ui_command",
                                   text: m.path.joined(separator: " ▸ "),
                                   reason: UIActions.isDestructive(m) ? "destructive" : nil)
        case .key(let k):
            return ZeldaFlowAction(action: "press_key", key: k)
        case .type(let field):
            guard let text = await cleanup.fieldText(
                    goal: goal, field: field.label, app: app) else { return nil }
            // Remember it so the next round doesn't offer to type it again —
            // the field's AX value becomes its label, so this is how we know.
            typedInto[field.label.lowercased()] = text
            typedInto[text.lowercased()] = text
            return ZeldaFlowAction(action: "ui_type", text: text, target: field.label)
        case .wait:
            return nil
        }
    }

    /// Let the UI catch up before looking again. Launching an app is in a
    /// different league from pressing a key, and observing too early reads a
    /// half-built window that the planner then tries to act on.
    private static func settle(after kind: TaskCandidate.Kind) async {
        switch kind {
        case .openApp:
            // Poll rather than guess: a running app is instant, a cold launch
            // is seconds, and any fixed wait is wrong for one of them.
            let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if now != before, now != Bundle.main.bundleIdentifier { break }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        case .key:
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        case .click, .menu:
            try? await Task.sleep(nanoseconds: 800_000_000)
        case .type, .wait:
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: - Reporting

    /// Say what actually happened, including when it didn't work.
    ///
    /// The loop reports what it *did*, never what it achieved: clicking Get
    /// means Get was clicked, not that 300 MB finished downloading. Claiming
    /// otherwise would be the easiest way to make this feel unreliable.
    private static func finish(_ stop: Stop, _ goal: String,
                               _ history: [String]) -> ActionOutcome {
        let trail = history.isEmpty ? "no steps" : history.joined(separator: " · ")
        let pill: String
        switch stop {
        case .completedGatedAction(let what): pill = "✓ \(what)"
        case .completedGoal(let what):
            pill = "✓ " + what.replacingOccurrences(of: "menu ", with: "")
                               .replacingOccurrences(of: " > ", with: " ▸ ")
        case .nothingLeftToTry:               pill = "Nothing left to try for that"
        case .screenStopped(let app):         pill = "\(app) stopped responding to it"
        case .stepCap:                        pill = "Gave up after \(maxSteps) steps"
        case .outOfTime:                      pill = "Task took too long"
        case .cancelled:                      pill = "Cancelled"
        case .declined:                       pill = "Cancelled"
        case .plannerUnavailable:             pill = "AI engine isn't responding"
        }
        Log.info("task ended: \(stop) after \(history.count) steps")
        return ActionOutcome(ok: stop.ok, summary: "[task: \(trail)]", pillMessage: pill,
                             payload: history.isEmpty ? nil
                                 : "\(goal)\n\n" + history.enumerated()
                                     .map { "\($0.offset + 1). \($0.element)" }
                                     .joined(separator: "\n"))
    }
}
