import Foundation

public struct Source: Identifiable, Hashable, Codable {
    public let id = UUID()
    public let name: String
    public let url: String
    public let iconURL: String?
    public let packageCount: Int
    
    public init(name: String, url: String, iconURL: String? = nil, packageCount: Int = 0) {
        self.name = name
        self.url = url
        self.iconURL = iconURL
        self.packageCount = packageCount
    }
}
