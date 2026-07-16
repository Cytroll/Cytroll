import Foundation

public struct Source: Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public let url: String
    public let iconURL: String?
    public let packageCount: Int

    private enum CodingKeys: String, CodingKey {
        case name, url, iconURL, packageCount
    }

    public init(name: String, url: String, iconURL: String? = nil, packageCount: Int = 0) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.iconURL = iconURL
        self.packageCount = packageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(String.self, forKey: .url)
        self.iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        self.packageCount = try container.decodeIfPresent(Int.self, forKey: .packageCount) ?? 0
    }
}
