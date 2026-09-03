import Foundation

/// A desktop icon captured into a bin, remembered by name and its
/// Finder-native desktop position at capture time.
struct BinMember: Codable, Equatable {
    var name: String
    var x: Double
    var y: Double
}

struct Bin: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var colorHex: String
    var isCollapsed: Bool
    var members: [BinMember]

    init(
        id: UUID = UUID(),
        title: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        colorHex: String = "3B82F6",
        isCollapsed: Bool = false,
        members: [BinMember] = []
    ) {
        self.id = id
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.colorHex = colorHex
        self.isCollapsed = isCollapsed
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        members = try container.decodeIfPresent([BinMember].self, forKey: .members) ?? []
    }
}
