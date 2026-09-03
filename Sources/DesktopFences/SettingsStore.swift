import Foundation

/// User-tunable behaviour for how fences arrange the icons inside them,
/// persisted in UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let snapEnabled = "snapEnabled"
        static let gridCellWidth = "gridCellWidth"
        static let gridCellHeight = "gridCellHeight"
        static let packIcons = "packIcons"
    }

    static let defaultCellWidth: Double = 112
    static let defaultCellHeight: Double = 112

    /// Called whenever a value changes so the fence controller can re-run a
    /// layout pass immediately instead of waiting for its next tick.
    var onChange: (() -> Void)?

    @Published var snapEnabled: Bool { didSet { save(); onChange?() } }
    @Published var gridCellWidth: Double { didSet { save(); onChange?() } }
    @Published var gridCellHeight: Double { didSet { save(); onChange?() } }
    @Published var packIcons: Bool { didSet { save(); onChange?() } }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.snapEnabled: true,
            Key.gridCellWidth: Self.defaultCellWidth,
            Key.gridCellHeight: Self.defaultCellHeight,
            // On by default: leaving holes where icons happened to be dropped
            // reads as erratic rather than as a preserved layout.
            Key.packIcons: true
        ])
        snapEnabled = defaults.bool(forKey: Key.snapEnabled)
        gridCellWidth = defaults.double(forKey: Key.gridCellWidth)
        gridCellHeight = defaults.double(forKey: Key.gridCellHeight)
        packIcons = defaults.bool(forKey: Key.packIcons)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(snapEnabled, forKey: Key.snapEnabled)
        defaults.set(gridCellWidth, forKey: Key.gridCellWidth)
        defaults.set(gridCellHeight, forKey: Key.gridCellHeight)
        defaults.set(packIcons, forKey: Key.packIcons)
    }

    func resetToDefaults() {
        snapEnabled = true
        gridCellWidth = Self.defaultCellWidth
        gridCellHeight = Self.defaultCellHeight
        packIcons = true
    }
}
