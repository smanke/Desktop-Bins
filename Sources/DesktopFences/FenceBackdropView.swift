import AppKit

/// Draws the whole fence — body fill, title bar strip, title text and the
/// resize grip. Purely visual: its window sits below Finder's desktop icons
/// and ignores mouse events, so all input is handled by FenceHitView.
final class FenceBackdropView: NSView {
    var fence: Fence {
        didSet { needsDisplay = true }
    }

    init(fence: Fence) {
        self.fence = fence
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var titleBarRect: NSRect {
        NSRect(x: 0, y: bounds.height - FenceMetrics.titleBarHeight, width: bounds.width, height: FenceMetrics.titleBarHeight)
    }

    private var resizeHandleRect: NSRect {
        NSRect(x: bounds.width - FenceMetrics.resizeHandleSize, y: 0, width: FenceMetrics.resizeHandleSize, height: FenceMetrics.resizeHandleSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(hex: fence.colorHex)
        let path = NSBezierPath(roundedRect: bounds, xRadius: FenceMetrics.cornerRadius, yRadius: FenceMetrics.cornerRadius)

        color.withAlphaComponent(0.14).setFill()
        path.fill()

        if fence.isCollapsed {
            color.withAlphaComponent(0.55).setFill()
            path.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: titleBarRect).addClip()
            color.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: FenceMetrics.cornerRadius, yRadius: FenceMetrics.cornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        color.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let titleRect = fence.isCollapsed ? bounds : titleBarRect
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textRect = titleRect.insetBy(dx: 8, dy: 0)
        let textHeight = font.boundingRectForFont.height
        let centeredY = textRect.origin.y + (textRect.height - textHeight) / 2
        fence.title.draw(
            in: NSRect(x: textRect.origin.x, y: centeredY, width: textRect.width, height: textHeight),
            withAttributes: attrs
        )

        if !fence.isCollapsed {
            let handle = resizeHandleRect.insetBy(dx: 5, dy: 5)
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: handle.minX, y: handle.minY))
            grip.line(to: NSPoint(x: handle.maxX, y: handle.minY))
            grip.line(to: NSPoint(x: handle.maxX, y: handle.maxY))
            NSColor.white.withAlphaComponent(0.7).setStroke()
            grip.lineWidth = 2
            grip.stroke()
        }
    }
}
