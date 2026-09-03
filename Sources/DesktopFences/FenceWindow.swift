import AppKit

/// Each fence is drawn with two kinds of window, because macOS gives us no
/// single window level that is both visible behind desktop icons *and* able
/// to receive clicks:
///
/// - `.backdrop` sits just above the wallpaper but BELOW Finder's desktop
///   icon layer, and ignores mouse events entirely. It draws the fence. The
///   whole fence body is therefore still plain Finder desktop, so icons can
///   be dragged into it and rearranged exactly as normal.
/// - `.chrome` sits ABOVE the icon layer so it actually receives clicks, and
///   is used only for small invisible hit targets (the title bar strip and
///   the resize corner) that would otherwise be unreachable.
final class FenceWindow: NSWindow {
    enum Role {
        case backdrop
        case chrome
    }

    init(contentRect: NSRect, role: Role) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false

        switch role {
        case .backdrop:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            ignoresMouseEvents = true
        case .chrome:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            ignoresMouseEvents = false
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
