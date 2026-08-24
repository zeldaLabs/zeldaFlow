import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Only meaningful when running from a real
/// .app bundle (not `swift run`).
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.error("LoginItem: \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
