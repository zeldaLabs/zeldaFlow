import AppKit
import SwiftUI

/// AppKit-backed text field for the Hub's input rows. On this macOS beta the
/// SwiftUI TextField renders keystrokes but never delivers them to the bound
/// model (verified: field shows text, binding stays empty, Add stays
/// disabled) — NSTextField delegate callbacks are immune to that.
struct AppKitTextField: NSViewRepresentable {
    let placeholder: String
    var text: String
    var onChange: (String) -> Void
    var onSubmit: () -> Void = {}
    var onEscape: (() -> Void)?
    /// Borderless white-on-dark styling for the floating type bar.
    var darkStyle = false
    /// Borderless ink-on-transparent styling for the onboarding's paper
    /// design. Without it the field falls back to a bezeled system control,
    /// which follows the *system* appearance and renders as a black slab
    /// inside a deliberately light window whenever macOS is in Dark Mode.
    var paperStyle = false
    var autofocus = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        // Return is handled in doCommandBy(insertNewline:), which consumes
        // the event — but assistive tech submits via AXConfirm, which fires
        // the target/action instead. Wire both to the same onSubmit.
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitAction(_:))
        if darkStyle {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.textColor = .white
            field.font = .systemFont(ofSize: 14)
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45),
                             .font: NSFont.systemFont(ofSize: 14)])
        } else if paperStyle {
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.appearance = NSAppearance(named: .aqua)   // never follow a dark system
            field.textColor = NSColor(srgbRed: 0.08, green: 0.075, blue: 0.06, alpha: 1)
            field.font = .systemFont(ofSize: 15)
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor(srgbRed: 0.55, green: 0.52, blue: 0.47, alpha: 1),
                             .font: NSFont.systemFont(ofSize: 15)])
        } else {
            field.bezelStyle = .roundedBezel
            field.controlSize = .regular
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if autofocus {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard field.stringValue != text else { return }
        // Never stomp what the user is mid-typing; do push a programmatic
        // clear (after a successful Add) through to the field editor.
        if field.currentEditor() == nil {
            field.stringValue = text
        } else if text.isEmpty {
            field.stringValue = ""
            field.currentEditor()?.string = ""
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField
        init(_ parent: AppKitTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        /// AXConfirm (VoiceOver, UI scripting) lands here; keyboard Return
        /// is consumed in doCommandBy below, so this never double-fires.
        @objc func submitAction(_ sender: Any?) {
            parent.onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            return false
        }
    }
}
