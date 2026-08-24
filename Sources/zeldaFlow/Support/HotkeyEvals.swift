import Foundation
import AppKit
import CoreGraphics

/// Checks that pressing the hotkey is answered immediately, and that the
/// gestures built on top of it still mean what they used to.
///
/// This exists because of a specific failure. The tap callback used to run on
/// the main run loop and call the delegate synchronously, so a press ran
/// `AudioRecorder.start()` inline — 845 ms cold on this machine. An active
/// head-insert tap holds the whole system's keyboard stream while its callback
/// runs, so that press stalled the keyboard, a second press landed in the dead
/// window and was lost, and a slow enough callback got the tap torn out by the
/// OS (`.tapDisabledByTimeout`) until the 5 s watchdog noticed. It felt like a
/// hotkey that lagged, ignored double-taps, and sometimes just didn't fire.
///
/// The first check below is the one that matters: it blocks the main thread
/// outright and measures the callback anyway. Under the old design that
/// measurement was the block duration, by construction.
///
/// Run with `zeldaFlow --evalhotkey`. Needs no permissions — events are
/// synthesised and handed to the callback directly, so the real tap is never
/// installed and the user's keyboard is never touched.
enum HotkeyEvals {
    @MainActor
    private final class Spy: HotkeyMonitorDelegate {
        weak var monitor: HotkeyMonitor?
        var events: [String] = []
        var beginSucceeds = true

        func reset() { events = [] }

        func hotkeySessionShouldBegin() -> Bool {
            events.append("begin")
            guard beginSucceeds else { return false }
            // Exactly what AppState does: the phase change mirrors into the
            // monitor so the tap thread can answer "is a session live?".
            monitor?.phaseChanged(recording: true, typeBarOpen: false)
            return true
        }

        private func end(_ name: String) {
            events.append(name)
            monitor?.phaseChanged(recording: false, typeBarOpen: false)
        }

        func hotkeyHoldEnded() { end("holdEnded") }
        func hotkeyTapDiscarded() { end("tapDiscarded") }
        func hotkeyHandsFreeStarted() { events.append("handsFreeStarted") }
        func hotkeyHandsFreeEnded() { end("handsFreeEnded") }
        func hotkeyCommandModeStarted() { events.append("commandModeStarted") }
        func hotkeyCommandEnded() { end("commandEnded") }
        func confirmationApproved() { events.append("confirmationApproved") }
        func confirmationCancelled() { events.append("confirmationCancelled") }
        func hotkeySessionDirtied() { end("sessionDirtied") }
        func escapePressed() { end("escapePressed") }
    }

    static func run() -> Int32 {
        print("zeldaFlow hotkey evals — the press must be answered immediately")
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        // The driver runs off-main, which is where the tap thread lives now.
        // That leaves the real main thread free to be the app's main thread —
        // and, in the first check, to be deliberately blocked.
        Thread.detachNewThread {
            code = runAll()
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return code
    }

    // MARK: - Driver (background thread)

    private static var failures = 0

    private static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        print("    \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func onMain<T>(_ body: @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private static func runAll() -> Int32 {
        failures = 0
        let monitor = HotkeyMonitor()
        let spy = onMain { Spy() }
        onMain {
            spy.monitor = monitor
            monitor.delegate = spy
        }
        monitor.updateBinding(.fn)

        // Events are synthesised once and replayed; a private-state source
        // keeps them out of the real event stream.
        let source = CGEventSource(stateID: .privateState)
        func fn(down: Bool) -> CGEvent {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: down)!
            event.type = .flagsChanged
            event.flags = down ? .maskSecondaryFn : []
            return event
        }
        func key(_ code: CGKeyCode) -> CGEvent {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)!
        }
        @discardableResult
        func send(_ event: CGEvent, _ type: CGEventType = .flagsChanged) -> Bool {
            monitor.handleForEval(type: type, event: event)
        }
        func settle(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
        func delivered(_ expected: [String], within timeout: TimeInterval = 1.5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if onMain({ spy.events }) == expected { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return false
        }
        func seen() -> String {
            let events = onMain { spy.events }
            return events.isEmpty ? "(nothing)" : events.joined(separator: " → ")
        }
        func fresh() {
            // Effects are delivered with main.async, so a main.sync is a
            // barrier for everything already queued. Without it a late
            // "begin" lands after the reset and re-arms the mirror.
            onMain {}
            monitor.sessionWasReset()
            monitor.phaseChanged(recording: false, typeBarOpen: false)
            onMain { spy.reset() }
        }

        func timePress() -> Double {
            let t0 = Date()
            send(fn(down: true))
            return Date().timeIntervalSince(t0) * 1000
        }

        // 1. The whole point. Time the callback with the main thread free,
        //    then again with it blocked outright — a pill re-render, a
        //    transcription kicking off, the session start itself. The two
        //    numbers should be the same, because main is no longer on this
        //    path at all. Under the old design the second one *was* the block
        //    duration, by construction.
        print("\n  with the main thread blocked (the old failure mode):")
        // One warm-up press first: the first trip through any dispatch/CG
        // path pays one-time setup that says nothing about steady state.
        send(fn(down: true)); send(fn(down: false)); fresh()

        let freeMs = timePress()
        send(fn(down: false))
        fresh()

        let blockSeconds: TimeInterval = 0.5
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: blockSeconds) }
        settle(0.03)  // let the block actually take hold
        let blockedMs = timePress()
        check("a blocked main thread doesn't delay the press", blockedMs < 5,
              String(format: "%.3f ms blocked vs %.3f ms free (main blocked %.0f ms)",
                     blockedMs, freeMs, blockSeconds * 1000))

