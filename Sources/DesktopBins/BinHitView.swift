import AppKit

protocol BinHitViewDelegate: AnyObject {
    func binHitViewDidBeginGesture(_ view: BinHitView)
    func binHitView(_ view: BinHitView, didDragBy delta: CGSize)
    func binHitViewDidEndGesture(_ view: BinHitView)
    func binHitViewRequestsToggleCollapse(_ view: BinHitView)
    func binHitViewContextMenu(_ view: BinHitView) -> NSMenu
    func binHitView(_ view: BinHitView, didDropFileURLs urls: [URL], atScreenPoint screenPoint: NSPoint)
}

/// An invisible click target layered above Finder's desktop icons. One
/// covers the bin's title bar strip (drag to move, double-click to
/// collapse), another the resize corner. Deliberately tiny so that almost
/// all of the bin body stays live Finder desktop.
final class BinHitView: NSView {
    enum Kind {
        case titleBar
        case resizeHandle
    }

    let kind: Kind
    let binID: UUID
    weak var delegate: BinHitViewDelegate?

    private var dragStartMouse: NSPoint?

    init(kind: Kind, binID: UUID) {
        self.kind = kind
        self.binID = binID
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
            delegate?.binHitViewRequestsToggleCollapse(self)
            return
        }
        // Screen coordinates, since our own window moves during the drag.
        dragStartMouse = NSEvent.mouseLocation
        delegate?.binHitViewDidBeginGesture(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse else { return }
        let now = NSEvent.mouseLocation
        delegate?.binHitView(self, didDragBy: CGSize(width: now.x - start.x, height: now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartMouse != nil else { return }
        dragStartMouse = nil
        delegate?.binHitViewDidEndGesture(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.binHitViewContextMenu(self)
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
        delegate?.binHitView(self, didDropFileURLs: urls, atScreenPoint: screenPoint)
        return true
    }

    private func droppableURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    private func showMenu(at point: NSPoint) {
        guard let menu = delegate?.binHitViewContextMenu(self) else { return }
        menu.popUp(positioning: nil, at: point, in: self)
    }
}
