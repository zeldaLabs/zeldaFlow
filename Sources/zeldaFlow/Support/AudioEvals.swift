import AVFoundation

/// Checks that recording gives the audio system back afterwards.
///
/// Apple's voice-processing unit is the reason this needs a test: while it's
/// in the graph macOS runs everything in voice mode, so output is ducked and
/// Bluetooth headphones drop to the hands-free profile. Nothing about that is
/// visible from inside the app — the only symptom is that music sounds quiet,
/// which is easy to blame on anything else.
enum AudioEvals {
    static func run() -> Int32 {
        print("zeldaFlow audio evals — voice processing must not outlive a recording")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task { @MainActor in
            code = await runAll()
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return code
    }

    @MainActor
    private static func runAll() async -> Int32 {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("    \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let recorder = AudioRecorder()
        recorder.voiceProcessing = true
        // Two minutes in production; the eval only needs to see it happen.
        recorder.idleReleaseDelay = 2

        print("\n  with echo cancellation on (the setting this user has):")
        check("starts clean", !recorder.voiceProcessingActive)

        let t0 = Date()
        do { try recorder.start() } catch {
            print("    SKIP: no microphone available (\(error.localizedDescription))")
            return 0
        }
        let coldMs = Int(Date().timeIntervalSince(t0) * 1000)

        // Which seamless property applies depends on what's plugged in, so the
        // eval reads the real topology and asserts the rule for it.
        let btOutput = AudioRecorder.defaultOutputDeviceID().map(AudioRecorder.isBluetooth)
            ?? false
        if btOutput {
            // Headphones: nothing may touch the audio system at all.
            check("Bluetooth headphones on → voice mode never engages",
                  !recorder.voiceProcessingActive,
                  "no ducking, no profile flip, start \(coldMs)ms")
        } else {
            check("speakers → voice processing engages", recorder.voiceProcessingActive,
                  "cold start \(coldMs)ms")
            check("system audio ducking is at minimum", recorder.duckingMinimised,
                  "music keeps playing while dictating")
        }

        // Either way, a Bluetooth *mic* must never be opened: doing so flips
        // the headset into the hands-free profile — the pause/quiet/return
        // cycle the user hears on every dictation.
        if let def = AudioRecorder.defaultInputDeviceID(), AudioRecorder.isBluetooth(def) {
            let btName = AudioRecorder.deviceName(def)
            check("Bluetooth default mic (\"\(btName)\") is not opened",
                  recorder.capturedDeviceName != btName,
                  "capturing \"\(recorder.capturedDeviceName)\" instead")
        } else {
            print("    · default input isn't Bluetooth — capturing "
                  + "\"\(recorder.capturedDeviceName)\"")
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = recorder.stop()

        if !btOutput {
            // Immediately after stopping it should still be warm, so dictating
            // again straight away doesn't pay to rebuild the graph.
            check("stays warm right after stopping", recorder.voiceProcessingActive)

            let t1 = Date()
            try? recorder.start()
            let warmMs = Int(Date().timeIntervalSince(t1) * 1000)
            _ = recorder.stop()
            print("      (warm restart \(warmMs)ms vs cold \(coldMs)ms — the warm path "
                  + "is why release is deferred)")

            // ...and once the user has actually walked away, it must let go.
            print("\n  after the idle delay:")
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            check("voice processing released — headphones back to normal",
                  !recorder.voiceProcessingActive)
        }

        // With the setting off it should never engage at all.
        print("\n  with echo cancellation off:")
        let plain = AudioRecorder()
        plain.voiceProcessing = false
        try? plain.start()
        check("never engages", !plain.voiceProcessingActive)
        _ = plain.stop()

        print(failures == 0
              ? "\nOK — recording leaves the audio system as it found it"
              : "\nFAIL — \(failures) problem(s)")
        return failures == 0 ? 0 : 1
    }
}
