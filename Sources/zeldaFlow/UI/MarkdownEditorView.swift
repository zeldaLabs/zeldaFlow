import AppKit
import SwiftUI

/// Editable NSTextView host for raw markdown (the meeting notes edit mode).
/// SwiftUI's TextEditor never delivers keystrokes to the bound model on this
/// beta toolchain (same defect AppKitTextField works around), and
/// MarkdownRenderer is strictly one-way — so edit mode shows the raw
/// markdown in a plain text view and Done returns to the rendered preview.
struct MarkdownEditorView: NSViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    var onEscape: (() -> Void)?
    var autofocus = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Fixed pitch keeps list markers and table pipes aligned while typing.
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        // Smart quotes/dashes would silently corrupt markdown syntax.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Same geometry as AttributedTextView so toggling edit/preview
        // doesn't shift the page.
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scroll.documentView = textView
        if autofocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = view.documentView as? NSTextView else { return }
        // Never stomp what the user is mid-typing (the AppKitTextField rule):
        // while the text view is first responder, its buffer wins.
        guard textView.string != text else { return }
        if textView.window?.firstResponder !== textView {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)),
               let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            return false
        }
    }
}
