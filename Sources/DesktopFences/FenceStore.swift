import Foundation

/// Loads/saves the fence layout as JSON under Application Support.
/// Owns the in-memory list and notifies observers on any change so window
/// controllers can add/remove/update overlay windows without polling.
final class FenceStore {
    private(set) var fences: [Fence] = []
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("DesktopFences", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("fences.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            fences = []
            return
        }
        fences = (try? JSONDecoder().decode([Fence].self, from: data)) ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(fences) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func addFence(_ fence: Fence) {
        fences.append(fence)
        save()
        onChange?()
    }

    func removeFence(id: UUID) {
        fences.removeAll { $0.id == id }
        save()
        onChange?()
    }

    /// Updates a fence's stored fields in place (e.g. after a drag/resize)
    /// without re-triggering onChange, since the window itself already reflects the change.
    func updateFence(_ fence: Fence) {
        guard let idx = fences.firstIndex(where: { $0.id == fence.id }) else { return }
        fences[idx] = fence
        save()
    }
}
