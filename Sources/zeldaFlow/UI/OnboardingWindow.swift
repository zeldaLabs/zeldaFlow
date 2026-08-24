import AppKit
import SwiftUI

/// First-run window host. The animated experience itself lives in
/// OnboardingCinematic.swift. The window (and with it the animation timers
/// and permission poll in the view) is torn down on close.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    private override init() {}

    var isNeeded: Bool {
        !Permissions.micGranted || !Permissions.accessibilityTrusted || !Paths.whisperModelExists
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Set Up zeldaFlow"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.backgroundColor = NSColor(srgbRed: 0.992, green: 0.988, blue: 0.980, alpha: 1)
            // The first run is a deliberately single-theme "paper" design, so
            // pin it to light — otherwise AppKit controls inside (text fields,
            // focus rings) render dark and fight the whole composition.
            w.appearance = NSAppearance(named: .aqua)
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingCinematicView()
                .environmentObject(AppState.shared))
            window = w
        }
        // Same stale-frame guard as the Hub window: a frame left on a
        // disconnected display would order in invisibly.
        if let w = window,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
            w.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the whole window so the SwiftUI view and its timers die.
        window?.contentView = nil
        window?.delegate = nil
        window = nil
    }
}
