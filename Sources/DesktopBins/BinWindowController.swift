import AppKit

/// Owns the windows backing each bin and keeps them in sync with the
/// store. Every bin is three windows: a visual backdrop below the desktop
/// icons, plus two small hit targets above them (title bar, resize corner).
final class BinWindowController: NSObject, BinHitViewDelegate {
    private struct BinWindows {
        let backdrop: BinWindow
        let titleBar: BinWindow
        let resizeHandle: BinWindow

        var all: [BinWindow] { [backdrop, titleBar, resizeHandle] }
    }

    private let store: BinStore
    private var windows: [UUID: BinWindows] = [:]
    private var expandedHeights: [UUID: Double] = [:]
    private var gestureStartFrame: NSRect?
    private var gridSnapTimer: Timer?
    private(set) var isVisible = true

    /// Serializes every Finder script call; NSAppleScript is not thread safe.
    private let finderQueue = DispatchQueue(label: "com.smanke.DesktopBins.finder")
    private var dragMembers: [BinMember] = []
    private var dragUpdateInFlight = false
    private var lastDragUpdate = Date.distantPast
    private static let dragUpdateInterval: TimeInterval = 0.05

    private static let minBinWidth: CGFloat = 140
    private static let minBinHeight: CGFloat = 120
    private static let gridMargin: Double = 8
    private static let gridSnapInterval: TimeInterval = 1.5

    init(store: BinStore) {
        self.store = store
        super.init()
        store.onChange = { [weak self] in self?.syncWindows() }
        syncWindows()
        gridSnapTimer = Timer.scheduledTimer(withTimeInterval: Self.gridSnapInterval, repeats: true) { [weak self] _ in
            self?.performGridSnapPass()
        }
        // Re-lay out as soon as a setting changes, rather than on the next tick.
        SettingsStore.shared.onChange = { [weak self] in
            self?.performGridSnapPass()
        }

        // Monitors being attached, detached or rearranged moves bins back to
        // their own display, or parks them until it returns.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        adoptCurrentDisplayForUnpinnedBins()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenConfigurationChanged() {
        syncWindows()
        performGridSnapPass()
    }

    /// Layouts saved before per-display positions existed only have absolute
    /// coordinates; attach each of those to whichever display it is sitting
    /// on now, so it starts travelling with that monitor.
    private func adoptCurrentDisplayForUnpinnedBins() {
        for var bin in store.bins where bin.displayUUID == nil {
            let frame = NSRect(x: bin.x, y: bin.y, width: bin.width, height: bin.height)
            pinToDisplay(&bin, frame: frame)
            if bin.displayUUID != nil {
                store.updateBin(bin)
            }
        }
    }

    // MARK: - Window lifecycle

    func syncWindows() {
        let currentIDs = Set(store.bins.map(\.id))

        for (id, set) in windows where !currentIDs.contains(id) {
            set.all.forEach { $0.close() }
            windows.removeValue(forKey: id)
        }

        for bin in store.bins {
            let set: BinWindows
            if let existing = windows[bin.id] {
                (existing.backdrop.contentView as? BinBackdropView)?.bin = bin
                set = existing
            } else {
                set = makeWindows(for: bin)
                windows[bin.id] = set
            }

            // A bin whose display is currently detached stays in the store
            // but off screen, ready for when that monitor comes back.
            guard let frame = frameOf(bin) else {
                set.all.forEach { $0.orderOut(nil) }
                continue
            }
            layout(set: set, bin: bin, frame: frame)
            if isVisible {
                set.backdrop.orderFront(nil)
                set.titleBar.orderFront(nil)
                if !bin.isCollapsed { set.resizeHandle.orderFront(nil) }
            }
        }
    }

    private func makeWindows(for bin: Bin) -> BinWindows {
        let frame = frameOf(bin) ?? NSRect(x: bin.x, y: bin.y, width: bin.width, height: bin.height)

        let backdrop = BinWindow(contentRect: frame, role: .backdrop)
        let backdropView = BinBackdropView(bin: bin)
        backdropView.frame = NSRect(origin: .zero, size: frame.size)
        backdrop.contentView = backdropView

        let titleBar = BinWindow(contentRect: titleBarFrame(for: frame), role: .chrome)
        let titleBarView = BinHitView(kind: .titleBar, binID: bin.id)
        titleBarView.delegate = self
        titleBar.contentView = titleBarView

        let resizeHandle = BinWindow(contentRect: resizeHandleFrame(for: frame), role: .chrome)
        let resizeView = BinHitView(kind: .resizeHandle, binID: bin.id)
        resizeView.delegate = self
        resizeHandle.contentView = resizeView

        return BinWindows(backdrop: backdrop, titleBar: titleBar, resizeHandle: resizeHandle)
    }

