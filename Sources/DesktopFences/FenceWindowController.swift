import AppKit

/// Owns the windows backing each fence and keeps them in sync with the
/// store. Every fence is three windows: a visual backdrop below the desktop
/// icons, plus two small hit targets above them (title bar, resize corner).
final class FenceWindowController: NSObject, FenceHitViewDelegate {
    private struct FenceWindows {
        let backdrop: FenceWindow
        let titleBar: FenceWindow
        let resizeHandle: FenceWindow

        var all: [FenceWindow] { [backdrop, titleBar, resizeHandle] }
    }

    private let store: FenceStore
    private var windows: [UUID: FenceWindows] = [:]
    private var expandedHeights: [UUID: Double] = [:]
    private var gestureStartFrame: NSRect?
    private var gridSnapTimer: Timer?
    private(set) var isVisible = true

    /// Serializes every Finder script call; NSAppleScript is not thread safe.
    private let finderQueue = DispatchQueue(label: "com.smanke.DesktopFences.finder")
    private var dragMembers: [FenceMember] = []
    private var dragUpdateInFlight = false
    private var lastDragUpdate = Date.distantPast
    private static let dragUpdateInterval: TimeInterval = 0.05

    private static let minFenceWidth: CGFloat = 140
    private static let minFenceHeight: CGFloat = 120
    private static let gridMargin: Double = 8
    private static let gridSnapInterval: TimeInterval = 1.5

    init(store: FenceStore) {
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
    }

    // MARK: - Window lifecycle

    func syncWindows() {
        let currentIDs = Set(store.fences.map(\.id))

        for (id, set) in windows where !currentIDs.contains(id) {
            set.all.forEach { $0.close() }
            windows.removeValue(forKey: id)
        }

        for fence in store.fences {
            if let set = windows[fence.id] {
                (set.backdrop.contentView as? FenceBackdropView)?.fence = fence
                layout(set: set, fence: fence)
            } else {
                let set = makeWindows(for: fence)
                windows[fence.id] = set
                layout(set: set, fence: fence)
                if isVisible {
                    set.all.forEach { $0.orderFront(nil) }
                }
            }
        }
    }

    private func makeWindows(for fence: Fence) -> FenceWindows {
        let frame = frameOf(fence)

        let backdrop = FenceWindow(contentRect: frame, role: .backdrop)
        let backdropView = FenceBackdropView(fence: fence)
        backdropView.frame = NSRect(origin: .zero, size: frame.size)
        backdrop.contentView = backdropView

        let titleBar = FenceWindow(contentRect: titleBarFrame(for: frame), role: .chrome)
        let titleBarView = FenceHitView(kind: .titleBar, fenceID: fence.id)
        titleBarView.delegate = self
        titleBar.contentView = titleBarView

        let resizeHandle = FenceWindow(contentRect: resizeHandleFrame(for: frame), role: .chrome)
        let resizeView = FenceHitView(kind: .resizeHandle, fenceID: fence.id)
        resizeView.delegate = self
        resizeHandle.contentView = resizeView

        return FenceWindows(backdrop: backdrop, titleBar: titleBar, resizeHandle: resizeHandle)
    }

    private func frameOf(_ fence: Fence) -> NSRect {
        NSRect(x: fence.x, y: fence.y, width: fence.width, height: fence.height)
    }

