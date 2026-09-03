import AppKit

protocol FenceHitViewDelegate: AnyObject {
    func fenceHitViewDidBeginGesture(_ view: FenceHitView)
    func fenceHitView(_ view: FenceHitView, didDragBy delta: CGSize)
    func fenceHitViewDidEndGesture(_ view: FenceHitView)
    func fenceHitViewRequestsToggleCollapse(_ view: FenceHitView)
    func fenceHitViewContextMenu(_ view: FenceHitView) -> NSMenu
    func fenceHitView(_ view: FenceHitView, didDropFileURLs urls: [URL], atScreenPoint screenPoint: NSPoint)
}

/// An invisible click target layered above Finder's desktop icons. One
/// covers the fence's title bar strip (drag to move, double-click to
/// collapse), another the resize corner. Deliberately tiny so that almost
/// all of the fence body stays live Finder desktop.
final class FenceHitView: NSView {
    enum Kind {
        case titleBar
        case resizeHandle
    }

    let kind: Kind
    let fenceID: UUID
    weak var delegate: FenceHitViewDelegate?

    private var dragStartMouse: NSPoint?

    init(kind: Kind, fenceID: UUID) {
        self.kind = kind
        self.fenceID = fenceID
        super.init(frame: .zero)
        // These strips sit above Finder's icon layer, so without this a file
        // dropped on them is refused and springs back to where it came from.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func resetCursorRects() {
        let cursor: NSCursor = kind == .titleBar ? .openHand : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            showMenu(at: convert(event.locationInWindow, from: nil))
            return
        }
        if kind == .titleBar && event.clickCount == 2 {
            delegate?.fenceHitViewRequestsToggleCollapse(self)
            return
        }
        // Screen coordinates, since our own window moves during the drag.
        dragStartMouse = NSEvent.mouseLocation
        delegate?.fenceHitViewDidBeginGesture(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        delegate?.fenceHitView(self, didDragBy: CGSize(width: now.x - start.x, height: now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartMouse != nil else { return }
        dragStartMouse = nil
        delegate?.fenceHitViewDidEndGesture(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.fenceHitViewContextMenu(self)
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppableURLs(from: sender).isEmpty ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppableURLs(from: sender).isEmpty ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty, let window else { return false }
        let screenPoint = window.convertPoint(toScreen: sender.draggingLocation)
        delegate?.fenceHitView(self, didDropFileURLs: urls, atScreenPoint: screenPoint)
        return true
    }

    private func droppableURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    private func showMenu(at point: NSPoint) {
        guard let menu = delegate?.fenceHitViewContextMenu(self) else { return }
        menu.popUp(positioning: nil, at: point, in: self)
    }
}