    /// Where a bin should sit right now. When it is pinned to a display,
    /// its stored offset is resolved against that display's current origin,
    /// so rearranging monitors doesn't drag bins around with the coordinate
    /// space. Returns nil when the bin's display isn't attached.
    private func frameOf(_ bin: Bin) -> NSRect? {
        if let uuid = bin.displayUUID {
            guard let screen = DisplayIdentity.screen(withUUID: uuid) else { return nil }
            let originX = screen.frame.origin.x + CGFloat(bin.relativeX ?? 0)
            let originY = screen.frame.origin.y + CGFloat(bin.relativeY ?? 0)
            return NSRect(x: originX, y: originY, width: bin.width, height: bin.height)
        }
        return NSRect(x: bin.x, y: bin.y, width: bin.width, height: bin.height)
    }

    /// Records which display a bin now sits on, storing its position as an
    /// offset within that display.
    private func pinToDisplay(_ bin: inout Bin, frame: NSRect) {
        bin.x = Double(frame.origin.x)
        bin.y = Double(frame.origin.y)
        bin.width = Double(frame.width)
        bin.height = Double(frame.height)

        guard let screen = DisplayIdentity.screen(containing: frame),
              let uuid = DisplayIdentity.uuid(for: screen) else {
            bin.displayUUID = nil
            bin.relativeX = nil
            bin.relativeY = nil
            return
        }
        bin.displayUUID = uuid
        bin.relativeX = Double(frame.origin.x - screen.frame.origin.x)
        bin.relativeY = Double(frame.origin.y - screen.frame.origin.y)
    }

