import AppKit
import SwiftUI
import Combine

/// Bottom-center floating pill. Non-activating so the paste target keeps
/// focus; joins all Spaces and full-screen apps; pure indicator (no clicks).
/// A non-activating panel never becomes key before a click, so AppKit treats
/// every click as "first mouse" and drops it unless the view opts in.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PillPanel: NSPanel {
    /// True only while the type bar is open — the panel then takes key so
    /// the text field gets the keyboard, without activating zeldaFlow (the
    /// user's app stays frontmost, exactly like Spotlight).
    var allowsKey = false

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // SwiftUI draws its own shadow
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = FirstMouseHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    private var repositionRetry: DispatchWorkItem?
    /// The display the pill currently lives on. The pill is deliberately
    /// sticky: it changes screens ONLY when a recording starts on a
    /// different display (feedback belongs where the user is dictating) or
    /// when its own display disappears — never because the type bar opened,
    /// a phase changed, or an unrelated monitor was plugged in/out.
    private(set) var currentDisplayID: CGDirectDisplayID?

    /// Pretend the pill is on a given display, so the eval can exercise the
    /// "my monitor was unplugged" path without unplugging a monitor.
    func forceDisplayID(_ id: CGDirectDisplayID) { currentDisplayID = id }

    /// Where a positioning pass is allowed to put the panel.
    enum Placement: Equatable {
        /// Stay on the current display (recompute coordinates in case the
        /// arrangement rebased); fall back only if that display is gone.
        case keep
        /// Move to the frontmost app's window screen — recording start only.
        case follow
    }

    /// Resize + set interactivity for the current phase, keeping the panel
    /// bottom-centered. Small while idle so the clickable hover zone doesn't
    /// swallow clicks around it; large and click-through while active.
    func apply(width: CGFloat, height: CGFloat, clickable: Bool,
               placement: Placement = .keep) {
        setContentSize(NSSize(width: width, height: height))
        ignoresMouseEvents = !clickable
        positionBottomCenter(placement: placement)
    }

    /// The screen the pill belongs on. Dictation lands in the frontmost
    /// app's window, so at recording start its screen wins — with 2-3
    /// monitors the mouse often rests on a different display, and feedback
    /// there reads as "nothing happened". Every other transition keeps the
    /// pill where it is. NSScreen.main follows OUR key window, which a
    /// background accessory app never has — it's only the last-ditch
    /// fallback.
    private func targetScreen(placement: Placement) -> NSScreen? {
        let mouseScreen = { () -> NSScreen? in
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        }
        switch placement {
        case .keep:
            return currentScreen() ?? Self.frontmostWindowScreen() ?? mouseScreen()
                ?? NSScreen.main ?? NSScreen.screens.first
        case .follow:
            return Self.frontmostWindowScreen() ?? currentScreen() ?? mouseScreen()
                ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// The pill's current display, if it still exists in the arrangement.
    private func currentScreen() -> NSScreen? {
        guard let id = currentDisplayID else { return nil }
        return NSScreen.screens.first { Self.displayID(of: $0) == id }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Screen hosting the frontmost app's topmost normal window. Asks the
    /// window server (CGWindowList), never the app itself — unlike an AX
    /// query, a beachballing target can't stall us, so this is safe on the
    /// main thread that also services the Fn event tap.
    private static func frontmostWindowScreen() -> NSScreen? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                  as? [[String: Any]] else { return nil }
        let pid = Int(front.processIdentifier)
        // List is front-to-back; layer 0 filters out menu extras and overlays.
        guard let win = list.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int) == pid &&
                  ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let boundsDict = win[kCGWindowBounds as String],
              let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
              rect.width > 1, rect.height > 1 else { return nil }
        // CG coordinates are top-left-origin; NSScreen frames are bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let center = NSPoint(x: rect.midX, y: primaryHeight - rect.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    func positionBottomCenter(placement: Placement = .keep) {
        // A newer positioning supersedes any pending retry from a failed one.
        repositionRetry?.cancel()
        repositionRetry = nil
        guard let screen = targetScreen(placement: placement) else {
            // Display topology mid-change (docking, monitors handshaking):
            // the screen list can be momentarily empty. Retry once it
            // settles instead of stranding the panel at a dead origin.
            let retry = DispatchWorkItem { [weak self] in
                self?.positionBottomCenter(placement: placement)
            }
            repositionRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: retry)
            return
        }
        let previous = currentDisplayID
        currentDisplayID = Self.displayID(of: screen)
        if previous != currentDisplayID {
            Log.info("pill: display \(previous.map(String.init) ?? "none") → "
                     + "\(currentDisplayID.map(String.init) ?? "none") (\(placement))")
        }
        let vf = screen.visibleFrame
        let size = frame.size
        // Borderless panels skip AppKit's constrain pass — clamp inside the
        // screen ourselves so no coordinate rebase can push us off an edge.
        let x = max(vf.minX, min(vf.midX - size.width / 2, vf.maxX - size.width))
        setFrameOrigin(NSPoint(x: x, y: Self.bottomY(for: screen)))
    }

    /// How high off the bottom of a screen the pill rests.
    ///
    /// `visibleFrame` alone isn't enough. The Dock lives on one display at a
    /// time and migrates as you move the pointer, so anchoring to it made the
    /// pill sit 110pt up on the display holding the Dock and 20pt up on every
    /// other one — on an external monitor that reads as jammed into the bottom
    /// edge, which is exactly what it looked like.
    ///
    /// So: clear the Dock when it's there, and otherwise keep a resting height
    /// that matches what the Dock-bearing display gives, rather than hugging
    /// the glass.
    static func bottomY(for screen: NSScreen) -> CGFloat {
        let vf = screen.visibleFrame
        let dockInset = vf.minY - screen.frame.minY   // ~90 with a Dock, else 0
        let clearOfDock = dockInset + 20
        return screen.frame.minY + max(clearOfDock, restingHeight)
    }

    /// Chosen to match where the pill sits above a standard Dock, so it looks
    /// like the same app whichever display you glance at.
    private static let restingHeight: CGFloat = 90
}


