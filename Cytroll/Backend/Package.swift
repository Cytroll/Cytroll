import Foundation

public enum QueueAction: String, Codable {
    case install = "Install"
    case remove = "Remove"
    case upgrade = "Upgrade"
    case reinstall = "Reinstall"
}

public struct Package: Identifiable, Hashable, Codable {
    public let id: String // Bundle ID e.g. com.saurik.substrate.safemode
    public let name: String
    public let version: String
    public let author: String
    public let architecture: String
    public let description: String
    public var sourceURL: String?

    /// Debian `Section:` field (e.g. "System", "Utilities", "Tweaks").
    public var section: String = "Unknown"

    /// Parsed `Depends:` field. Each element is a group of OR-alternatives
    /// (from `a | b`); the whole group is satisfied if ANY alternative is
    /// installed or queued for install. Version constraints are stripped —
    /// real constraint enforcement is delegated to apt/dpkg itself.
    public var dependsGroups: [[String]] = []

    /// Parsed `Conflicts:` field (flattened package IDs, version constraints stripped).
    public var conflicts: [String] = []

    // UI State flags
    public var isInstalled: Bool = false
    public var isBroken: Bool = false
    
    // The action assigned to this package in the queue
    public var action: QueueAction? = nil

    public init(id: String, name: String, version: String, author: String, architecture: String, description: String, sourceURL: String? = nil, section: String = "Unknown", dependsGroups: [[String]] = [], conflicts: [String] = [], isInstalled: Bool = false, isBroken: Bool = false, action: QueueAction? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.architecture = architecture
        self.description = description
        self.sourceURL = sourceURL
        self.section = section
        self.dependsGroups = dependsGroups
        self.conflicts = conflicts
        self.isInstalled = isInstalled
        self.isBroken = isBroken
        self.action = action
    }
    
    // Hashable conformance based on bundle ID to ensure uniqueness in Collections
    public static func == (lhs: Package, rhs: Package) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
