import Foundation
import ServiceManagement

/// Wraps `SMAppService` to register/unregister this app as a login item.
/// Requires the app to be running from a proper `.app` bundle — registration
/// fails harmlessly when run as a bare command-line binary.
enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success; false if the toggle couldn't be applied
    /// (e.g. not running from an installed .app bundle).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("Failed to \(enabled ? "register" : "unregister") launch-at-login: \(error)")
            return false
        }
    }
}