    private func titleBarFrame(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - FenceMetrics.titleBarHeight, width: frame.width, height: FenceMetrics.titleBarHeight)
    }

    private func resizeHandleFrame(for frame: NSRect) -> NSRect {
        NSRect(
            x: frame.maxX - FenceMetrics.resizeHandleSize,
            y: frame.minY,
            width: FenceMetrics.resizeHandleSize,
            height: FenceMetrics.resizeHandleSize
        )
    }

    /// Positions the whole window set to match a fence frame.
    private func layout(set: FenceWindows, fence: Fence, frame: NSRect? = nil) {
        let frame = frame ?? frameOf(fence)
        set.backdrop.setFrame(frame, display: true)
        set.backdrop.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        set.backdrop.contentView?.needsDisplay = true
        set.titleBar.setFrame(titleBarFrame(for: frame), display: true)

        if fence.isCollapsed {
            set.resizeHandle.orderOut(nil)
        } else {
            set.resizeHandle.setFrame(resizeHandleFrame(for: frame), display: true)
            if isVisible { set.resizeHandle.orderFront(nil) }
        }
    }

    func setAllVisible(_ visible: Bool) {
        isVisible = visible
        for (id, set) in windows {
            let collapsed = store.fences.first { $0.id == id }?.isCollapsed ?? false
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

    func addFenceAtCenterOfMainScreen() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 260
        let height: CGFloat = 240
        let colors = ["3B82F6", "10B981", "F59E0B", "EF4444", "8B5CF6", "EC4899"]
        let fence = Fence(
            title: "New Fence",
            x: Double(screenFrame.midX - width / 2),
            y: Double(screenFrame.midY - height / 2),
            width: Double(width),
            height: Double(height),
            colorHex: colors[store.fences.count % colors.count]
        )
        store.addFence(fence)
    }

    private func fence(for id: UUID) -> Fence? {
        store.fences.first { $0.id == id }
    }

    // MARK: - FenceHitViewDelegate

    func fenceHitViewDidBeginGesture(_ view: FenceHitView) {
        let frame = windows[view.fenceID]?.backdrop.frame
        gestureStartFrame = frame
        dragMembers = []

        // Snapshot what's inside the fence so the drag can shift those icons
        // live. Done off the main thread so mouse-down isn't stalled by the
        // Apple Event round trip.
        guard view.kind == .titleBar,
              let frame,
              let screenHeight = primaryScreenHeight() else { return }

        let startRect = finderSpaceRect(for: frame, screenHeight: screenHeight)
        finderQueue.async { [weak self] in
            let members = FinderDesktopController.currentDesktopItems()
                .filter { startRect.contains(NSPoint(x: $0.x, y: $0.y)) }
                .map { FenceMember(name: $0.name, x: $0.x, y: $0.y) }
            DispatchQueue.main.async { self?.dragMembers = members }
        }
    }

    func fenceHitView(_ view: FenceHitView, didDragBy delta: CGSize) {
        guard let start = gestureStartFrame,
              let set = windows[view.fenceID],
              let fence = fence(for: view.fenceID) else { return }

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
            let width = max(Self.minFenceWidth, start.width + delta.width)
            let height = max(Self.minFenceHeight, start.height - delta.height)
            newFrame = NSRect(x: start.origin.x, y: start.maxY - height, width: width, height: height)
        }

        layout(set: set, fence: fence, frame: newFrame)

        if view.kind == .titleBar {
            dragIconsAlongside(delta: delta)
        }
    }

    /// Shifts the captured icons to track the fence while it's being dragged.
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
    private func shiftedMembers(_ members: [FenceMember], delta: CGSize) -> [FenceMember] {
        members.map { FenceMember(name: $0.name, x: $0.x + Double(delta.width), y: $0.y - Double(delta.height)) }
    }

    func fenceHitViewDidEndGesture(_ view: FenceHitView) {
        let startFrame = gestureStartFrame
        gestureStartFrame = nil
        guard var fence = fence(for: view.fenceID), let set = windows[view.fenceID] else { return }
        let frame = set.backdrop.frame

        if view.kind == .titleBar, let startFrame, startFrame.origin != frame.origin {
            let delta = CGSize(width: frame.origin.x - startFrame.origin.x, height: frame.origin.y - startFrame.origin.y)
            if dragMembers.isEmpty {
                // The snapshot didn't finish in time; fall back to a direct read.
                moveContainedIcons(from: startFrame, to: frame, fence: &fence)
            } else {
                // Land the icons exactly, since throttling may have dropped
                // the last few drag frames.
                let settled = shiftedMembers(dragMembers, delta: delta)
                finderQueue.async { FinderDesktopController.setPositions(settled) }
                fence.members = settled
            }
        }
        dragMembers = []

        fence.x = Double(frame.origin.x)
        fence.y = Double(frame.origin.y)
        fence.width = Double(frame.width)
        fence.height = Double(frame.height)
        (set.backdrop.contentView as? FenceBackdropView)?.fence = fence
        store.updateFence(fence)
    }

    func fenceHitViewRequestsToggleCollapse(_ view: FenceHitView) {
        guard var fence = fence(for: view.fenceID), let set = windows[view.fenceID] else { return }
        let frame = set.backdrop.frame
        fence.isCollapsed.toggle()

        let newHeight: CGFloat
        if fence.isCollapsed {
            expandedHeights[fence.id] = Double(frame.height)
            newHeight = FenceMetrics.titleBarHeight
        } else {
            newHeight = CGFloat(expandedHeights[fence.id] ?? 240)
        }

        let newFrame = NSRect(x: frame.minX, y: frame.maxY - newHeight, width: frame.width, height: newHeight)
        fence.x = Double(newFrame.origin.x)
        fence.y = Double(newFrame.origin.y)
        fence.width = Double(newFrame.width)
        fence.height = Double(newFrame.height)

        (set.backdrop.contentView as? FenceBackdropView)?.fence = fence
        layout(set: set, fence: fence, frame: newFrame)
        store.updateFence(fence)
    }

    func fenceHitViewContextMenu(_ view: FenceHitView) -> NSMenu {
        buildMenu(for: view.fenceID)
    }

    /// A file dropped onto the fence's chrome (title bar or resize corner)
    /// would otherwise be rejected, since those strips sit above Finder's
    /// icon layer. Place it into the cell the user aimed at instead.
    func fenceHitView(_ view: FenceHitView, didDropFileURLs urls: [URL], atScreenPoint screenPoint: NSPoint) {
        guard let set = windows[view.fenceID],
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
            FenceMember(name: name, x: targetX - 24 + Double(index), y: targetY)
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
        guard let fence = fence(for: id) else { return menu }

        menu.addItem(withActionTitle: fence.isCollapsed ? "Expand Fence" : "Collapse Fence") { [weak self] in
            guard let self, let view = self.windows[id]?.titleBar.contentView as? FenceHitView else { return }
            self.fenceHitViewRequestsToggleCollapse(view)
        }
        menu.addItem(withActionTitle: "Rename Fence…") { [weak self] in
            self?.renameFence(id)
        }
        menu.addItem(withActionTitle: "Change Color…") { [weak self] in
            self?.changeColor(id)
        }
        menu.addItem(.separator())
        let captureTitle = fence.members.isEmpty
            ? "Save Icon Layout"
            : "Save Icon Layout (\(fence.members.count) saved)"
        menu.addItem(withActionTitle: captureTitle) { [weak self] in
            self?.captureIcons(id)
        }
        let restoreItem = menu.addItem(withActionTitle: "Restore Saved Layout") { [weak self] in
            self?.restoreIcons(id)
        }
        restoreItem.isEnabled = !fence.members.isEmpty
        menu.addItem(.separator())
        menu.addItem(withActionTitle: "Delete Fence") { [weak self] in
            self?.deleteFence(id)
        }
        return menu
    }

    private func renameFence(_ id: UUID) {
        guard var fence = fence(for: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Fence"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = fence.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        fence.title = trimmed.isEmpty ? fence.title : trimmed
        (windows[id]?.backdrop.contentView as? FenceBackdropView)?.fence = fence
        store.updateFence(fence)
    }

    private var colorTargetID: UUID?

    private func changeColor(_ id: UUID) {
        guard let fence = fence(for: id) else { return }
        colorTargetID = id
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = NSColor(hex: fence.colorHex)
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let id = colorTargetID, var fence = fence(for: id) else { return }
        fence.colorHex = sender.color.hexString
        (windows[id]?.backdrop.contentView as? FenceBackdropView)?.fence = fence
        store.updateFence(fence)
    }

    private func deleteFence(_ id: UUID) {
        guard let fence = fence(for: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(fence.title)”?"
        alert.informativeText = "This removes the fence. Nothing on your desktop is deleted or moved."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeFence(id: id)
        }
    }

    /// Moving a fence carries the icons inside it along, so a fence acts as a
    /// real container rather than a backdrop icons happen to sit on. The
    /// icons haven't moved during the drag, so membership is decided by
    /// testing their current positions against where the fence started.
    private func moveContainedIcons(from startFrame: NSRect, to endFrame: NSRect, fence: inout Fence) {
        guard let screenHeight = primaryScreenHeight() else { return }
        let startRect = finderSpaceRect(for: startFrame, screenHeight: screenHeight)
        let contained = FinderDesktopController.currentDesktopItems().filter {
            startRect.contains(NSPoint(x: $0.x, y: $0.y))
        }
        guard !contained.isEmpty else { return }

        let dx = Double(endFrame.origin.x - startFrame.origin.x)
        let dy = Double(endFrame.origin.y - startFrame.origin.y)
        // AppKit's y grows upward, Finder's desktop coordinates grow downward.
        let moved = contained.map { FenceMember(name: $0.name, x: $0.x + dx, y: $0.y - dy) }

        FinderDesktopController.setPositions(moved)
        fence.members = moved
    }

    // MARK: - Icon capture / restore

    private func captureIcons(_ id: UUID) {
        guard var fence = fence(for: id),
              let set = windows[id],
              let screenHeight = primaryScreenHeight() else { return }

        let rect = finderSpaceRect(for: set.backdrop.frame, screenHeight: screenHeight)
        let matched = FinderDesktopController.currentDesktopItems().filter {
            rect.contains(NSPoint(x: $0.x, y: $0.y))
        }
        fence.members = matched.map { FenceMember(name: $0.name, x: $0.x, y: $0.y) }
        store.updateFence(fence)
    }

    private func restoreIcons(_ id: UUID) {
        guard let fence = fence(for: id) else { return }
        FinderDesktopController.setPositions(fence.members)
    }

    /// Forces an immediate layout pass instead of waiting for the timer.
    func arrangeIconsNow() {
        performGridSnapPass()
    }

    func restoreAllFences() {
        for fence in store.fences {
            FinderDesktopController.setPositions(fence.members)
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

    /// Finds icons sitting inside each expanded fence and nudges any that
    /// are off-grid onto that fence's grid, so a dropped or rearranged icon
    /// settles into place the way Finder's own desktop grid behaves.
    private func performGridSnapPass() {
        // Don't reshuffle icons while a fence is mid-drag or mid-resize.
        guard gestureStartFrame == nil, SettingsStore.shared.snapEnabled else { return }
        guard !store.fences.isEmpty, let screenHeight = primaryScreenHeight() else { return }
        let allItems = FinderDesktopController.currentDesktopItems()
        guard !allItems.isEmpty else { return }

        var updates: [FenceMember] = []

        for fence in store.fences {
            guard let set = windows[fence.id], !fence.isCollapsed else { continue }
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
                    updates.append(FenceMember(name: item.name, x: targetX, y: targetY))
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

        let top = screenHeight - Double(frame.maxY) + Double(FenceMetrics.titleBarHeight)
        let usableWidth = Double(frame.width) - 2 * Self.gridMargin
        let usableHeight = Double(frame.height) - Double(FenceMetrics.titleBarHeight) - 2 * Self.gridMargin
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

    /// Refills the fence from its top-left in reading order, leaving no
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
            guard row < metrics.maxRows else { break } // fence is full
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
