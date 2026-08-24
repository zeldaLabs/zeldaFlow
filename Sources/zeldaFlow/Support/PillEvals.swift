import AppKit
import SwiftUI

/// Measures where the pill actually lands across the transitions a user makes,
/// on the displays actually attached.
///
/// The pill is the app's only visible surface, so "it moved" is not cosmetic —
/// on a multi-display Mac it's the difference between seeing feedback and
/// believing nothing happened. This asserts the two properties that matter:
/// it stays horizontally centred on its own screen, and it does not change
/// screens except when it is supposed to.
enum PillEvals {
    static func run() -> Int32 {
        print("zeldaFlow pill-position evals")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var failures = 0
        let panel = PillPanel(content: Color.clear.frame(maxWidth: .infinity,
                                                         maxHeight: .infinity))

        print("\n  displays:")
        for (i, s) in NSScreen.screens.enumerated() {
            print("    \(i): frame=\(short(s.frame)) visible=\(short(s.visibleFrame))")
        }
        guard !NSScreen.screens.isEmpty else { print("no screens"); return 1 }

        func screenOf(_ p: PillPanel) -> NSScreen? {
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { CGDirectDisplayID($0.uint32Value) } == p.currentDisplayID
            }
        }

        /// Centred within half a point, and sitting on the bottom margin.
        func check(_ label: String, _ p: PillPanel) {
            guard let s = screenOf(p) else {
                print("    ✗ \(label): pill is on no known display")
                failures += 1
                return
            }
            let vf = s.visibleFrame
            let wantX = vf.midX - p.frame.width / 2
            let wantY = PillPanel.bottomY(for: s)
            let dx = abs(p.frame.minX - wantX), dy = abs(p.frame.minY - wantY)
            let ok = dx < 0.5 && dy < 0.5
            print("    \(ok ? "✓" : "✗") \(label): frame=\(short(p.frame)) "
                  + "on display \(p.currentDisplayID.map(String.init) ?? "?")"
                  + (ok ? "" : "  OFF BY dx=\(round(dx)) dy=\(round(dy))"))
            if !ok { failures += 1 }
        }

        // The exact sequence a user performs: idle pill, click to type, close,
        // dictate, back to idle. Sizes mirror PillController.attach.
        print("\n  transitions (sizes as PillController applies them):")
        panel.apply(width: 170, height: 40, clickable: true, placement: .keep)
        check("idle", panel)
        let idleDisplay = panel.currentDisplayID

        panel.allowsKey = true
        panel.apply(width: 520, height: 70, clickable: true, placement: .keep)
        check("typing (the reported bug)", panel)

        panel.allowsKey = false
        panel.apply(width: 170, height: 40, clickable: true, placement: .keep)
        check("back to idle", panel)

        panel.apply(width: 560, height: 120, clickable: false, placement: .keep)
        check("processing", panel)

        panel.apply(width: 170, height: 40, clickable: true, placement: .keep)
        check("idle again", panel)

        let ok = panel.currentDisplayID == idleDisplay
        print("    \(ok ? "✓" : "✗") stayed on the same display through all of it")
        if !ok { failures += 1 }

        // Simulate what a monitor change does: the reposition pass that
        // didChangeScreenParameters triggers must land it centred again.
        print("\n  after a display-parameter change:")
        panel.positionBottomCenter(placement: .keep)
        check("re-anchored in place", panel)

        // Every attached display in turn. This is where the arithmetic really
        // differs — a secondary display can sit at a negative origin, and a
        // window placed there is exactly what AppKit's constrain pass likes to
        // drag back onto the primary.
        print("\n  placed on each attached display, then shown and made key:")
        for (i, s) in NSScreen.screens.enumerated() {
            let vf = s.visibleFrame
            let want = NSPoint(x: vf.midX - panel.frame.width / 2,
                               y: PillPanel.bottomY(for: s))

            panel.setFrameOrigin(want)
            let afterPlace = panel.frame.origin

            // The real app always follows positioning with these two calls, and
            // the type bar takes key. If AppKit constrains a borderless panel,
            // this is where the pill would jump.
            panel.orderFrontRegardless()
            let afterOrder = panel.frame.origin
            panel.allowsKey = true
            panel.makeKey()
            let afterKey = panel.frame.origin
            panel.allowsKey = false

            print("    display \(i) visible=\(short(vf))")
            print("        wanted    \(pt(want))")
            print("        placed    \(pt(afterPlace))"
                  + (near(afterPlace, want) ? "" : "   ← setFrameOrigin moved it"))
            print("        ordered   \(pt(afterOrder))"
                  + (near(afterOrder, afterPlace) ? "" : "   ← orderFront moved it"))
            print("        made key  \(pt(afterKey))"
                  + (near(afterKey, afterOrder) ? "" : "   ← makeKey moved it"))

            if !near(afterPlace, want) || !near(afterOrder, afterPlace)
                || !near(afterKey, afterOrder) {
                print("        ✗ the panel was constrained away from where it was put")
                failures += 1
            } else {
                print("        ✓ stayed exactly where it was put")
            }
        }
        panel.orderOut(nil)

        // The unplug path: the display the pill lives on no longer exists.
        // Can't physically remove a monitor here, so drive the same code by
        // parking it on a display ID that isn't in the arrangement.
        print("\n  when the pill's own display disappears:")
        panel.forceDisplayID(0xDEAD_BEEF)
        panel.positionBottomCenter(placement: .keep)
        if let s = screenOf(panel) {
            print("    ✓ recovered onto a live display \(short(s.visibleFrame))")
            check("centred after recovery", panel)
        } else {
            print("    ✗ pill did not recover onto any live display")
            failures += 1
        }

