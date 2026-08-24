import AppKit

/// One concrete, already-validated thing the loop could do next.
///
/// A candidate is built from live Accessibility data, so by construction it
/// names a control or menu item that exists right now. The model's only job is
/// to pick one — it never invents a label, so the worst a bad pick can do is
/// waste a step.
struct TaskCandidate {
    enum Kind {
        case openApp(String)
        case click(UIControl)
        case type(field: UIControl)
        case menu(MenuCommand)
        case key(String)
        case wait
    }
    let kind: Kind
    /// The line the model sees. Also the pill narration.
    let label: String
    /// Stable identity for the ledger, so a step that failed can be withheld.
    let signature: String
    /// This step *is* what was asked for, not a move toward it.
    ///
    /// "check for new mail" names Mail's own "Get New Mail" command almost
    /// exactly. Running it successfully finishes the task, and without knowing
    /// that the loop carries on pressing keys and waiting until it times out —
    /// then reports failure for something it had already done.
    var isGoalMatch: Bool = false

    var isGuarded: Bool {
        switch kind {
        case .click(let c): return UIActions.isGuarded(c)
        case .menu(let m):  return UIActions.isDestructive(m)
        default:            return false
        }
    }
}

/// Records what has already been tried, so the same step isn't offered forever.
///
/// This is load-bearing rather than an optimisation. Measured: leaving a
/// satisfied step in the list makes the model choose it again — it re-typed a
/// search box that already held the right text, and re-pressed a Return that
/// had already worked. Pruning those two options was the difference between
/// picking the wrong step and picking "click Get".
struct TrialLedger {
    private(set) var succeeded: Set<String> = []
    private var failures: [String: Int] = [:]

    mutating func record(_ signature: String, ok: Bool) {
        if ok { succeeded.insert(signature) } else { failures[signature, default: 0] += 1 }
    }
    /// Two strikes: once can be a timing problem, twice is the step being wrong.
    func isBurned(_ signature: String) -> Bool { (failures[signature] ?? 0) >= 2 }
    func hasSucceeded(_ signature: String) -> Bool { succeeded.contains(signature) }
}

enum TaskCandidates {
    /// Everything worth doing next, in a stable order, already pruned.
    ///
    /// Ordering matters as much as membership: the model shows a mild bias
    /// toward the first entries, so the most task-shaped options go first.
    @MainActor
    static func build(goal: String, observation obs: TaskObservation,
                      ledger: TrialLedger, typedInto: [String: String],
                      justTyped: Bool = false) -> [TaskCandidate] {
        // Text typed into a search field does nothing until it's submitted, and
        // which key submits it is not a judgement call. Observed: left to
        // choose freely after typing "Slack" into the App Store, the model
        // clicked the Search tab, then Categories, and never searched at all.
        // So this one transition is sequenced in code.
        if justTyped {
            return [
                TaskCandidate(kind: .key("return"), label: "press return",
                              signature: "key:return"),
                TaskCandidate(kind: .wait, label: "wait for the screen to change",
                              signature: "wait"),
            ]
        }

        var out: [TaskCandidate] = []

        // The app the goal names, if we aren't in it yet. First, because
        // nothing else can work from the wrong app.
        if let wanted = namedApp(in: goal),
           !obs.appName.localizedCaseInsensitiveContains(wanted) {
            out.append(TaskCandidate(kind: .openApp(wanted),
                                     label: "open \(wanted)",
                                     signature: "open:\(wanted.lowercased())"))
        }

        for c in obs.controls where c.kind == "button" {
            // A button repeating the window title is almost always the item
            // we're already looking at. Measured: leaving it in made the model
            // click "Slack" on the Slack page instead of "Get".
            if isEchoOfWindow(c.label, obs.windowTitle) { continue }
            out.append(TaskCandidate(kind: .click(c), label: "click \(c.label)",
                                     signature: "click:\(c.label.lowercased())"))
        }

        for c in obs.controls where c.kind == "field" {
            // The field's AX value doubles as its label, so a field already
            // holding what we typed shows up here with that text. Offering it
            // again just re-types it.
            if let typed = typedInto[c.label.lowercased()], typed == c.label { continue }
            if c.label.caseInsensitiveCompare(typedInto[c.label.lowercased()] ?? "\u{0}")
                == .orderedSame { continue }
            out.append(TaskCandidate(kind: .type(field: c),
                                     label: "type into \(c.label)",
                                     signature: "type:\(c.label.lowercased())"))
        }

        // A menu command the goal names outright finishes the task by itself.
        //
        // The bar is "best match, and a real match" rather than UIMatcher's
        // `confident` flag: confidence is tuned for *choosing* a command
        // unprompted, and "check for new mail" only scores 56 against Mail's
        // "Get New Mail" because of the words around it. For deciding that a
        // command we already ran was the point, top-ranked above the match
        // floor is the right test — a goal sharing no words with any menu, like
        // "find lofi beats on youtube", still matches nothing and completes
        // nothing.
        let topMenu = obs.menus
            .compactMap { m in UIMatcher.score(m, against: goal).map { (m, $0) } }
            .max { $0.1 < $1.1 }
        for m in obs.menus {
            out.append(TaskCandidate(kind: .menu(m),
                                     label: "menu \(m.path.joined(separator: " > "))",
                                     signature: "menu:\(m.display.lowercased())",
                                     isGoalMatch: topMenu?.0 == m && (topMenu?.1 ?? 0) >= 55))
        }

        for c in obs.controls where c.kind == "link" || c.kind == "checkbox" || c.kind == "menu" {
            if isEchoOfWindow(c.label, obs.windowTitle) { continue }
            out.append(TaskCandidate(kind: .click(c), label: "click \(c.label)",
                                     signature: "click:\(c.label.lowercased())"))
        }

        out.append(TaskCandidate(kind: .key("return"), label: "press return",
                                 signature: "key:return"))
        out.append(TaskCandidate(kind: .wait, label: "wait for the screen to change",
                                 signature: "wait"))

        // Withhold anything already done or twice-failed. Everything above is
        // about what exists; this is about what's left worth trying.
        return out.filter { c in
            if c.signature == "wait" { return true }
            return !ledger.hasSucceeded(c.signature) && !ledger.isBurned(c.signature)
        }
    }

    /// A button labelled the same as the window is a link to where we already
    /// are. Compared loosely because apps pad titles ("Slack" vs "Slack — Mac").
    private static func isEchoOfWindow(_ label: String, _ window: String?) -> Bool {
        guard let w = window, !w.isEmpty, label.count > 2 else { return false }
        return w.localizedCaseInsensitiveCompare(label) == .orderedSame
            || w.localizedCaseInsensitiveHasPrefix(label + " ")
    }

    /// An installed app named in the goal. Checked against what's really on
    /// this Mac, so "open the app store" resolves and "open my fridge" doesn't.
    static func namedApp(in goal: String) -> String? {
        let g = goal.lowercased()
        // Longest name first: "App Store" must win over a hypothetical "App".
        return AppResolver.installedApps()
            .filter { $0.count >= 4 && g.contains($0.lowercased()) }
            .max { $0.count < $1.count }
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ p: String) -> Bool {
        guard count >= p.count else { return false }
        return prefix(p.count).localizedCaseInsensitiveCompare(p) == .orderedSame
    }
}
