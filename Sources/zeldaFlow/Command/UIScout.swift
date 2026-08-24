import AppKit
import ApplicationServices

/// One command an app actually offers, discovered from its menu bar.
struct MenuCommand: Equatable {
    /// Full path as the user would navigate it, e.g. ["Format", "Font", "Bold"].
    let path: [String]
    /// The leaf title — what the user most likely said.
    var title: String { path.last ?? "" }
    let enabled: Bool
    /// Keyboard shortcut if the app advertises one ("⌘B"), for the pill.
    let shortcut: String?

    var display: String { path.joined(separator: " ▸ ") }
}

/// Reads what the frontmost app can *do*.
///
/// The insight this rests on: on macOS every application publishes its entire
/// command surface through the menu bar, and the Accessibility API can read
/// and press it. That makes the menu bar a universal automation API — one
/// mechanism that works in Pages, Xcode, Figma, Excel and an app written
/// yesterday, with no per-app scripting and no screenshots.
///
/// It also preserves the safety property from ADR 7: the model never writes
/// code or synthesises coordinates. It picks from a list of commands the app
/// itself declared, and we press exactly that.
enum UIScout {
    /// Per-element cap so one unresponsive app can't stall the walk. Matches
    /// the ScreenContext harvest budget for the same reason.
    private static let axTimeout: Float = 0.25
    private static let budget: TimeInterval = 1.2
    private static let maxCommands = 400

    /// Every enabled command in the frontmost app's menus.
    /// Excludes zeldaFlow itself — dictating into our own menus is never meant.
    static func menuCommands(for app: NSRunningApplication? = nil) -> [MenuCommand] {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return [] }

        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let raw = barRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
        let menuBar = raw as! AXUIElement

        guard let topLevel: [AXUIElement] = children(of: menuBar) else { return [] }

        var out: [MenuCommand] = []
        let deadline = Date().addingTimeInterval(budget)
        for item in topLevel {
            guard let title = title(of: item), !title.isEmpty else { continue }
            // The Apple menu is system-wide, not the app's own vocabulary.
            if title == "Apple" { continue }
            collect(item, path: [title], into: &out, deadline: deadline)
            if out.count >= maxCommands || Date() > deadline { break }
        }
        return out
    }

    /// Walk one menu, depth-first, gathering leaf commands.
    private static func collect(_ item: AXUIElement, path: [String],
                                into out: inout [MenuCommand], deadline: Date) {
        guard out.count < maxCommands, Date() < deadline, path.count <= 4 else { return }
        AXUIElementSetMessagingTimeout(item, axTimeout)

        // A menu-bar item owns exactly one child: its menu.
        guard let kids: [AXUIElement] = children(of: item), !kids.isEmpty else { return }
        for child in kids {
            guard Date() < deadline else { return }
            AXUIElementSetMessagingTimeout(child, axTimeout)

            // Separators have no title.
            guard let t = title(of: child), !t.isEmpty else {
                // A menu container: descend without adding a path segment.
                if role(of: child) == (kAXMenuRole as String) {
                    collect(child, path: path, into: &out, deadline: deadline)
                }
                continue
            }

            let grandkids: [AXUIElement] = children(of: child) ?? []
            if grandkids.isEmpty {
                // Leaf: a real command.
                out.append(MenuCommand(path: path + [t],
                                       enabled: enabled(of: child),
                                       shortcut: shortcut(of: child)))
            } else {
                // Submenu.
                collect(child, path: path + [t], into: &out, deadline: deadline)
            }
        }
    }

    /// Find the live element for a command path, so it can be pressed.
    static func element(for path: [String], in app: NSRunningApplication? = nil) -> AXUIElement? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let raw = barRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var current = raw as! AXUIElement

        for (depth, segment) in path.enumerated() {
            guard let kids: [AXUIElement] = children(of: current) else { return nil }
            var found: AXUIElement?
            for kid in kids {
                if title(of: kid) == segment { found = kid; break }
                // Menus wrap their items one level deeper.
                if title(of: kid) == nil, let inner: [AXUIElement] = children(of: kid) {
                    for deep in inner where title(of: deep) == segment { found = deep; break }
                }
            }
            guard let hit = found else { return nil }
            current = hit
            // Descend into the submenu for the next segment.
            if depth < path.count - 1, let inner: [AXUIElement] = children(of: hit), let first = inner.first {
                current = first
            }
        }
        return current
    }

    // MARK: - AX helpers

    private static func children(of el: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? [AXUIElement]
    }

    private static func title(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref) == .success
        else { return nil }
        let t = ref as? String
        return (t?.isEmpty ?? true) ? nil : t
    }

    private static func role(of el: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success
        else { return "" }
        return (ref as? String) ?? ""
    }

    private static func enabled(of el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &ref) == .success
        else { return true }
        return (ref as? Bool) ?? true
    }

    /// Reconstruct the displayed shortcut, e.g. "⌘B".
    private static func shortcut(of el: AXUIElement) -> String? {
        var cmdRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXMenuItemCmdCharAttribute as CFString, &cmdRef) == .success,
              let key = cmdRef as? String, !key.isEmpty else { return nil }
        var modRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(el, kAXMenuItemCmdModifiersAttribute as CFString, &modRef)
        let mods = (modRef as? Int) ?? 0
        // Bit flags per AXMenuItemCmdModifiers: 1 = shift, 2 = option, 4 = control,
        // and command is implied unless bit 8 clears it.
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + key.uppercased()
    }
}
