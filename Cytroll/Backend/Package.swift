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

    /// `Installed-Size:` field, in kilobytes (Debian convention). Present in
    /// both `dpkg status` (installed packages) and repo indices.
    public var installedSizeKB: Int? = nil

    /// `Size:` field, in bytes — the compressed `.deb` download size. Only
    /// ever present in repo `_Packages` indices, never in `dpkg status`.
    public var downloadSizeBytes: Int64? = nil

    /// `Homepage:` field, if the package/repo provides one.
    public var homepageURL: String? = nil

    /// Depiction page URL — checks `Depiction:` then `SileoDepiction:`.
    /// Classic Cydia-style depictions are plain HTML pages meant for an
    /// in-app browser; rendered here via `DepictionWebView`.
    public var depictionURL: String? = nil

    // UI State flags
    public var isInstalled: Bool = false
    public var isBroken: Bool = false
    
    // The action assigned to this package in the queue
    public var action: QueueAction? = nil

    /// When set, queueing this package for `.install` requests this *exact*
    /// version via apt's `name=version` syntax instead of whatever apt
    /// would otherwise pick as the candidate. Transient — never parsed,
    /// only set by the UI (Package Details' "Other Versions" picker).
    public var pinnedVersion: String? = nil

    public init(id: String, name: String, version: String, author: String, architecture: String, description: String, sourceURL: String? = nil, section: String = "Unknown", dependsGroups: [[String]] = [], conflicts: [String] = [], installedSizeKB: Int? = nil, downloadSizeBytes: Int64? = nil, homepageURL: String? = nil, depictionURL: String? = nil, isInstalled: Bool = false, isBroken: Bool = false, action: QueueAction? = nil, pinnedVersion: String? = nil) {
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
        self.installedSizeKB = installedSizeKB
        self.downloadSizeBytes = downloadSizeBytes
        self.homepageURL = homepageURL
        self.depictionURL = depictionURL
        self.isInstalled = isInstalled
        self.isBroken = isBroken
        self.action = action
        self.pinnedVersion = pinnedVersion
    }
    
    // Hashable conformance based on bundle ID to ensure uniqueness in Collections
    public static func == (lhs: Package, rhs: Package) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
