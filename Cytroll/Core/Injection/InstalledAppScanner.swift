import Foundation

/// A single installed third-party app, discovered by scanning
/// `RootlessPaths.bundleApplicationsRoot`.
public struct InstalledAppInfo: Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let displayName: String
    public let version: String
    /// Absolute path to the `.app` bundle itself (not the container UUID dir).
    public let bundlePath: String
    /// Absolute path to the main Mach-O executable inside the bundle.
    public let executablePath: String

    public static func == (lhs: InstalledAppInfo, rhs: InstalledAppInfo) -> Bool {
        lhs.bundleID == rhs.bundleID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }
}

/// Enumerates installed third-party apps for the per-app tweak injection
/// feature. Cytroll is unsandboxed via TrollStore, so listing
/// `Bundle/Application/*/*.app/Info.plist` and reading each plist works
/// without any root helper involvement — only the later *write* steps
/// (backup, insert_dylib, ldid) need `cytrollhelper`.
public final class InstalledAppScanner {
    public static let shared = InstalledAppScanner()

    private init() {}

    /// Scans for installed apps. Runs synchronously — call off the main
    /// thread (directory + plist reads for every installed app).
    public func scanInstalledApps() -> [InstalledAppInfo] {
        let fm = FileManager.default
        let root = RootlessPaths.bundleApplicationsRoot
        let ownBundleID = Bundle.main.bundleIdentifier

        guard let containerDirs = try? fm.contentsOfDirectory(atPath: root) else {
            return []
        }

        var results: [InstalledAppInfo] = []

        for containerDir in containerDirs {
            let containerPath = root + "/" + containerDir
            guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { continue }
            guard let appDirName = entries.first(where: { $0.hasSuffix(".app") }) else { continue }

            let appPath = containerPath + "/" + appDirName
            let infoPlistPath = appPath + "/Info.plist"

            guard let plistData = fm.contents(atPath: infoPlistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                continue
            }

            guard let bundleID = plist["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty,
                  bundleID != ownBundleID else {
                continue
            }

            guard let executableName = plist["CFBundleExecutable"] as? String,
                  !executableName.isEmpty else {
                continue
            }

            let executablePath = appPath + "/" + executableName
            guard fm.fileExists(atPath: executablePath) else { continue }

            let displayName = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? bundleID

            let version = (plist["CFBundleShortVersionString"] as? String) ?? "?"

            results.append(InstalledAppInfo(
                bundleID: bundleID,
                displayName: displayName,
                version: version,
                bundlePath: appPath,
                executablePath: executablePath
            ))
        }

        return results.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// Async convenience — scanning touches disk for every installed app.
    public func scanInstalledApps(completion: @escaping ([InstalledAppInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = self?.scanInstalledApps() ?? []
            DispatchQueue.main.async { completion(apps) }
        }
    }

    /// Looks up a single installed app by bundle ID (used to detect
    /// version drift for `InjectionRecord.needsReapply`).
    public func app(withBundleID bundleID: String) -> InstalledAppInfo? {
        scanInstalledApps().first { $0.bundleID == bundleID }
    }
}
