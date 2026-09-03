import AppKit

/// Controlling Finder requires the user's Automation (Apple Events) consent.
///
/// The consent prompt is raised by actually *sending* an Apple Event while
/// the run loop is running — see AppDelegate. Deliberately no pre-flight
/// check here: `AEDeterminePermissionToAutomateTarget` called during launch
/// blocks the main thread and suppresses the very prompt we want, which
/// leaves the app absent from System Settings › Automation entirely.
enum FinderAutomation {
    /// Shown only after Finder has actually refused us (Apple Event -1743).
    static func presentDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Desktop Fences can’t control Finder"
        alert.informativeText = """
        Fences organize icons by asking Finder to move them, which needs your permission.

        Open System Settings › Privacy & Security › Automation, find Desktop Fences, and turn on Finder.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