        // And the resize-before-reposition ordering: growing the type bar must
        // never leave the pill anchored by its left edge.
        print("\n  type bar grows symmetrically:")
        panel.apply(width: 170, height: 40, clickable: true, placement: .keep)
        let idleCentre = panel.frame.midX
        panel.apply(width: 520, height: 70, clickable: true, placement: .keep)
        let barCentre = panel.frame.midX
        let centred = abs(idleCentre - barCentre) < 0.5
        print("    \(centred ? "✓" : "✗") centre held at "
              + "\(Int(idleCentre)) → \(Int(barCentre))")
        if !centred { failures += 1 }

        // The reported symptom: on a second monitor the pill sits far lower
        // than it does on the built-in. Anchoring to visibleFrame alone makes
        // the resting height depend on whether the Dock happens to be on that
        // display — 110pt up with a Dock, 20pt up without. On an external
        // screen that reads as "stuck at the bottom".
        print("\n  resting height is consistent across displays:")
        var heights: [(Int, CGFloat)] = []
        for (i, s) in NSScreen.screens.enumerated() {
            let y = PillPanel.bottomY(for: s)
            let lift = y - s.frame.minY
            let dockInset = s.visibleFrame.minY - s.frame.minY
            heights.append((i, lift))
            print("    display \(i): dock inset \(Int(dockInset))pt → "
                  + "pill sits \(Int(lift))pt above the screen bottom")
        }
        if let lo = heights.map(\.1).min(), let hi = heights.map(\.1).max() {
            let consistent = hi - lo < 40
            print("    \(consistent ? "✓" : "✗") spread across displays: \(Int(hi - lo))pt")
            if !consistent { failures += 1 }
        }
        for (i, lift) in heights where lift < 40 {
            print("    ✗ display \(i) leaves the pill only \(Int(lift))pt off the bottom edge")
            failures += 1
        }

        // The meeting rows of the layout table: sizes are cosmetic, placement
        // is not — a meeting chip that follows focus would drag the pill to
        // another display mid-call, the exact bug class the ADR 0018/0025
        // stickiness rule closed.
        print("\n  meeting layout table:")
        failures += meetingLayoutFailures()

        print(failures == 0
              ? "\nOK — pill stays centred and stays put"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }

    /// Pins PillController.layout's meeting-driven rows (ADR 0027). run() is
    /// already on the main thread (dispatched from main.swift before the app
    /// loop), so assumeIsolated is a statement of fact, not a hop.
    private static func meetingLayoutFailures() -> Int {
        MainActor.assumeIsolated {
            var failures = 0
            func check(_ label: String, _ ok: Bool) {
                print("    \(ok ? "✓" : "✗") \(label)")
                if !ok { failures += 1 }
            }
            typealias L = PillController
            let rec = MeetingCenter.UIPhase.recording(started: Date(), micHealthy: true)

            var l = L.layout(phase: .idle, meeting: .idle, banner: nil, showIdlePill: true)
            check("idle + idle → 170 wide, visible, .keep",
                  l.width == 170 && l.visible && l.placement == .keep)
            l = L.layout(phase: .idle, meeting: rec, banner: nil, showIdlePill: false)
            check("meeting chip: 232×44, visible even with the idle pill off, .keep",
                  l.width == 232 && l.height == 44 && l.visible && l.placement == .keep)
            l = L.layout(phase: .idle, meeting: rec, banner: .started(app: "Zoom"),
                         showIdlePill: true)
            check("banner outranks the chip: 420 wide, .keep",
                  l.width == 420 && l.placement == .keep)
            l = L.layout(phase: .recording(mode: .pushToTalk), meeting: rec, banner: nil,
                         showIdlePill: true)
            check("dictation recording is the ONLY .follow row (560×120)",
                  l.width == 560 && l.height == 120 && l.placement == .follow)
            l = L.layout(phase: .answer("x"), meeting: .idle, banner: nil, showIdlePill: true)
            check("answer pill: notice footprint but clickable, no key, .keep",
                  l.width == 560 && l.height == 120 && l.clickable && !l.key
                  && l.placement == .keep)
            l = L.layout(phase: .chat, meeting: .idle, banner: nil, showIdlePill: true)
            check("chat note: 640×460, clickable, takes key, .keep",
                  l.width == 640 && l.height == 460 && l.clickable && l.key
                  && l.placement == .keep)

            // Exhaustive: any non-idle meeting state × any non-dictation
            // phase × any banner must keep its display.
            let phases: [AppState.Phase] = [.idle, .typing, .processing,
                                            .confirming("x"), .notice("x"),
                                            .answer("x"), .chat, .success]
            let meetings: [MeetingCenter.UIPhase] = [
                .starting, rec, .recording(started: Date(), micHealthy: false),
                .processing(step: "Transcribing…"),
            ]
            let banners: [MeetingCenter.Banner?] = [nil, .started(app: "Zoom"),
                                                    .finished(title: "T"), .micOnly]
            var moved = 0, rows = 0
            for phase in phases {
                for meeting in meetings {
                    for banner in banners {
                        for show in [true, false] {
                            rows += 1
                            if L.layout(phase: phase, meeting: meeting, banner: banner,
                                        showIdlePill: show).placement != .keep {
                                moved += 1
                            }
                        }
                    }
                }
            }
            check("all \(rows) meeting-driven rows keep their display (\(moved) would move)",
                  moved == 0)
            return failures
        }
    }

    private static func pt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }

    private static func short(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }
}
