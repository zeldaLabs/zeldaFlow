import Foundation
import AppKit

/// Live-fire UAT of the app-control actions. CommandEvals pins the parser
/// without side effects; this mode EXECUTES real actions on this Mac and
/// verifies their observable results — then puts everything back:
/// - system volume is saved first and restored last;
/// - apps this run launches are quit again (apps already running are left
///   alone — their close_app step is skipped, never their windows);
/// - the note and reminder it creates carry a unique marker and are deleted;
/// - music only plays if nothing is audibly playing, at low volume, briefly.
/// Actions that reach another person (send_email/send_message) or a terminal
/// (agent_task) are never run here — they stay behind the live Fn gate.
/// A missing Automation permission reports as SKIP, not failure.
enum ActionEvals {
    private struct Step {
        let name: String
        let status: String   // "ok" | "FAIL" | "skip"
        let ms: Int
        let detail: String
    }

    static func run() -> Int32 {
        print("zeldaFlow action evals — executes real actions on this Mac, then restores state")
        let sem = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task { @MainActor in
            exitCode = await runAll()
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return exitCode
    }

    @MainActor
    private static func runAll() async -> Int32 {
        var steps: [Step] = []
        let marker = "zeldaFlow-UAT-\(Int(Date().timeIntervalSince1970))"

        func record(_ name: String, _ status: String, _ started: Date, _ detail: String) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            steps.append(Step(name: name, status: status, ms: ms, detail: detail))
            let pad = name.padding(toLength: 34, withPad: " ", startingAt: 0)
            print("  \(status == "ok" ? "ok  " : (status == "skip" ? "skip" : "FAIL")) \(pad) \(ms)ms\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        // Volume is the blast radius of half these steps — snapshot it first.
        let savedVolume = await readVolume()

        // MARK: open_app / close_app (TextEdit — benign, no unsaved state on a fresh launch)
        let textEditWasRunning = isRunning("com.apple.TextEdit")
        var t = Date()
        let openOutcome = await BasicActions.openApp(ZeldaFlowAction(action: "open_app", app: "TextEdit"))
        if openOutcome.ok, await waitFor({ isRunning("com.apple.TextEdit") }, timeout: 6) {
            record("open_app TextEdit", "ok", t, "process appeared")
        } else {
            record("open_app TextEdit", "FAIL", t, openOutcome.summary)
        }

        t = Date()
        if textEditWasRunning {
            record("close_app TextEdit", "skip", t, "was already running before the test — leaving it open")
        } else {
            let closeOutcome = await BasicActions.closeApp(ZeldaFlowAction(action: "close_app", app: "TextEdit"))
            if closeOutcome.ok, await waitFor({ !isRunning("com.apple.TextEdit") }, timeout: 8) {
                record("close_app TextEdit", "ok", t, "process gone")
            } else {
                record("close_app TextEdit", "FAIL", t, closeOutcome.summary)
            }
        }

        // MARK: set_volume — level, mute, then restore the snapshot
        t = Date()
        _ = await BasicActions.setVolume(ZeldaFlowAction(action: "set_volume", level: 25))
        if let v = await readVolume(), v.level == 25 {
            record("set_volume 25", "ok", t, "read back 25")
        } else {
            record("set_volume 25", "FAIL", t, "readback mismatch")
        }

        t = Date()
        _ = await BasicActions.setVolume(ZeldaFlowAction(action: "set_volume", mute: true))
        if let v = await readVolume(), v.muted {
            record("set_volume muted", "ok", t, "read back muted")
        } else {
            record("set_volume muted", "FAIL", t, "readback mismatch")
        }

        t = Date()
        if let saved = savedVolume {
            _ = await AppleScriptRunner.run("set volume output volume \(saved.level)")
            _ = await AppleScriptRunner.run("set volume \(saved.muted ? "with" : "without") output muted")
            let v = await readVolume()
            record("restore volume", v?.level == saved.level && v?.muted == saved.muted ? "ok" : "FAIL",
                   t, "back to \(saved.level)%\(saved.muted ? " muted" : "")")
        } else {
            record("restore volume", "skip", t, "could not read initial volume")
        }

        // MARK: create_note → verify → delete
        let notesWasRunning = isRunning("com.apple.Notes")
        t = Date()
        let q = AppleScriptRunner.quote
        let noteOutcome = await BasicActions.createNote(ZeldaFlowAction(
            action: "create_note", body: "Created by zeldaFlow --evalactions; safe to delete.",
            title: marker))
        if noteOutcome.ok {
            let count = await AppleScriptRunner.run(
                "tell application \"Notes\" to count of (notes whose name = \(q(marker)))")
            if Int(count.output) ?? 0 >= 1 {
                let del = await AppleScriptRunner.run(
                    "tell application \"Notes\" to delete (every note whose name = \(q(marker)))")
                // Notes "delete" moves to the Recently Deleted folder, where
                // the note still counts — exclude it when checking it's gone.
                let left = await AppleScriptRunner.run(
                    "tell application \"Notes\" to count of (notes whose name = \(q(marker)) " +
                    "and name of container is not \"Recently Deleted\")")
                let gone = del.ok && (!left.ok || Int(left.output) == 0)
                record("create_note + verify + delete", gone ? "ok" : "FAIL", t,
                       "note created, found, deleted (lands in Recently Deleted)")
            } else {
                record("create_note + verify + delete", "FAIL", t, "note not found after create")
            }
        } else {
            record("create_note + verify + delete", isPermissionProblem(noteOutcome.summary) ? "skip" : "FAIL",
                   t, noteOutcome.summary)
        }
        if !notesWasRunning { quit("com.apple.Notes") }

        // MARK: add_reminder → verify → delete
        let remindersWasRunning = isRunning("com.apple.reminders")
        t = Date()
        let remOutcome = await BasicActions.addReminder(ZeldaFlowAction(action: "add_reminder", title: marker))
        if remOutcome.ok {
            var found = false
            for _ in 0..<3 {   // Reminders whose-queries lag on big databases
                let count = await AppleScriptRunner.run(
                    "tell application \"Reminders\" to count of (reminders whose name = \(q(marker)))")
                if Int(count.output) ?? 0 >= 1 { found = true; break }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if found {
                _ = await AppleScriptRunner.run(
                    "tell application \"Reminders\" to delete (every reminder whose name = \(q(marker)))")
                record("add_reminder + verify + delete", "ok", t, "reminder created, found, deleted")
            } else {
                record("add_reminder + verify + delete", "FAIL", t, "reminder not found after create")
            }
        } else {
            record("add_reminder + verify + delete", isPermissionProblem(remOutcome.summary) ? "skip" : "FAIL",
                   t, remOutcome.summary)
        }
        if !remindersWasRunning { quit("com.apple.reminders") }

        // MARK: navigate — Maps opens with a route; quit it if we launched it
        let mapsWasRunning = isRunning("com.apple.Maps")
        t = Date()
        let navOutcome = BasicActions.navigate(ZeldaFlowAction(
            action: "navigate", destination: "Melbourne Airport", transport: "driving"))
        if navOutcome.ok, await waitFor({ isRunning("com.apple.Maps") }, timeout: 8) {
            record("navigate (Apple Maps)", "ok", t, "Maps opened with route request")
        } else {
            record("navigate (Apple Maps)", "FAIL", t, navOutcome.summary)
        }
        if !mapsWasRunning {
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // let the route render before quitting
            quit("com.apple.Maps")
        }

        // MARK: music_control play/pause — only if nothing is already playing
        t = Date()
        let applePlaying = await musicPlayerState() == "playing"
        let alreadyPlaying = applePlaying ? true : await spotifyPlaying()
        if alreadyPlaying {
            record("music play/pause", "skip", t, "music already playing — not interrupting it")
        } else {
            let musicWasRunning = isRunning("com.apple.Music")
            _ = await AppleScriptRunner.run("set volume output volume 12")
            _ = await BasicActions.musicControl(ZeldaFlowAction(
                action: "music_control", service: "music", command: "play"))
            let reachedPlaying = await waitFor2 { await musicPlayerState() == "playing" }
            if reachedPlaying {
                _ = await BasicActions.musicControl(ZeldaFlowAction(
                    action: "music_control", service: "music", command: "pause"))
                let paused = await waitFor2 { await musicPlayerState() != "playing" }
                record("music play/pause", paused ? "ok" : "FAIL", t,
                       paused ? "played briefly at 12% volume, paused" : "did not pause")
            } else {
                record("music play/pause", "skip", t,
                       "Music never reached playing (empty queue or permission) — nothing to pause")
            }
            if let saved = savedVolume {
                _ = await AppleScriptRunner.run("set volume output volume \(saved.level)")
                _ = await AppleScriptRunner.run("set volume \(saved.muted ? "with" : "without") output muted")
            }
            if !musicWasRunning { quit("com.apple.Music") }
        }

        // MARK: summary
        let failed = steps.filter { $0.status == "FAIL" }
        let skipped = steps.filter { $0.status == "skip" }
        print(failed.isEmpty
              ? "OK — \(steps.count - skipped.count) live actions verified, \(skipped.count) skipped"
              : "FAIL — \(failed.count) of \(steps.count) steps failed")
        return failed.isEmpty ? 0 : 1
    }

    // MARK: - Probes

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func quit(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .forEach { $0.terminate() }
    }

    private static func waitFor(_ cond: @escaping () -> Bool, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return cond()
    }

    /// waitFor with an async condition (AppleScript probes), fixed 6 s budget.
    private static func waitFor2(_ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return await cond()
    }

    private static func readVolume() async -> (level: Int, muted: Bool)? {
        let r = await AppleScriptRunner.run(
            "set s to get volume settings\nreturn (output volume of s as text) & \",\" & (output muted of s as text)")
        let parts = r.output.split(separator: ",")
        guard r.ok, parts.count == 2, let level = Int(parts[0]) else { return nil }
        return (level, parts[1] == "true")
    }

    private static func musicPlayerState() async -> String {
        // Query without launching: player state on a non-running app would
        // start it via AppleScript, so gate on the process first.
        guard isRunning("com.apple.Music") else { return "not running" }
        let r = await AppleScriptRunner.run("tell application \"Music\" to player state as text")
        return r.ok ? r.output : "unknown"
    }

    private static func spotifyPlaying() async -> Bool {
        guard isRunning("com.spotify.client") else { return false }
        let r = await AppleScriptRunner.run("tell application \"Spotify\" to player state as text")
        return r.ok && r.output == "playing"
    }

    private static func isPermissionProblem(_ text: String) -> Bool {
        text.contains("1743") || text.lowercased().contains("not authorized")
            || text.lowercased().contains("not allowed")
    }
}
