import Foundation
import Combine

public struct TweakInfo: Identifiable, Hashable {
    public let id: String
    public let name: String
    public var isEnabled: Bool
    public let dylibPath: String
    /// Bundle IDs from the tweak's MobileSubstrate `Filter -> Bundles` key
    /// (its companion `.plist`, e.g. `<name>.plist` next to the `.dylib`).
    /// Empty when the tweak ships no filter plist, or the plist has no
    /// `Bundles` array — such tweaks are treated as "no known target app"
    /// rather than "matches everything", since per-app injection always
    /// needs an explicit target the user picks.
    public var filterBundleIDs: [String] = []
}

public final class TweakInjectionManager: ObservableObject {
    public static let shared = TweakInjectionManager()

    @Published public private(set) var installedTweaks: [TweakInfo] = []
    @Published public private(set) var isProcessing: Bool = false

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared

    private init() {
        refreshTweaks()
    }

    public func refreshTweaks() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fm = FileManager.default
            var targetPath = RootlessPaths.tweakInjectDir

            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: targetPath, isDirectory: &isDir) || !isDir.boolValue {
                targetPath = RootlessPaths.mobileSubstrateDir
            }

            guard let files = try? fm.contentsOfDirectory(atPath: targetPath) else { return }

            var tweaksDict = [String: TweakInfo]()

            for file in files where file.hasSuffix(".dylib") || file.hasSuffix(".disabled") {
                let isEnabled = file.hasSuffix(".dylib")
                let baseName = file
                    .replacingOccurrences(of: ".dylib", with: "")
                    .replacingOccurrences(of: ".disabled", with: "")
                let path = targetPath + "/" + file

                if tweaksDict[baseName] == nil {
                    let plistPath = targetPath + "/" + baseName + ".plist"
                    tweaksDict[baseName] = TweakInfo(
                        id: baseName, name: baseName, isEnabled: isEnabled, dylibPath: path,
                        filterBundleIDs: Self.readFilterBundleIDs(plistPath: plistPath)
                    )
                }
            }

            let sorted = Array(tweaksDict.values).sorted { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async {
                self.installedTweaks = sorted
                // Covers apt/dpkg removing a tweak entirely (its .dylib +
                // .plist disappear from disk): any app still holding an
                // injected copy of that now-gone tweak gets auto-restored.
                AppInjectionManager.shared.reconcileAfterTweakChanges(currentTweaks: sorted)
            }
        }
    }

    public func toggleTweak(_ tweak: TweakInfo, enable: Bool, completion: @escaping (Bool) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true

        console.log(enable ? "Enabling tweak: \(tweak.name)" : "Disabling tweak: \(tweak.name)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let basePath = tweak.dylibPath
                .replacingOccurrences(of: ".dylib", with: "")
                .replacingOccurrences(of: ".disabled", with: "")
            let targetDylib = enable ? "\(basePath).dylib" : "\(basePath).disabled"

            let currentPlist = tweak.dylibPath
                .replacingOccurrences(of: ".dylib", with: ".plist")
                .replacingOccurrences(of: ".disabled", with: ".plist")
            let targetPlist = "\(basePath).plist"

            let successDylib = self.coreBridge.executeCommand(
                executable: "/bin/mv", arguments: [tweak.dylibPath, targetDylib]
            )
            if FileManager.default.fileExists(atPath: currentPlist) {
                _ = self.coreBridge.executeCommand(
                    executable: "/bin/mv", arguments: [currentPlist, targetPlist]
                )
            }

            DispatchQueue.main.async {
                if successDylib {
                    self.console.log("Tweak \(enable ? "enabled" : "disabled").")
                    self.refreshTweaks()

                    // Disabling a tweak doesn't delete its dylib (just
                    // renames it to .disabled), so the reconciliation in
                    // refreshTweaks() above won't catch this case — handle
                    // it explicitly: a disabled tweak's dylib is gone from
                    // its expected path, so any app still loading it via an
                    // injected copy needs restoring right away.
                    if !enable {
                        // Include `.failed` records too — they still carry a
                        // valid backup path (AppInjectionManager only marks a
                        // record `.failed` when its own rollback didn't fully
                        // complete), so disabling the tweak is exactly the
                        // right moment to retry restoring them.
                        let related = InjectionRecordStore.shared.records(forTweakID: tweak.id)
                        AppInjectionManager.shared.restoreAll(related)
                    }
                } else {
                    self.console.log("Failed to toggle tweak: \(tweak.name)")
                }
                self.isProcessing = false
                completion(successDylib)
            }
        }
    }

    // MARK: - Per-app injection matching

    /// Parses the standard MobileSubstrate `Filter -> Bundles` array from a
    /// tweak's companion `.plist`. Missing file / missing keys just yields
    /// an empty list (handled as "no match" by callers, never "matches
    /// everything").
    private static func readFilterBundleIDs(plistPath: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let filter = plist["Filter"] as? [String: Any],
              let bundles = filter["Bundles"] as? [String] else {
            return []
        }
        return bundles
    }

    /// Installed third-party apps whose bundle ID appears in `tweak`'s
    /// `Filter -> Bundles`. Used by the Tweaks UI to only ever offer
    /// injection into apps the tweak actually declares support for.
    public func candidateApps(for tweak: TweakInfo) -> [InstalledAppInfo] {
        guard !tweak.filterBundleIDs.isEmpty else { return [] }
        let filterSet = Set(tweak.filterBundleIDs)
        return InstalledAppScanner.shared.scanInstalledApps().filter { filterSet.contains($0.bundleID) }
    }

    /// Async convenience for `candidateApps(for:)` — scanning installed
    /// apps touches disk for every app on the device.
    public func candidateApps(for tweak: TweakInfo, completion: @escaping ([InstalledAppInfo]) -> Void) {
        guard !tweak.filterBundleIDs.isEmpty else {
            completion([])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = self?.candidateApps(for: tweak) ?? []
            DispatchQueue.main.async { completion(apps) }
        }
    }
}
