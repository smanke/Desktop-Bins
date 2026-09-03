import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: FenceStore!
    private var windowController: FenceWindowController!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = FenceStore()
        windowController = FenceWindowController(store: store)
        statusItemController = StatusItemController(windowController: windowController)

        if store.fences.isEmpty {
            windowController.addFenceAtCenterOfMainScreen()
        }

        // Send a real Apple Event once the run loop is going: that is what
        // actually raises macOS's "wants to control Finder" prompt. Asking
        // during launch (or via a blocking modal) suppresses it entirely.
        DispatchQueue.main.async {
            _ = FinderDesktopController.currentDesktopItems()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
