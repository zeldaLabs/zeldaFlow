import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a login-item launch plus a manual open must not
        // fight over the event tap and llama-server port.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            Log.info("another instance is running, exiting")
            NSApp.terminate(nil)
            return
        }

        Log.info("zeldaFlow launching (bundle: \(Bundle.main.bundlePath))")
        let state = AppState.shared
        StatusBarController.shared.setUp()
        PillController.shared.attach(state: state)
        state.bootstrap()

        if OnboardingWindowController.shared.isNeeded || !state.settings.onboardingCompleted {
            OnboardingWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
        Log.info("zeldaFlow terminated")
    }
}
