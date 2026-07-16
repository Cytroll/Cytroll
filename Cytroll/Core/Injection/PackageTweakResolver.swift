import Foundation

/// Resolves an installed apt package ID to a `TweakInfo` suitable for
/// per-app injection by reading dpkg's `.list` and matching known tweak
/// directories (TweakInject / MobileSubstrate).
public enum PackageTweakResolver {

    public static func resolveTweak(forPackageID packageID: String) -> TweakInfo? {
        let listPath = RootlessPaths.dpkgInfoDir + "/" + packageID + ".list"
        guard let content = try? String(contentsOfFile: listPath, encoding: .utf8) else {
            return matchInstalledTweak(named: packageID)
        }

        let lines = content.components(separatedBy: .newlines)
        let dylibPaths = lines.filter {
            ($0.hasSuffix(".dylib") || $0.hasSuffix(".disabled"))
                && ($0.contains("/TweakInject/") || $0.contains("/MobileSubstrate/DynamicLibraries/"))
        }

        guard let first = dylibPaths.first else {
            return matchInstalledTweak(named: packageID)
        }

        let isEnabled = first.hasSuffix(".dylib")
        let baseName = (first as NSString).lastPathComponent
            .replacingOccurrences(of: ".dylib", with: "")
            .replacingOccurrences(of: ".disabled", with: "")
        let plistPath = first
            .replacingOccurrences(of: ".dylib", with: ".plist")
            .replacingOccurrences(of: ".disabled", with: ".plist")

        return TweakInfo(
            id: baseName,
            name: baseName,
            isEnabled: isEnabled,
            dylibPath: first,
            filterBundleIDs: TweakInjectionManager.readFilterBundleIDs(plistPath: plistPath)
        )
    }

    /// True when the installed package ships at least one inject-able dylib.
    public static func isInjectable(packageID: String) -> Bool {
        resolveTweak(forPackageID: packageID) != nil
    }

    private static func matchInstalledTweak(named packageID: String) -> TweakInfo? {
        let tweaks = TweakInjectionManager.shared.installedTweaks
        if let exact = tweaks.first(where: { $0.id == packageID || $0.name == packageID }) {
            return exact
        }
        // Common Debian naming: package id embeds the tweak basename.
        return tweaks.first { packageID.localizedCaseInsensitiveContains($0.id) }
    }
}
