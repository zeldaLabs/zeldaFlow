import AppKit
import ApplicationServices

/// A control in the frontmost window that can be clicked or typed into.
struct UIControl: Equatable {
    let label: String
    /// AX role, e.g. AXButton, AXTextField, AXCheckBox.
    let role: String
    let enabled: Bool
    /// Index among same-labelled controls, so duplicates stay addressable.
    let ordinal: Int

    var kind: String {
        switch role {
        case "AXButton", "AXMenuButton": return "button"
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return "field"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "menu"
        case "AXLink": return "link"
        default: return "control"
        }
    }

    var display: String { "\(label) (\(kind))" }
}

/// Reads and drives the controls inside the frontmost window.
///
/// The menu bar (see UIScout) covers an app's *commands*; this covers its
/// *interface* — the Search field, the Get button, the checkbox. Together they
/// are what "do the thing in this app" actually requires, because plenty of
/// what a person wants has no menu equivalent at all.
///
/// Same safety property throughout: we enumerate what the app declares and act
/// on one of those elements. Nothing is clicked by coordinate, so a moved or
/// re-laid-out window can't cause a stray click somewhere unintended.
enum UIControls {
    private static let axTimeout: Float = 0.25
    private static let budget: TimeInterval = 1.0
    private static let maxControls = 250

    /// Interactive controls in the focused window, in visual order.
    static func inFocusedWindow(of app: NSRunningApplication? = nil) -> [UIControl] {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return [] }
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let raw = winRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }

        var found: [(UIControl, AXUIElement)] = []
        var counts: [String: Int] = [:]
        walk(raw as! AXUIElement, depth: 0, deadline: Date().addingTimeInterval(budget)) { el in
            guard let role = string(el, kAXRoleAttribute), interesting.contains(role) else { return }
            guard let label = bestLabel(el), !label.isEmpty else { return }
            let ordinal = counts[label, default: 0]
            counts[label] = ordinal + 1
            found.append((UIControl(label: label, role: role,
                                    enabled: bool(el, kAXEnabledAttribute) ?? true,
                                    ordinal: ordinal), el))
        }
        return found.map(\.0)
    }

    /// Re-find a control now, so we act on the live element rather than a
    /// stale reference from when the list was built.
    static func element(for control: UIControl, in app: NSRunningApplication? = nil) -> AXUIElement? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let raw = winRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }

        var seen = 0
        var hit: AXUIElement?
        walk(raw as! AXUIElement, depth: 0, deadline: Date().addingTimeInterval(budget)) { el in
            guard hit == nil,
                  string(el, kAXRoleAttribute) == control.role,
                  bestLabel(el) == control.label else { return }
            if seen == control.ordinal { hit = el }
            seen += 1
        }
        return hit
    }

    /// Roles worth offering. Static text and groups are structure, not actions.
    private static let interesting: Set<String> = [
        "AXButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXLink",
    ]

    private static func walk(_ el: AXUIElement, depth: Int, deadline: Date,
                             _ visit: (AXUIElement) -> Void) {
        guard depth < 22, Date() < deadline else { return }
        AXUIElementSetMessagingTimeout(el, axTimeout)
        visit(el)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement] else { return }
        for kid in kids {
            guard Date() < deadline else { return }
            walk(kid, depth: depth + 1, deadline: deadline, visit)
        }
    }

    /// Apps label controls inconsistently — try every attribute a human would read.
    private static func bestLabel(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXValueAttribute, kAXPlaceholderValueAttribute] {
            if let s = string(el, attr), !s.isEmpty, s.count < 60 { return s }
        }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    // MARK: - Acting

    /// Click a control.
    @discardableResult
    static func press(_ control: UIControl, in app: NSRunningApplication? = nil) -> Bool {
        guard let el = element(for: control, in: app) else { return false }
        return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Put text into a field (replacing what's there) and focus it.
    @discardableResult
    static func setValue(_ text: String, in control: UIControl,
                         app: NSRunningApplication? = nil) -> Bool {
        guard let el = element(for: control, in: app) else { return false }
        return setValue(text, into: el)
    }

    @discardableResult
    static func setValue(_ text: String, into el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
        return AXUIElementSetAttributeValue(
            el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Title of the focused window — the cheapest signal that a step actually
    /// changed something ("Apps" → "Slack" after clicking a search result).
    static func focusedWindowTitle(of app: NSRunningApplication? = nil) -> String? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let raw = winRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return string(raw as! AXUIElement, kAXTitleAttribute)
    }

    /// The text field or area that currently has the caret, with its label.
    ///
    /// When the user doesn't name a field, this is the answer they meant —
    /// "type this" goes where the cursor already is. Scanning the window and
    /// picking among several unnamed boxes would be a guess; the focus ring
    /// is the app telling us outright.
    static func focusedField(of app: NSRunningApplication? = nil) -> (UIControl, AXUIElement)? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let el = raw as! AXUIElement
        guard let role = string(el, kAXRoleAttribute) else { return nil }
        let control = UIControl(label: string(el, kAXTitleAttribute)
                                    ?? string(el, kAXDescriptionAttribute) ?? "focused field",
                                role: role,
                                enabled: bool(el, kAXEnabledAttribute) ?? true,
                                ordinal: 0)
        return control.kind == "field" ? (control, el) : nil
    }
}
