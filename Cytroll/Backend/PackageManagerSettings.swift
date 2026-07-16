import Foundation
import Combine

/// User-defaults-backed toggles for package-manager (APT/dpkg) *behavior* —
/// distinct from `ThemeManager`'s purely cosmetic settings. Read by
/// `PackagesViewModel`/`PackageDetailView` to control what's actually shown.
public final class PackageManagerSettings: ObservableObject {
    public static let shared = PackageManagerSettings()

    private enum Keys {
        static let filterIncompatible = "cytroll.pm.filterIncompatiblePackages"
        static let showAllVersions = "cytroll.pm.showAllVersionsExpanded"
    }

    /// Hides packages whose `Architecture:` clearly targets a different
    /// platform (watchOS, macOS, etc.) from the Packages tab.
    @Published public var filterIncompatiblePackages: Bool {
        didSet { UserDefaults.standard.set(filterIncompatiblePackages, forKey: Keys.filterIncompatible) }
    }

    /// Controls whether Package Details' "Other Versions Available"
    /// section starts expanded by default, instead of behind a disclosure.
    @Published public var showAllVersions: Bool {
        didSet { UserDefaults.standard.set(showAllVersions, forKey: Keys.showAllVersions) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.filterIncompatiblePackages = defaults.object(forKey: Keys.filterIncompatible) as? Bool ?? true
        self.showAllVersions = defaults.object(forKey: Keys.showAllVersions) as? Bool ?? false
    }

    /// Conservative on purpose: ambiguous/empty/generic (`all`/`any`)
    /// architecture strings are always kept rather than risk hiding a
    /// perfectly-installable package because of inconsistent repo metadata.
    public func isCompatible(_ package: Package) -> Bool {
        guard filterIncompatiblePackages else { return true }
        let arch = package.architecture.lowercased()
        if arch.isEmpty || arch == "all" || arch == "any" { return true }
        if arch.contains("arm64") || arch.contains("iphoneos-arm") { return true }
        return false
    }
}
