import Foundation

/// Maps to Procursus's own suite numbering (confirmed against
/// https://apt.procurs.us/dists/ and the Procursus Makefile):
/// 1800 = iOS 15, 1900 = iOS 16. There is no separate published rootless
/// bootstrap tarball for iOS 17/18 yet (Dopamine itself only ships
/// `bootstrap_1800`/`bootstrap_1900`), so 1900 is reused for iOS 16+
/// exactly like upstream does.
public enum BootstrapVersion: String, CaseIterable, Identifiable, Codable {
    case ios15 = "1800"
    case ios16Plus = "1900"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ios15: return "iOS 15.x (Procursus 1800)"
        case .ios16Plus: return "iOS 16.0+ (Procursus 1900)"
        }
    }

    public var fileName: String {
        "bootstrap_\(rawValue).tar.zst"
    }

    /// Procursus's APT suite is literally the numeric prefix (e.g. `1800`),
    /// used as: `deb https://apt.procurs.us/ 1800 main`.
    public var aptSuite: String {
        rawValue
    }

    public static func forCurrentOS() -> BootstrapVersion {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16 ? .ios16Plus : .ios15
    }
}

public struct BootstrapManifestEntry: Codable {
    public let fileName: String
    public let url: String
    public let sha256: String?
    public let size: Int?
}

public struct BootstrapManifest: Codable {
    public let versions: [String: BootstrapManifestEntry]
}

/// Bootstrap acquisition: remote download (preferred) with bundled fallback.
public enum BootstrapConfig {

    public static let manifestResourceName = "bootstrap-manifest"
    public static let defaultSourcesResourceName = "default-sources"

    public static func manifestEntry(for version: BootstrapVersion) -> BootstrapManifestEntry? {
        guard let manifest = loadManifest() else { return nil }
        return manifest.versions[version.rawValue]
    }

    public static func loadManifest() -> BootstrapManifest? {
        guard let url = Bundle.main.url(
            forResource: manifestResourceName,
            withExtension: "json",
            subdirectory: "Resources/Bootstrap"
        ) ?? Bundle.main.url(forResource: manifestResourceName, withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BootstrapManifest.self, from: data)
    }

    public static func defaultSources(for version: BootstrapVersion) -> [String] {
        guard let url = Bundle.main.url(
            forResource: defaultSourcesResourceName,
            withExtension: "list",
            subdirectory: "Resources/Bootstrap"
        ) ?? Bundle.main.url(forResource: defaultSourcesResourceName, withExtension: "list") else {
            return fallbackSources(for: version)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackSources(for: version)
        }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func fallbackSources(for version: BootstrapVersion) -> [String] {
        ["deb https://apt.procurs.us/ \(version.aptSuite) main"]
    }

    public static func bundledBootstrapURL(for version: BootstrapVersion) -> URL? {
        Bundle.main.url(
            forResource: version.fileName,
            withExtension: nil,
            subdirectory: "Binaries"
        ) ?? Bundle.main.url(forResource: version.fileName, withExtension: nil)
    }

    public static func bundledToolPath(_ name: String) -> String? {
        let path = RootlessPaths.bundledBinariesDir + "/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
