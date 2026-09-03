import AppKit

/// Menu bar entry point. The menu is rebuilt each time it opens so the grid
/// spacing and packing state always show the right checkmarks.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let windowController: BinWindowController
    private let settingsWindowController = SettingsWindowController()

    private static let spacingPresets: [(name: String, value: Double)] = [
        ("Tight (80 pt)", 80),
        ("Compact (96 pt)", 96),
        ("Normal (112 pt)", 112),
        ("Roomy (128 pt)", 128),
        ("Wide (144 pt)", 144)
    ]

    init(windowController: BinWindowController) {
        self.windowController = windowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Desktop Bins")
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = SettingsStore.shared
        menu.removeAllItems()

        menu.addItem(withTitle: "New Bin", action: #selector(newBin), keyEquivalent: "n", target: self)
        menu.addItem(.separator())

        let snapItem = menu.addItem(withTitle: "Snap Icons to Grid", action: #selector(toggleSnap), keyEquivalent: "", target: self)
        snapItem.state = settings.snapEnabled ? .on : .off

        let packItem = menu.addItem(withTitle: "Pack Icons Without Gaps", action: #selector(togglePack), keyEquivalent: "", target: self)
        packItem.state = settings.packIcons ? .on : .off
        packItem.isEnabled = settings.snapEnabled

        let spacingItem = menu.addItem(withTitle: "Grid Spacing", action: nil, keyEquivalent: "", target: nil)
        let spacingMenu = NSMenu()
        for preset in Self.spacingPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(setSpacing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.value
            // Both axes share a preset; the Settings window tunes them separately.
            item.state = (settings.gridCellWidth == preset.value && settings.gridCellHeight == preset.value) ? .on : .off
            spacingMenu.addItem(item)
        }
        spacingMenu.addItem(.separator())
        spacingMenu.addItem(withTitle: "More Settings…", action: #selector(showSettings), keyEquivalent: "", target: self)
        spacingItem.submenu = spacingMenu
        spacingItem.isEnabled = settings.snapEnabled

        menu.addItem(.separator())
        menu.addItem(withTitle: "Arrange Icons Now", action: #selector(arrangeNow), keyEquivalent: "", target: self)
        menu.addItem(withTitle: "Restore All Icon Positions", action: #selector(restoreAll), keyEquivalent: "", target: self)
        menu.addItem(.separator())

        let visibilityTitle = windowController.isVisible ? "Hide All Bins" : "Show All Bins"
        menu.addItem(withTitle: visibilityTitle, action: #selector(toggleVisibility), keyEquivalent: "", target: self)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",", target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Desktop Bins", action: #selector(quit), keyEquivalent: "q", target: self)
    }

    @objc private func newBin() {
        windowController.addBinAtCenterOfMainScreen()
    }

    @objc private func toggleSnap() {
        SettingsStore.shared.snapEnabled.toggle()
    }

    @objc private func togglePack() {
        SettingsStore.shared.packIcons.toggle()
    }

    @objc private func setSpacing(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        let settings = SettingsStore.shared
        settings.gridCellWidth = value
        settings.gridCellHeight = value
    }

    @objc private func arrangeNow() {
        windowController.arrangeIconsNow()
    }

    @objc private func restoreAll() {
        windowController.restoreAllBins()
    }

    @objc private func toggleVisibility() {
        windowController.setAllVisible(!windowController.isVisible)
    }

    @objc private func showSettings() {
        settingsWindowController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
        return item
    }
}
