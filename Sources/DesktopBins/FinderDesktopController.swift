import Foundation

/// Talks to Finder over Apple Events (AppleScript) to read and set desktop
/// icon positions. Positions are stored and replayed exactly as Finder
/// reports them, so no coordinate-space conversion is needed for capture/
/// restore — only for testing whether a point falls inside a bin's frame.
enum FinderDesktopController {
    struct Item {
        let name: String
        let x: Double
        let y: Double
    }

    /// Returns every item currently on the desktop with its Finder-native position.
    static func currentDesktopItems() -> [Item] {
        // Note: desktop icons expose their location as `desktop position`;
        // the plain `position` property reports -1,-1 for them. Iterating
        // Finder item references directly fails, so pull the two plain
        // lists and walk those instead.
        let script = """
        tell application "Finder"
            set theNames to name of every item of desktop
            set thePositions to desktop position of every item of desktop
            set output to ""
            repeat with i from 1 to count of theNames
                set p to item i of thePositions
                set output to output & (item i of theNames) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
            end repeat
            return output
        end tell
        """
        guard let result = runScript(script) else { return [] }

        var items: [Item] = []
        for line in result.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3,
                  let x = Double(fields[1]),
                  let y = Double(fields[2]) else { continue }
            items.append(Item(name: String(fields[0]), x: x, y: y))
        }
        return items
    }

    /// Moves each named item back to its stored position. Items that no
    /// longer exist (renamed/deleted/moved) are skipped individually.
    static func setPositions(_ members: [BinMember]) {
        guard !members.isEmpty else { return }
        var body = "tell application \"Finder\"\n"
        for member in members {
            let escapedName = escape(member.name)
            let x = Int(member.x.rounded())
            let y = Int(member.y.rounded())
            body += "    try\n"
            body += "        set desktop position of item \"\(escapedName)\" of desktop to {\(x), \(y)}\n"
            body += "    end try\n"
        }
        body += "end tell"
        _ = runScript(body)
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Set once we've told the user Finder control is blocked, so a timer
    /// firing every couple of seconds can't spam them with alerts.
    private static var hasReportedPermissionFailure = false

    private static func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            NSLog("DesktopBins: AppleScript error talking to Finder (\(code)): \(errorInfo)")

            // -1743 is "not authorized to send Apple Events" — the user has
            // not granted Automation access, which silently breaks everything.
            if code == -1743, !hasReportedPermissionFailure {
                hasReportedPermissionFailure = true
                DispatchQueue.main.async { FinderAutomation.presentDeniedAlert() }
            }
            return nil
        }
        return descriptor.stringValue
    }
}
