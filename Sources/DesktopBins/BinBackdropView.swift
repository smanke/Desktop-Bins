import AppKit

/// Draws the whole bin — body fill, title bar strip, title text and the
/// resize grip. Purely visual: its window sits below Finder's desktop icons
/// and ignores mouse events, so all input is handled by BinHitView.
final class BinBackdropView: NSView {
    var bin: Bin {
        didSet { needsDisplay = true }
    }

    init(bin: Bin) {
        self.bin = bin
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var titleBarRect: NSRect {
        NSRect(x: 0, y: bounds.height - BinMetrics.titleBarHeight, width: bounds.width, height: BinMetrics.titleBarHeight)
    }

    private var resizeHandleRect: NSRect {
        NSRect(x: bounds.width - BinMetrics.resizeHandleSize, y: 0, width: BinMetrics.resizeHandleSize, height: BinMetrics.resizeHandleSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(hex: bin.colorHex)
        let path = NSBezierPath(roundedRect: bounds, xRadius: BinMetrics.cornerRadius, yRadius: BinMetrics.cornerRadius)

        color.withAlphaComponent(0.14).setFill()
        path.fill()

        if bin.isCollapsed {
            color.withAlphaComponent(0.55).setFill()
            path.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: titleBarRect).addClip()
            color.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: BinMetrics.cornerRadius, yRadius: BinMetrics.cornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        color.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let titleRect = bin.isCollapsed ? bounds : titleBarRect
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
        bin.title.draw(
            in: NSRect(x: textRect.origin.x, y: centeredY, width: textRect.width, height: textHeight),
            withAttributes: attrs
        )

        if !bin.isCollapsed {
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