    private func titleBarFrame(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - BinMetrics.titleBarHeight, width: frame.width, height: BinMetrics.titleBarHeight)
    }

    private func resizeHandleFrame(for frame: NSRect) -> NSRect {
        NSRect(
            x: frame.maxX - BinMetrics.resizeHandleSize,
            y: frame.minY,
            width: BinMetrics.resizeHandleSize,
            height: BinMetrics.resizeHandleSize
        )
    }

    /// Positions the whole window set to match a bin frame.
    private func layout(set: BinWindows, bin: Bin, frame: NSRect? = nil) {
        guard let frame = frame ?? frameOf(bin) else { return }
        set.backdrop.setFrame(frame, display: true)
        set.backdrop.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        set.backdrop.contentView?.needsDisplay = true
        set.titleBar.setFrame(titleBarFrame(for: frame), display: true)

        if bin.isCollapsed {
            set.resizeHandle.orderOut(nil)
        } else {
            set.resizeHandle.setFrame(resizeHandleFrame(for: frame), display: true)
            if isVisible { set.resizeHandle.orderFront(nil) }
        }
    }

    func setAllVisible(_ visible: Bool) {
        isVisible = visible
        for (id, set) in windows {
            let collapsed = store.bins.first { $0.id == id }?.isCollapsed ?? false
            for window in set.all {
                if visible {
                    if window === set.resizeHandle && collapsed { continue }
                    window.orderFront(nil)
                } else {
                    window.orderOut(nil)
                }
            }
        }
    }

    func addBinAtCenterOfMainScreen() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 260
        let height: CGFloat = 240
        let colors = ["3B82F6", "10B981", "F59E0B", "EF4444", "8B5CF6", "EC4899"]
        let frame = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
        var bin = Bin(
            title: "New Bin",
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(width),
            height: Double(height),
            colorHex: colors[store.bins.count % colors.count]
        )
        pinToDisplay(&bin, frame: frame)
        store.addBin(bin)
    }

    private func bin(for id: UUID) -> Bin? {
        store.bins.first { $0.id == id }
    }

    // MARK: - BinHitViewDelegate

    func binHitViewDidBeginGesture(_ view: BinHitView) {
        let frame = windows[view.binID]?.backdrop.frame
        gestureStartFrame = frame
        dragMembers = []

        // Snapshot what's inside the bin so the drag can shift those icons
        // live. Done off the main thread so mouse-down isn't stalled by the
        // Apple Event round trip.
        guard view.kind == .titleBar,
              let frame,
              let screenHeight = primaryScreenHeight() else { return }

        let startRect = finderSpaceRect(for: frame, screenHeight: screenHeight)
        finderQueue.async { [weak self] in
            let members = FinderDesktopController.currentDesktopItems()
                .filter { startRect.contains(NSPoint(x: $0.x, y: $0.y)) }
                .map { BinMember(name: $0.name, x: $0.x, y: $0.y) }
            DispatchQueue.main.async { self?.dragMembers = members }
        }
    }

    func binHitView(_ view: BinHitView, didDragBy delta: CGSize) {
        guard let start = gestureStartFrame,
              let set = windows[view.binID],
              let bin = bin(for: view.binID) else { return }

        let newFrame: NSRect
        switch view.kind {
        case .titleBar:
            newFrame = NSRect(
                x: start.origin.x + delta.width,
                y: start.origin.y + delta.height,
                width: start.width,
                height: start.height
            )
        case .resizeHandle:
            let width = max(Self.minBinWidth, start.width + delta.width)
            let height = max(Self.minBinHeight, start.height - delta.height)
            newFrame = NSRect(x: start.origin.x, y: start.maxY - height, width: width, height: height)
        }

        layout(set: set, bin: bin, frame: newFrame)

        if view.kind == .titleBar {
            dragIconsAlongside(delta: delta)
        }
    }

    /// Shifts the captured icons to track the bin while it's being dragged.
    /// Throttled, and overlapping frames are dropped, because each update is
    /// an Apple Event round trip to Finder.
    private func dragIconsAlongside(delta: CGSize) {
        guard !dragMembers.isEmpty, !dragUpdateInFlight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDragUpdate) >= Self.dragUpdateInterval else { return }

        lastDragUpdate = now
        dragUpdateInFlight = true
        let shifted = shiftedMembers(dragMembers, delta: delta)
        finderQueue.async { [weak self] in
            FinderDesktopController.setPositions(shifted)
            DispatchQueue.main.async { self?.dragUpdateInFlight = false }
        }
    }

    /// AppKit's y grows upward, Finder's desktop coordinates grow downward.
    private func shiftedMembers(_ members: [BinMember], delta: CGSize) -> [BinMember] {
        members.map { BinMember(name: $0.name, x: $0.x + Double(delta.width), y: $0.y - Double(delta.height)) }
    }

    func binHitViewDidEndGesture(_ view: BinHitView) {
        let startFrame = gestureStartFrame
        gestureStartFrame = nil
        guard var bin = bin(for: view.binID), let set = windows[view.binID] else { return }
        let frame = set.backdrop.frame

        if view.kind == .titleBar, let startFrame, startFrame.origin != frame.origin {
            let delta = CGSize(width: frame.origin.x - startFrame.origin.x, height: frame.origin.y - startFrame.origin.y)
            if dragMembers.isEmpty {
                // The snapshot didn't finish in time; fall back to a direct read.
                moveContainedIcons(from: startFrame, to: frame, bin: &bin)
            } else {
                // Land the icons exactly, since throttling may have dropped
                // the last few drag frames.
                let settled = shiftedMembers(dragMembers, delta: delta)
                finderQueue.async { FinderDesktopController.setPositions(settled) }
                bin.members = settled
            }
        }
        dragMembers = []

        // Dragging a bin can carry it to another monitor, so re-record which
        // display owns it and where it sits within that display.
        pinToDisplay(&bin, frame: frame)
        (set.backdrop.contentView as? BinBackdropView)?.bin = bin
        store.updateBin(bin)
    }

    func binHitViewRequestsToggleCollapse(_ view: BinHitView) {
        guard var bin = bin(for: view.binID), let set = windows[view.binID] else { return }
        let frame = set.backdrop.frame
        bin.isCollapsed.toggle()

        let newHeight: CGFloat
        if bin.isCollapsed {
            expandedHeights[bin.id] = Double(frame.height)
            newHeight = BinMetrics.titleBarHeight
        } else {
            newHeight = CGFloat(expandedHeights[bin.id] ?? 240)
        }

        let newFrame = NSRect(x: frame.minX, y: frame.maxY - newHeight, width: frame.width, height: newHeight)
        pinToDisplay(&bin, frame: newFrame)

        (set.backdrop.contentView as? BinBackdropView)?.bin = bin
        layout(set: set, bin: bin, frame: newFrame)
        store.updateBin(bin)
    }

    func binHitViewContextMenu(_ view: BinHitView) -> NSMenu {
        buildMenu(for: view.binID)
    }

    /// A file dropped onto the bin's chrome (title bar or resize corner)
    /// would otherwise be rejected, since those strips sit above Finder's
    /// icon layer. Place it into the cell the user aimed at instead.
    func binHitView(_ view: BinHitView, didDropFileURLs urls: [URL], atScreenPoint screenPoint: NSPoint) {
        guard let set = windows[view.binID],
              let screenHeight = primaryScreenHeight(),
              let metrics = gridMetrics(forFrame: set.backdrop.frame, screenHeight: Double(screenHeight)) else { return }

        // Only items already on the desktop can simply be repositioned;
        // anything else would have to be moved on disk first.
        let desktopPath = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath().path
        let names = urls.compactMap { url -> String? in
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == desktopPath else { return nil }
            return url.lastPathComponent
        }
        guard !names.isEmpty else { return }

        let finderPoint = NSPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        let col = clamp(Int(((Double(finderPoint.x) - metrics.originX) / metrics.cellWidth).rounded()), 0, metrics.maxCols - 1)
        let row = clamp(Int(((Double(finderPoint.y) - metrics.originY) / metrics.cellHeight).rounded()), 0, metrics.maxRows - 1)
        let targetX = metrics.originX + Double(col) * metrics.cellWidth
        let targetY = metrics.originY + Double(row) * metrics.cellHeight

        // Land them a little ahead of the target cell so the layout pass
        // sorts them into that slot and shifts the existing icons along,
        // rather than dropping them on top of whatever is already there.
        let placements = names.enumerated().map { index, name in
            BinMember(name: name, x: targetX - 24 + Double(index), y: targetY)
        }

        finderQueue.async { [weak self] in
            FinderDesktopController.setPositions(placements)
            DispatchQueue.main.async { self?.performGridSnapPass() }
        }
    }

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    // MARK: - Menu

    private func buildMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        guard let bin = bin(for: id) else { return menu }

        menu.addItem(withActionTitle: bin.isCollapsed ? "Expand Bin" : "Collapse Bin") { [weak self] in
            guard let self, let view = self.windows[id]?.titleBar.contentView as? BinHitView else { return }
            self.binHitViewRequestsToggleCollapse(view)
        }
        menu.addItem(withActionTitle: "Rename Bin…") { [weak self] in
            self?.renameBin(id)
        }
        menu.addItem(withActionTitle: "Change Color…") { [weak self] in
            self?.changeColor(id)
        }
        menu.addItem(.separator())
        let captureTitle = bin.members.isEmpty
            ? "Save Icon Layout"
            : "Save Icon Layout (\(bin.members.count) saved)"
        menu.addItem(withActionTitle: captureTitle) { [weak self] in
            self?.captureIcons(id)
        }
        let restoreItem = menu.addItem(withActionTitle: "Restore Saved Layout") { [weak self] in
            self?.restoreIcons(id)
        }
        restoreItem.isEnabled = !bin.members.isEmpty
        menu.addItem(.separator())
        menu.addItem(withActionTitle: "Delete Bin") { [weak self] in
            self?.deleteBin(id)
        }
        return menu
    }

    private func renameBin(_ id: UUID) {
        guard var bin = bin(for: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bin"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = bin.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        bin.title = trimmed.isEmpty ? bin.title : trimmed
        (windows[id]?.backdrop.contentView as? BinBackdropView)?.bin = bin
        store.updateBin(bin)
    }

    private var colorTargetID: UUID?

    private func changeColor(_ id: UUID) {
        guard let bin = bin(for: id) else { return }
        colorTargetID = id
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = NSColor(hex: bin.colorHex)
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let id = colorTargetID, var bin = bin(for: id) else { return }
        bin.colorHex = sender.color.hexString
        (windows[id]?.backdrop.contentView as? BinBackdropView)?.bin = bin
        store.updateBin(bin)
    }

    private func deleteBin(_ id: UUID) {
        guard let bin = bin(for: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(bin.title)”?"
        alert.informativeText = "This removes the bin. Nothing on your desktop is deleted or moved."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeBin(id: id)
        }
    }

    /// Moving a bin carries the icons inside it along, so a bin acts as a
    /// real container rather than a backdrop icons happen to sit on. The
    /// icons haven't moved during the drag, so membership is decided by
    /// testing their current positions against where the bin started.
    private func moveContainedIcons(from startFrame: NSRect, to endFrame: NSRect, bin: inout Bin) {
        guard let screenHeight = primaryScreenHeight() else { return }
        let startRect = finderSpaceRect(for: startFrame, screenHeight: screenHeight)
        let contained = FinderDesktopController.currentDesktopItems().filter {
            startRect.contains(NSPoint(x: $0.x, y: $0.y))
        }
        guard !contained.isEmpty else { return }

        let dx = Double(endFrame.origin.x - startFrame.origin.x)
        let dy = Double(endFrame.origin.y - startFrame.origin.y)
        // AppKit's y grows upward, Finder's desktop coordinates grow downward.
        let moved = contained.map { BinMember(name: $0.name, x: $0.x + dx, y: $0.y - dy) }

        FinderDesktopController.setPositions(moved)
        bin.members = moved
    }

    // MARK: - Icon capture / restore

    private func captureIcons(_ id: UUID) {
        guard var bin = bin(for: id),
              let set = windows[id],
              let screenHeight = primaryScreenHeight() else { return }

        let rect = finderSpaceRect(for: set.backdrop.frame, screenHeight: screenHeight)
        let matched = FinderDesktopController.currentDesktopItems().filter {
            rect.contains(NSPoint(x: $0.x, y: $0.y))
        }
        bin.members = matched.map { BinMember(name: $0.name, x: $0.x, y: $0.y) }
        store.updateBin(bin)
    }

    private func restoreIcons(_ id: UUID) {
        guard let bin = bin(for: id) else { return }
        FinderDesktopController.setPositions(bin.members)
    }

    /// Forces an immediate layout pass instead of waiting for the timer.
    func arrangeIconsNow() {
        performGridSnapPass()
    }

    func restoreAllBins() {
        for bin in store.bins {
            FinderDesktopController.setPositions(bin.members)
        }
    }

    private func primaryScreenHeight() -> CGFloat? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
    }

    /// Finder reports desktop positions top-left-origin; AppKit windows are
    /// bottom-left-origin. The returned rect is in Finder's space.
    private func finderSpaceRect(for frame: NSRect, screenHeight: CGFloat) -> NSRect {
        NSRect(x: frame.origin.x, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: - Live grid snapping

    private struct GridMetrics {
        let originX: Double
        let originY: Double
        let cellWidth: Double
        let cellHeight: Double
        let maxCols: Int
        let maxRows: Int
    }

    /// Finds icons sitting inside each expanded bin and nudges any that
    /// are off-grid onto that bin's grid, so a dropped or rearranged icon
    /// settles into place the way Finder's own desktop grid behaves.
    private func performGridSnapPass() {
        // Don't reshuffle icons while a bin is mid-drag or mid-resize.
        guard gestureStartFrame == nil, SettingsStore.shared.snapEnabled else { return }
        guard !store.bins.isEmpty, let screenHeight = primaryScreenHeight() else { return }
        let allItems = FinderDesktopController.currentDesktopItems()
        guard !allItems.isEmpty else { return }

        var updates: [BinMember] = []

        for bin in store.bins {
            guard let set = windows[bin.id], !bin.isCollapsed else { continue }
            let frame = set.backdrop.frame
            guard let metrics = gridMetrics(forFrame: frame, screenHeight: Double(screenHeight)) else { continue }

            let rect = finderSpaceRect(for: frame, screenHeight: screenHeight)
            let inside = allItems.filter { rect.contains(NSPoint(x: $0.x, y: $0.y)) }
            guard !inside.isEmpty else { continue }

            let placements = SettingsStore.shared.packIcons
                ? packedPlacements(for: inside, metrics: metrics)
                : nearestCellPlacements(for: inside, metrics: metrics)

            for (item, col, row) in placements {
                let targetX = metrics.originX + Double(col) * metrics.cellWidth
                let targetY = metrics.originY + Double(row) * metrics.cellHeight
                if abs(targetX - item.x) > 2 || abs(targetY - item.y) > 2 {
                    updates.append(BinMember(name: item.name, x: targetX, y: targetY))
                }
            }
        }

        if !updates.isEmpty {
            FinderDesktopController.setPositions(updates)
        }
    }

    private func gridMetrics(forFrame frame: NSRect, screenHeight: Double) -> GridMetrics? {
        let settings = SettingsStore.shared
        let cellWidth = settings.gridCellWidth
        let cellHeight = settings.gridCellHeight

        let top = screenHeight - Double(frame.maxY) + Double(BinMetrics.titleBarHeight)
        let usableWidth = Double(frame.width) - 2 * Self.gridMargin
        let usableHeight = Double(frame.height) - Double(BinMetrics.titleBarHeight) - 2 * Self.gridMargin
        guard usableWidth >= cellWidth, usableHeight >= cellHeight else { return nil }

        return GridMetrics(
            originX: Double(frame.origin.x) + Self.gridMargin + cellWidth / 2,
            originY: top + Self.gridMargin + cellHeight / 2,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            maxCols: max(1, Int(usableWidth / cellWidth)),
            maxRows: max(1, Int(usableHeight / cellHeight))
        )
    }

    private typealias Placement = (item: FinderDesktopController.Item, col: Int, row: Int)

    /// Keeps each icon in whichever cell it was dropped nearest, so gaps the
    /// user left between icons are preserved.
    private func nearestCellPlacements(for items: [FinderDesktopController.Item], metrics: GridMetrics) -> [Placement] {
        var occupied = Set<[Int]>()
        var placements: [Placement] = []

        for item in items {
            let rawCol = Int(((item.x - metrics.originX) / metrics.cellWidth).rounded())
            let rawRow = Int(((item.y - metrics.originY) / metrics.cellHeight).rounded())
            var col = min(max(rawCol, 0), metrics.maxCols - 1)
            var row = min(max(rawRow, 0), metrics.maxRows - 1)

            if occupied.contains([col, row]) {
                guard let free = nearestFreeCell(col: col, row: row, metrics: metrics, occupied: occupied) else {
                    continue // grid full — leave this icon alone
                }
                col = free.0
                row = free.1
            }
            occupied.insert([col, row])
            placements.append((item, col, row))
        }
        return placements
    }

    /// Refills the bin from its top-left in reading order, leaving no
    /// empty cells between icons.
    private func packedPlacements(for items: [FinderDesktopController.Item], metrics: GridMetrics) -> [Placement] {
        let ordered = items.sorted { lhs, rhs in
            let lhsRow = Int(((lhs.y - metrics.originY) / metrics.cellHeight).rounded())
            let rhsRow = Int(((rhs.y - metrics.originY) / metrics.cellHeight).rounded())
            if lhsRow != rhsRow { return lhsRow < rhsRow }
            return lhs.x < rhs.x
        }

        var placements: [Placement] = []
        for (index, item) in ordered.enumerated() {
            let col = index % metrics.maxCols
            let row = index / metrics.maxCols
            guard row < metrics.maxRows else { break } // bin is full
            placements.append((item, col, row))
        }
        return placements
    }

    private func nearestFreeCell(col: Int, row: Int, metrics: GridMetrics, occupied: Set<[Int]>) -> (Int, Int)? {
        for radius in 1...(metrics.maxCols + metrics.maxRows) {
            for dRow in -radius...radius {
                for dCol in -radius...radius {
                    guard abs(dRow) == radius || abs(dCol) == radius else { continue }
                    let c = col + dCol
                    let r = row + dRow
                    guard c >= 0, c < metrics.maxCols, r >= 0, r < metrics.maxRows else { continue }
                    if !occupied.contains([c, r]) { return (c, r) }
                }
            }
        }
        return nil
    }
}

// Lets menu construction above read linearly instead of via target/action selectors.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func invoke() { handler() }
}

private extension NSMenu {
    @discardableResult
    func addItem(withActionTitle title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        addItem(item)
        return item
    }
}
