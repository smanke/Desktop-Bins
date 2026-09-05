import AppKit

/// Identifies a physical display in a way that survives reboots, unplugging
/// and re-arranging monitors.
///
/// A raw `CGDirectDisplayID` is deliberately not used for storage: the system
/// hands those out per session, so the same monitor can come back with a
/// different id and a laptop's built-in screen can inherit the id an external
/// one used to have. `CGDisplayCreateUUIDFromDisplayID` is stable per physical
/// display, which is what makes "put this bin back on that monitor" work.
enum DisplayIdentity {
    /// A stable fingerprint of the currently attached set of displays.
    ///
    /// Used to remember a separate arrangement per monitor setup, so docking
    /// between a desk, a second desk and the bare laptop restores whatever
    /// layout was last used with each.
    static func configurationSignature() -> String {
        let ids = NSScreen.screens.compactMap { uuid(for: $0) }.sorted()
        return ids.isEmpty ? "none" : ids.joined(separator: "+")
    }

    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuidRef) as String
    }

    static func screen(withUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { self.uuid(for: $0) == uuid }
    }

    /// The screen a bin frame belongs to, chosen by where most of it sits.
    static func screen(containing frame: NSRect) -> NSScreen? {
        let best = NSScreen.screens.max { lhs, rhs in
            overlapArea(frame, lhs.frame) < overlapArea(frame, rhs.frame)
        }
        if let best, overlapArea(frame, best.frame) > 0 {
            return best
        }
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
