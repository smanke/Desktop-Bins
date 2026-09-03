import Foundation

/// Loads/saves the bin layout as JSON under Application Support.
/// Owns the in-memory list and notifies observers on any change so window
/// controllers can add/remove/update overlay windows without polling.
final class BinStore {
    private(set) var bins: [Bin] = []
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("DesktopBins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("bins.json")
        migrateLegacyStoreIfNeeded(appSupport: appSupport)
        load()
    }

    /// The app was originally called Desktop Fences and stored its layout
    /// elsewhere; carry that over so a rename doesn't lose the user's bins.
    private func migrateLegacyStoreIfNeeded(appSupport: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }

        let legacyURL = appSupport
            .appendingPathComponent("DesktopFences", isDirectory: true)
            .appendingPathComponent("fences.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        try? fileManager.copyItem(at: legacyURL, to: fileURL)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            bins = []
            return
        }
        bins = (try? JSONDecoder().decode([Bin].self, from: data)) ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(bins) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func addBin(_ bin: Bin) {
        bins.append(bin)
        save()
        onChange?()
    }

    func removeBin(id: UUID) {
        bins.removeAll { $0.id == id }
        save()
        onChange?()
    }

    /// Updates a bin's stored fields in place (e.g. after a drag/resize)
    /// without re-triggering onChange, since the window itself already reflects the change.
    func updateBin(_ bin: Bin) {
        guard let idx = bins.firstIndex(where: { $0.id == bin.id }) else { return }
        bins[idx] = bin
        save()
    }
}
