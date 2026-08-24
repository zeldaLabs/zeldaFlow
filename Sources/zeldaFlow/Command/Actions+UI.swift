import AppKit
import ApplicationServices

/// Drives any app through its own menus — the "do that thing in this app"
/// capability, without a template per app.
///
/// The safety model is unchanged from ADR 7: the model never writes code and
/// never synthesises coordinates. It selects from commands the frontmost app
/// declared through the Accessibility API, and we press exactly one of them.
/// Anything the app doesn't offer simply cannot be chosen.
enum UIActions {
    /// Menu items whose names indicate irreversible loss. These always ask
    /// first, because "delete" heard slightly wrong is not recoverable.
    private static let destructiveWords = [
        "delete", "erase", "remove", "trash", "discard", "clear",
        "reset", "revert", "empty", "wipe", "uninstall", "sign out", "log out",
    ]

    static func isDestructive(_ command: MenuCommand) -> Bool {
        let t = command.title.lowercased()
        return destructiveWords.contains { t.contains($0) }
    }

    /// Confirmation label when a chosen command looks destructive.
    static func confirmationLabel(for command: MenuCommand, app: String) -> String {
        "Run “\(command.display)” in \(app)? Tap Fn to confirm, Esc to cancel"
    }

    /// The app to drive, or nil if focus moved since the user spoke.
    ///
    /// Every UI action resolves its target through here. Without it these
    /// actions bind to whatever happens to be frontmost when the LLM finishes,
    /// so a Cmd-Tab mid-sentence lands the click in a different app — which is
    /// the one failure mode where "it did something" is worse than "it didn't".
    private static func target(_ context: CommandContext) -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        guard front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        if let expected = context.expectedFrontmost, front.bundleIdentifier != expected {
            return nil
        }
        return front
    }

    private static func focusMoved(_ what: String) -> ActionOutcome {
        ActionOutcome(ok: false, summary: "[\(what): focus moved]",
                      pillMessage: "You switched apps — nothing was clicked")
    }

    @MainActor
    static func runMenuCommand(_ a: ZeldaFlowAction,
                               context: CommandContext = CommandContext(expectedFrontmost: nil))
        async -> ActionOutcome {
        guard let raw = a.text, !raw.isEmpty else {
            return ActionOutcome(ok: false, summary: "[ui_command: empty]",
                                 pillMessage: "Do what, exactly?")
        }
        guard let front = target(context) else { return focusMoved("ui_command") }
        // The LLM may hand back a full path ("Format ▸ Font ▸ Bold") or just
        // the leaf. Both are resolved against the live menu tree.
        let path = raw.components(separatedBy: "▸")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let appName = front.localizedName ?? "the app"

        // Re-read the menus now: enabled state changes with selection, and the
        // path we were given may be stale by a second or two.
        let commands = UIScout.menuCommands(for: front)
        guard !commands.isEmpty else {
            return ActionOutcome(ok: false, summary: "[ui_command: no menus]",
                                 pillMessage: "\(appName) didn't expose any commands")
        }

        // Prefer an exact path, else fall back to matching the spoken words.
        var target = commands.first { $0.path == path }
        if target == nil, path.count == 1 {
            target = commands.first { $0.title.caseInsensitiveCompare(path[0]) == .orderedSame }
        }
        if target == nil {
            target = UIMatcher.best(for: raw, in: commands)?.command
        }

        guard let command = target else {
            return ActionOutcome(ok: false, summary: "[ui_command: not found: \(raw)]",
                                 pillMessage: "\(appName) has no “\(raw)”")
        }
        guard command.enabled else {
            return ActionOutcome(ok: false, summary: "[ui_command disabled: \(command.display)]",
                                 pillMessage: "“\(command.title)” isn't available right now")
        }

        guard let element = UIScout.element(for: command.path, in: front) else {
            return ActionOutcome(ok: false, summary: "[ui_command: element gone]",
                                 pillMessage: "Couldn't reach “\(command.title)”")
        }

        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard err == .success else {
            Log.error("ui_command: AXPress failed (\(err.rawValue)) for \(command.display)")
            return ActionOutcome(ok: false, summary: "[ui_command failed: \(command.display)]",
                                 pillMessage: "\(appName) refused “\(command.title)”")
        }

        Log.info("ui_command: pressed \(command.display) in \(appName)")
        return ActionOutcome(ok: true, summary: "[\(appName): \(command.display)]",
                             pillMessage: "✓ \(command.title)")
    }

    /// What the frontmost app can do, for the Hub and for prompting.
    @MainActor
    static func availableCommands() -> [MenuCommand] {
        UIScout.menuCommands().filter(\.enabled)
    }

    // MARK: - Window controls

    /// Buttons that spend money or destroy something. Menus get gated by name
    /// too, but buttons need their own list: "Get" is harmless as a word and
    /// final as an App Store button.
    /// Gating these as a prefix is safe: whatever follows, the intent is still
    /// to spend or destroy ("Delete All", "Buy Now", "Send Later").
    private static let guardedButtons = [
        "buy", "install", "purchase", "subscribe", "confirm", "pay",
        "delete", "remove", "erase", "discard", "trash", "send", "submit",
        "sign out", "log out", "unsubscribe", "cancel subscription",
    ]

    /// Words that mean "purchase" alone and "fetch" in a phrase. "Get" buys an
    /// app; "Get Info" and "Get New Mail" do nothing of the sort, and gating
    /// those would train the user to confirm reflexively — which is how a real
    /// purchase gets waved through.
    private static let guardedExact = ["get"]

    /// Checked against the label rather than a flag on the action, so the gate
    /// holds whether the action came from the matcher or from the model. A
    /// model that forgets to mark a click risky must not be able to skip it.
    static func isGuarded(label: String) -> Bool {
        let t = label.lowercased().trimmingCharacters(in: .whitespaces)
        if guardedExact.contains(t) { return true }
        return guardedButtons.contains { t == $0 || t.hasPrefix($0 + " ") }
    }

    static func isGuarded(_ control: UIControl) -> Bool { isGuarded(label: control.label) }

    @MainActor
    static func click(_ a: ZeldaFlowAction,
                      context: CommandContext = CommandContext(expectedFrontmost: nil))
        async -> ActionOutcome {
        guard let wanted = a.text ?? a.target, !wanted.isEmpty else {
            return ActionOutcome(ok: false, summary: "[ui_click: empty]",
                                 pillMessage: "Click what?")
        }
        guard let front = target(context) else { return focusMoved("ui_click") }
        let appName = front.localizedName ?? "the app"
        let controls = UIControls.inFocusedWindow(of: front)
        guard !controls.isEmpty else {
            return ActionOutcome(ok: false, summary: "[ui_click: no controls]",
                                 pillMessage: "Nothing clickable in \(appName)")
        }
        guard let control = match(wanted, in: controls, pressable: true) else {
            return ActionOutcome(ok: false, summary: "[ui_click: not found: \(wanted)]",
                                 pillMessage: "No “\(wanted)” in \(appName)")
        }
        guard control.enabled else {
            return ActionOutcome(ok: false, summary: "[ui_click disabled: \(control.label)]",
                                 pillMessage: "“\(control.label)” isn't available")
        }
        guard UIControls.press(control, in: front) else {
            Log.error("ui_click: AXPress failed for \(control.display) in \(appName)")
            return ActionOutcome(ok: false, summary: "[ui_click failed: \(control.label)]",
                                 pillMessage: "\(appName) refused “\(control.label)”")
        }
        Log.info("ui_click: pressed \(control.display) in \(appName)")
        return ActionOutcome(ok: true, summary: "[\(appName): clicked \(control.label)]",
                             pillMessage: "✓ \(control.label)")
    }

    @MainActor
    static func type(_ a: ZeldaFlowAction,
                     context: CommandContext = CommandContext(expectedFrontmost: nil))
        async -> ActionOutcome {
        guard let value = a.text, !value.isEmpty else {
            return ActionOutcome(ok: false, summary: "[ui_type: empty]",
                                 pillMessage: "Type what?")
        }
        guard let front = target(context) else { return focusMoved("ui_type") }
        let appName = front.localizedName ?? "the app"

        // A named field wins; otherwise the caret decides. Only when neither
        // answers do we scan, and then only if there's exactly one candidate —
        // guessing among several unnamed boxes types into the wrong one.
        var field: UIControl
        var element: AXUIElement?

        if let wanted = a.target, !wanted.isEmpty {
            let fields = UIControls.inFocusedWindow(of: front).filter { $0.kind == "field" }
            guard let hit = match(wanted, in: fields, pressable: false) else {
                return ActionOutcome(ok: false, summary: "[ui_type: no field \(wanted)]",
                                     pillMessage: "No “\(wanted)” field in \(appName)")
            }
            field = hit
        } else if let (focused, el) = UIControls.focusedField(of: front) {
            field = focused
            element = el
        } else {
            let fields = UIControls.inFocusedWindow(of: front).filter { $0.kind == "field" }
            guard !fields.isEmpty else {
                return ActionOutcome(ok: false, summary: "[ui_type: no fields]",
                                     pillMessage: "No text field in \(appName)")
            }
            guard fields.count == 1 else {
                let names = fields.prefix(3).map(\.label).joined(separator: ", ")
                return ActionOutcome(ok: false, summary: "[ui_type: ambiguous field]",
                                     pillMessage: "Which field? \(names)")
            }
            field = fields[0]
        }

        let ok = element.map { UIControls.setValue(value, into: $0) }
            ?? UIControls.setValue(value, in: field, app: front)
        guard ok else {
            Log.error("ui_type: AXSetValue failed for \(field.display) in \(appName)")
            return ActionOutcome(ok: false, summary: "[ui_type failed: \(field.label)]",
                                 pillMessage: "Couldn't type into “\(field.label)”")
        }
        Log.info("ui_type: set \(field.display) in \(appName)")
        return ActionOutcome(ok: true, summary: "[\(appName): typed into \(field.label)]",
                             pillMessage: "✓ \(field.label)")
    }

    /// Exact label wins, then prefix, then contains — deliberately stricter
    /// than the menu matcher, because a wrong button click acts immediately
    /// while a wrong menu item is usually just a no-op.
    private static func match(_ wanted: String, in controls: [UIControl],
                              pressable: Bool) -> UIControl? {
        let want = wanted.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = pressable ? controls.filter { $0.kind != "field" } : controls
        if let exact = pool.first(where: { $0.label.lowercased() == want }) { return exact }
        if let pre = pool.first(where: { $0.label.lowercased().hasPrefix(want) }) { return pre }
        return pool.first { $0.label.lowercased().contains(want) }
    }

    /// What's on screen right now, for prompting and for "what can I do here".
    @MainActor
    static func availableControls() -> [UIControl] {
        UIControls.inFocusedWindow().filter(\.enabled)
    }

    // MARK: - Keys

    /// Keys a task actually needs to press. Setting a search field's value
    /// doesn't submit it — something has to send Return — and there is no menu
    /// item or button for that anywhere.
    ///
    /// Deliberately a closed list of navigation keys. This is not a general
    /// keystroke synthesiser: arbitrary key injection driven by a language
    /// model is a much larger blast radius than pressing what the app shows.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "space": 49, "delete": 51, "backspace": 51,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    @MainActor
    static func pressKey(_ a: ZeldaFlowAction,
                         context: CommandContext = CommandContext(expectedFrontmost: nil))
        async -> ActionOutcome {
        let wanted = (a.key ?? a.text ?? "").lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard let code = namedKeys[wanted] else {
            return ActionOutcome(ok: false, summary: "[press_key: unknown \(wanted)]",
                                 pillMessage: "Can't press “\(wanted)”")
        }
        guard target(context) != nil else { return focusMoved("press_key") }
        await TextInserter.pressKey(code)
        Log.info("press_key: \(wanted)")
        return ActionOutcome(ok: true, summary: "[pressed \(wanted)]", pillMessage: nil)
    }
}
