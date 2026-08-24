import Foundation
import AVFoundation
import ApplicationServices
import Carbon
import AppKit

enum Permissions {
    // MARK: Microphone

    static var micGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var micDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    static func requestMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Accessibility (needed for the suppressing event tap + synthetic Cmd-V)

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilityPane() {
        openPane("Privacy_Accessibility")
    }

    static func openMicrophonePane() {
        openPane("Privacy_Microphone")
    }

    private static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Screen Recording (needed for "look at my screen" agent commands)

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt on first call; afterwards the user must flip
    /// the toggle in System Settings (and relaunch zeldaFlow for it to stick).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingPane() {
        openPane("Privacy_ScreenCapture")
    }

    // MARK: System audio capture (meeting notetaker's "Them" channel)

    /// There is no TCC query API for system-audio capture, so status is
    /// inferred and cached: a probe tap that starts and delivers frames means
    /// granted; kAudioHardwareIllegalOperationError at any step means denied
    /// (the same inference OpenWhispr ships). Every real tap start reconciles
    /// the cache in both directions — see SystemAudioTap.probePermission.
    enum SystemAudioPermission: String { case unknown, granted, denied }

    static var systemAudio: SystemAudioPermission {
        SystemAudioPermission(rawValue:
            UserDefaults.standard.string(forKey: "systemAudioPermission") ?? "") ?? .unknown
    }

    static func setSystemAudio(_ s: SystemAudioPermission) {
        UserDefaults.standard.set(s.rawValue, forKey: "systemAudioPermission")
    }

    static func openSystemAudioPane() {
        // macOS 15 hosts "System Audio Recording Only" grants inside the
        // Screen & System Audio Recording pane — there is no dedicated anchor.
        openPane("Privacy_ScreenCapture")
    }

    // MARK: Secure input (password fields) — synthetic events are rejected while active.

    static var secureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: Fn key system action
    // 0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation.
    // Our event tap suppresses the key before HIToolbox sees it, so any value works;
    // we surface this in onboarding as belt-and-suspenders info only.

    static var fnUsageType: Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                  "com.apple.HIToolbox" as CFString) as? Int
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