@MainActor
final class PillController {
    static let shared = PillController()
    private var panel: PillPanel?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// One row of the pill's sizing/placement table.
    struct PillLayout: Equatable {
        var width: CGFloat
        var height: CGFloat
        var clickable: Bool
        var key: Bool
        var visible: Bool
        var placement: PillPanel.Placement
    }

    /// The whole sizing/placement decision as one pure function, so PillEvals
    /// pins the table instead of trusting a growing sink closure.
    ///
    /// INVARIANT (ADR 0018/0025): every MEETING-driven transition uses `.keep`
    /// — only dictation-recording may `.follow`. A meeting starting must never
    /// move the pill to another display. The chip also shows when the idle
    /// pill is off: consent visibility outranks the idle-pill preference — a
    /// recording with no visible indicator is the one thing auto-record must
    /// never produce (ADR 0027).
    static func layout(phase: AppState.Phase, meeting: MeetingCenter.UIPhase,
                       banner: MeetingCenter.Banner?, showIdlePill: Bool) -> PillLayout {
        switch phase {
        case .idle:
            if banner != nil {
                return PillLayout(width: 420, height: 56, clickable: true,
                                  key: false, visible: true, placement: .keep)
            }
            if case .idle = meeting {
                return PillLayout(width: 170, height: 40, clickable: true,
                                  key: false, visible: showIdlePill, placement: .keep)
            }
            // starting / recording / processing → the ambient meeting chip.
            return PillLayout(width: 232, height: 44, clickable: true,
                              key: false, visible: true, placement: .keep)
        case .typing:
            return PillLayout(width: 520, height: 70, clickable: true,
                              key: true, visible: true, placement: .keep)
        case .recording:
            // The one transition that may change screens: feedback belongs
            // on the display the user is dictating into.
            return PillLayout(width: 560, height: 120, clickable: false,
                              key: false, visible: true, placement: .follow)
        case .answer:
            // The one notice that invites a click: same footprint as a
            // notice, but the panel accepts the tap that expands it.
            return PillLayout(width: 560, height: 120, clickable: true,
                              key: false, visible: true, placement: .keep)
        case .chat:
            // The pill grown into the chat note. Takes key like the type bar
            // so the composer gets the keyboard without activating the app.
            return PillLayout(width: 640, height: 460, clickable: true,
                              key: true, visible: true, placement: .keep)
        default:
            // Processing/confirming/notice/success continue whatever
            // interaction placed the pill — stay put.
            return PillLayout(width: 560, height: 120, clickable: false,
                              key: false, visible: true, placement: .keep)
        }
    }

    func attach(state: AppState) {
        let view = PillView()
            .environmentObject(state)
            .environmentObject(AppSettings.shared)
        let panel = PillPanel(content: view)
        self.panel = panel

        state.$phase
            .combineLatest(AppSettings.shared.$showIdlePill,
                           MeetingCenter.shared.$uiPhase,
                           MeetingCenter.shared.$banner)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, showIdlePill, meetingPhase, banner in
                guard let panel = self?.panel else { return }
                let l = PillController.layout(phase: phase, meeting: meetingPhase,
                                              banner: banner, showIdlePill: showIdlePill)
                panel.allowsKey = l.key
                guard l.visible else {
                    panel.orderOut(nil)
                    return
                }
                panel.apply(width: l.width, height: l.height,
                            clickable: l.clickable, placement: l.placement)
                panel.orderFrontRegardless()
                if l.key { panel.makeKey() }
            }
            .store(in: &cancellables)

        // Monitors attached/removed/rearranged rebase global coordinates and
        // can leave the panel's frame on a display that no longer exists —
        // the app's only visible surface then vanishes. Once the
        // reconfiguration burst settles (the notification fires several
        // times per dock/undock), re-anchor IN PLACE: same display if it
        // survived, nearest live one only if it didn't.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.panel?.positionBottomCenter(placement: .keep)
            }
            .store(in: &cancellables)

        // Spotlight behavior: clicking anywhere else closes the type bar —
        // and the chat note, which took key the same way. Each guard is a
        // no-op unless its own phase is showing.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                AppState.shared.closeTypeBar()
                AppState.shared.closeChat()
            }
            .store(in: &cancellables)
    }
}