        // ...and the gesture that spans the block is not lost.
        settle(blockSeconds)
        send(fn(down: false))
        check("the press that spanned the block still completed",
              delivered(["begin", "holdEnded"]), seen())
        fresh()

        // 2. Hold, tap, double-tap, triple-tap still mean what they meant.
        print("\n  gestures:")
        send(fn(down: true))
        settle(0.35)                       // over minHoldSeconds (0.3)
        send(fn(down: false))
        check("hold ≥ 0.3 s → push-to-talk finishes",
              delivered(["begin", "holdEnded"]), seen())
        fresh()

        send(fn(down: true))
        settle(0.1)                        // under minHoldSeconds
        send(fn(down: false))
        check("lone short tap → audio discarded after the window",
              delivered(["begin", "tapDiscarded"], within: 1.5), seen())
        fresh()

        send(fn(down: true))
        settle(0.1)
        send(fn(down: false))
        settle(0.15)                       // inside doubleTapWindow (0.6)
        send(fn(down: true))
        check("double-tap → hands-free arms",
              delivered(["begin", "handsFreeStarted"]), seen())
        send(fn(down: false))
        settle(0.15)                       // inside commandUpgradeWindow (0.6)
        send(fn(down: true))
        check("third tap → command mode",
              delivered(["begin", "handsFreeStarted", "commandModeStarted"]), seen())
        send(fn(down: false))
        settle(0.1)
        send(fn(down: true))
        check("press in command mode → runs the command",
              delivered(["begin", "handsFreeStarted", "commandModeStarted", "commandEnded"]),
              seen())
        send(fn(down: false))
        fresh()

        // 3. A session that can't start must leave nothing armed behind — the
        //    press is optimistic now, so the unwind is load-bearing.
        print("\n  when the session can't start:")
        onMain { spy.beginSucceeds = false }
        send(fn(down: true))
        settle(0.05)
        send(fn(down: false))
        check("failed start delivers no phantom finish",
              delivered(["begin"], within: 1.2), seen())
        onMain { spy.beginSucceeds = true }
        fresh()
        send(fn(down: true))
        settle(0.35)
        send(fn(down: false))
        check("the next press starts cleanly",
              delivered(["begin", "holdEnded"]), seen())
        fresh()

        // 4. Swallowing. The tap eats the bound key so macOS never sees a
        //    globe press; Esc is only eaten when there's something to cancel.
        print("\n  what reaches the rest of the system:")
        check("the bound key never leaks to macOS", send(fn(down: true)))
        send(fn(down: false))
        fresh()

        check("Esc passes through when nothing is live",
              !send(key(53), .keyDown), "apps keep their own Esc")
        onMain { spy.reset() }
        monitor.phaseChanged(recording: true, typeBarOpen: false)
        check("Esc is swallowed and cancels while recording",
              send(key(53), .keyDown) && delivered(["escapePressed"]), seen())
        fresh()

        // fn+arrow is a system combo, not the start of a dictation.
        send(fn(down: true))
        settle(0.05)
        send(key(126), .keyDown)           // up arrow
        check("fn+arrow cancels the session instead of dictating",
              delivered(["begin", "sessionDirtied"]), seen())
        send(fn(down: false))
        fresh()

        // While Settings is capturing a new binding the tap must stand down
        // entirely, or it eats the very keypress being recorded.
        monitor.isSuspended = true
        check("suspended → the key reaches Settings untouched", !send(fn(down: true)))
        monitor.isSuspended = false
        send(fn(down: false))
        fresh()

        // 5. Sustained input: every press must still be answered in
        //    microseconds, not just the first one.
        print("\n  under sustained input:")
        var worstMs = 0.0
        var total = 0.0
        let rounds = 200
        for i in 0..<rounds {
            let down = i % 2 == 0
            let event = fn(down: down)
            let t0 = Date()
            send(event)
            let ms = Date().timeIntervalSince(t0) * 1000
            worstMs = max(worstMs, ms)
            total += ms
        }
        check("callback stays microsecond-scale", worstMs < 5,
              String(format: "%d events, mean %.3f ms, worst %.3f ms",
                     rounds, total / Double(rounds), worstMs))
        fresh()
        settle(0.7)  // let the last discard timer drain before we tear down

        print(failures == 0
              ? "\nOK — the press is answered immediately and the gestures hold"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }
}
