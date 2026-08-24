import AppKit

/// Which key drives dictation. Fn by default, but any key can be bound.
///
/// macOS splits keys into two event families and the monitor has to treat
/// them differently:
///   * **Modifiers** (Fn, Caps Lock, ⌃⌥⇧⌘) never produce keyDown/keyUp — they
///     report through `.flagsChanged`, and "is it down?" means "is my flag
///     set in the event's flags?".
///   * **Normal keys** (F13, §, …) produce `.keyDown` / `.keyUp`, and repeat
///     while held, so auto-repeat has to be filtered out.
/// `flagMask != 0` is what distinguishes the two.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: Int64
    /// `CGEventFlags` raw value for modifier keys; 0 for normal keys.
    var flagMask: UInt64
    /// What to show the user ("fn", "F13", "right ⌥").
    var label: String

    var isModifier: Bool { flagMask != 0 }

    static let fn = HotkeyBinding(keyCode: 63,
                                  flagMask: CGEventFlags.maskSecondaryFn.rawValue,
                                  label: "fn")

    /// Modifier keycodes worth binding, with the flag each one toggles.
    /// Left/right variants are separate keycodes but share a flag, which is
    /// exactly what lets someone bind *right* option and keep *left* option
    /// working normally.
    static let modifierFlags: [Int64: (mask: CGEventFlags, label: String)] = [
        63: (.maskSecondaryFn, "fn"),
        57: (.maskAlphaShift, "caps lock"),
        56: (.maskShift, "left ⇧"),
        60: (.maskShift, "right ⇧"),
        59: (.maskControl, "left ⌃"),
        62: (.maskControl, "right ⌃"),
        58: (.maskAlternate, "left ⌥"),
        61: (.maskAlternate, "right ⌥"),
        55: (.maskCommand, "left ⌘"),
        54: (.maskCommand, "right ⌘"),
    ]

    /// Build a binding from a captured event, or nil if the key is unusable.
    static func from(keyCode: Int64, characters: String?) -> HotkeyBinding? {
        if let mod = modifierFlags[keyCode] {
            return HotkeyBinding(keyCode: keyCode, flagMask: mod.mask.rawValue, label: mod.label)
        }
        // Binding a key that types a character would make that character
        // impossible to type — refuse, and steer the user to a safe key.
        guard let label = nonTypingLabels[keyCode] else { return nil }
        return HotkeyBinding(keyCode: keyCode, flagMask: 0, label: label)
    }

    /// Keys that are safe to swallow because they don't insert text. Function
    /// keys, and the extra keys that exist mainly to be bound to something.
    static let nonTypingLabels: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        114: "help", 115: "home", 119: "end", 116: "page up", 121: "page down",
    ]

    /// Human-readable list for the settings hint.
    static var suggestions: String {
        "fn · caps lock · right ⌥ · right ⌘ · F13–F20"
    }
}
