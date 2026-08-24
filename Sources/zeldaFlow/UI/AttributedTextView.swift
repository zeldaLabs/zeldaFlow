import AppKit
import SwiftUI

/// Read-only NSTextView host for rendered markdown (meeting notes). SwiftUI's
/// Text can't show an NSAttributedString with mixed fonts and keep native
/// selection/copy on this toolchain — NSTextView gives both for free.
struct AttributedTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // Horizontal breathing room comes from the page gutter; the 8 pt of
        // vertical inset keeps the first heading off the toolbar row.
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        (view.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
    }
}
