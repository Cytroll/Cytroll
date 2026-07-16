import Foundation
import Combine
import UIKit

public enum AppManagerStatus: Equatable {
    case normal
    case injected
    case needsReapply
    case safeMode
    case failed
}

public struct ManagedApp: Identifiable, Hashable {
    public var id: String { app.bundleID }
    public let app: InstalledAppInfo
    public let status: AppManagerStatus
    public let injectedTweakCount: Int
    public let dataContainerPath: String?
    public let bundleSizeBytes: Int64
    public let dataSizeBytes: Int64
}

public enum AppManagerError: Error, LocalizedError {
    case busy
    case appMissing
    case operationFailed(String)
    case noDataContainer
    case noVaultBackup
    case nothingToStrip

    public var errorDescription: String? {
        switch self {
        case .busy: return "Another operation is already running."
        case .appMissing: return "App is no longer installed."
        case .operationFailed(let reason): return reason
        case .noDataContainer: return "Could not locate this app's data container."
        case .noVaultBackup: return "No Data Vault backup for this app."
        case .nothingToStrip: return "No active injections on this app."
        }
    }
}

/// Real App Manager ops — kill, uicache, vault, strip injections, uninstall.
/// All privileged work goes through cytrollhelper / existing Care managers.
public final class AppManagerService: ObservableObject {
    public static let shared = AppManagerService()

    @Published public private(set) var apps: [ManagedApp] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?

    private let console = ConsoleManager.shared
    private let bridge = CytrollCoreBridge.shared
    private let recordStore = InjectionRecordStore.shared
    private let safeMode = AppSafeModeManager.shared
    private let vault = AppDataVault.shared
    private let injection = AppInjectionManager.shared
    private let fm = FileManager.default

    private init() {}

    // MARK: - Scan

    public func refresh(completion: (() -> Void)? = nil) {
        guard !isScanning else { completion?(); return }
        isScanning = true
        recordStore.refreshNeedsReapplyFlags()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let scanned = InstalledAppScanner.shared.scanInstalledApps()
            let managed = scanned.map { self.makeManaged($0) }
            DispatchQueue.main.async {
                self.apps = managed
                self.isScanning = false
                self.vault.reload()
                completion?()
            }
        }
    }

    public func managed(for bundleID: String) -> ManagedApp? {
        apps.first { $0.app.bundleID == bundleID }
    }

    private func makeManaged(_ app: InstalledAppInfo) -> ManagedApp {
        let records = recordStore.records(forBundleID: app.bundleID)
        let paused = safeMode.isPaused(bundleID: app.bundleID)
        let status: AppManagerStatus
        if paused {
            status = .safeMode
        } else if records.contains(where: { $0.status == .failed }) {
            status = .failed
        } else if records.contains(where: { $0.status == .needsReapply }) {
            status = .needsReapply
        } else if !records.isEmpty {
            status = .injected
        } else {
            status = .normal
        }
        let dataPath = DataContainerLocator.dataContainerPath(forBundleID: app.bundleID)
        return ManagedApp(
            app: app,
            status: status,
            injectedTweakCount: records.count,
            dataContainerPath: dataPath,
            bundleSizeBytes: directorySize(at: app.bundlePath),
            dataSizeBytes: dataPath.map { directorySize(at: $0) } ?? 0
        )
    }

    // MARK: - Actions

    public func killApp(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let name = (app.executablePath as NSString).lastPathComponent
            self.console.log("Killing \(app.displayName) (\(name))...")
            let ok = self.bridge.executeCommand(executable: "/usr/bin/killall", arguments: ["-9", name])
            DispatchQueue.main.async {
                if ok {
                    self.console.log("Terminated \(app.displayName).")
                    completion(.success(()))
                } else {
                    // killall returns non-zero when no process matched — still a real attempt.
                    self.console.log("killall finished for \(app.displayName) (app may not have been running).")
                    completion(.success(()))
                }
            }
        }
    }

    public func refreshIcon(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.fm.fileExists(atPath: app.bundlePath) else {
                DispatchQueue.main.async { completion(.failure(AppManagerError.appMissing)) }
                return
            }
            guard self.fm.fileExists(atPath: RootlessPaths.uicache) else {
                DispatchQueue.main.async {
                    completion(.failure(AppManagerError.operationFailed("uicache not found — bootstrap missing?")))
                }
                return
            }
            self.console.log("uicache -p \(app.bundlePath)")
            let ok = self.bridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-p", app.bundlePath])
            DispatchQueue.main.async {
                if ok {
                    self.console.log("Icon cache refreshed for \(app.displayName).")
                    completion(.success(()))
                } else {
                    completion(.failure(AppManagerError.operationFailed("uicache failed for \(app.displayName).")))
                }
            }
        }
    }

    public func copyDataPath(_ app: InstalledAppInfo) -> Result<String, Error> {
        guard let path = DataContainerLocator.dataContainerPath(forBundleID: app.bundleID) else {
            return .failure(AppManagerError.noDataContainer)
        }
        UIPasteboard.general.string = path
        console.log("Copied data path for \(app.displayName): \(path)")
        return .success(path)
    }

    /// Opens Filza at the data container when Filza's URL scheme is available.
    public func openDataInFilza(_ app: InstalledAppInfo) -> Result<Void, Error> {
        guard let path = DataContainerLocator.dataContainerPath(forBundleID: app.bundleID) else {
            return .failure(AppManagerError.noDataContainer)
        }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        guard let url = URL(string: "filza://view\(encoded)") else {
            return .failure(AppManagerError.operationFailed("Invalid Filza URL."))
        }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            console.log("Opened Filza at \(path)")
            return .success(())
        }
        // Fallback: copy path so the user can paste in Filza.
        UIPasteboard.general.string = path
        console.log("Filza not installed — copied path instead: \(path)")
        return .failure(AppManagerError.operationFailed("Filza not installed. Data path copied to clipboard."))
    }

    public func backupData(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        vault.backup(bundleID: app.bundleID, displayName: app.displayName) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func restoreLatestData(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let latest = vault.backups(for: app.bundleID).first else {
            completion(.failure(AppManagerError.noVaultBackup))
            return
        }
        vault.restore(latest, completion: completion)
    }

    public func stripInjections(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        let records = recordStore.records(forBundleID: app.bundleID)
        guard !records.isEmpty else {
            completion(.failure(AppManagerError.nothingToStrip))
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.appManager) else {
            completion(.failure(AppManagerError.busy))
            return
        }
        isBusy = true
        console.log("Stripping injections from \(app.displayName)...")
        injection.applyDesiredTweaks(
            bundleID: app.bundleID,
            displayName: app.displayName,
            tweaks: [],
            allowCareOwner: true
        ) { [weak self] result in
            guard let self = self else { return }
            self.isBusy = false
            CytrollOperationGate.shared.release(.appManager)
            switch result {
            case .success:
                self.safeMode.forget(bundleID: app.bundleID)
                self.refresh()
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func pauseTweaks(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        safeMode.pause(bundleID: app.bundleID) { [weak self] result in
            self?.refresh()
            completion(result)
        }
    }

    public func resumeTweaks(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        safeMode.resume(bundleID: app.bundleID) { [weak self] result in
            self?.refresh()
            completion(result)
        }
    }

    /// Uninstall: strip Cytroll bookkeeping, remove install UUID + data container, uicache.
    public func deleteApp(_ app: InstalledAppInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        guard CytrollOperationGate.shared.tryAcquire(.appManager) else {
            completion(.failure(AppManagerError.busy))
            return
        }
        isBusy = true
        console.log("Uninstalling \(app.displayName)...")

        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                self?.isBusy = false
                CytrollOperationGate.shared.release(.appManager)
                if case .success = result {
                    self?.refresh()
                }
                completion(result)
            }
        }

        // If injections exist, strip first so we don't leave orphan pristine backups.
        let records = recordStore.records(forBundleID: app.bundleID)
        let proceedDelete = { [weak self] in
            self?.performDelete(app, finish: finish)
        }

        if records.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async(execute: proceedDelete)
            return
        }

        injection.applyDesiredTweaks(
            bundleID: app.bundleID,
            displayName: app.displayName,
            tweaks: [],
            allowCareOwner: true
        ) { result in
            // Even if strip fails, still attempt uninstall — app may be half-gone.
            if case .failure(let error) = result {
                ConsoleManager.shared.log("Strip before delete warned: \(error.localizedDescription)")
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: proceedDelete)
        }
    }

    private func performDelete(_ app: InstalledAppInfo, finish: @escaping (Result<Void, Error>) -> Void) {
        let container = app.installContainerPath
        let dataPath = DataContainerLocator.dataContainerPath(forBundleID: app.bundleID)

        // Remove install container (UUID) — requires helper allowlist.
        if fm.fileExists(atPath: container) {
            console.log("Removing install container \(container)...")
            let ok = bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", container])
            if !ok && fm.fileExists(atPath: container) {
                // Fallback: remove .app only
                console.log("Container rm blocked/failed — removing .app only...")
                _ = bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", app.bundlePath])
            }
        }

        if let dataPath, fm.fileExists(atPath: dataPath) {
            console.log("Removing data container \(dataPath)...")
            _ = bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", dataPath])
        }

        recordStore.removeAll(forBundleID: app.bundleID)
        safeMode.forget(bundleID: app.bundleID)
        AppPristineBackupStore.shared.remove(bundleID: app.bundleID)

        if fm.fileExists(atPath: RootlessPaths.uicache) {
            _ = bridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-a"])
        }

        let stillThere = fm.fileExists(atPath: app.bundlePath)
        if stillThere {
            finish(.failure(AppManagerError.operationFailed("App bundle still present after delete.")))
        } else {
            console.log("Uninstalled \(app.displayName).")
            finish(.success(()))
        }
    }

    public func readEntitlements(for app: InstalledAppInfo, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ldid = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
            guard self.fm.fileExists(atPath: ldid) else {
                DispatchQueue.main.async {
                    completion(.failure(AppManagerError.operationFailed("ldid missing.")))
                }
                return
            }
            let result = self.bridge.executeCommandCapturingOutput(
                executable: ldid,
                arguments: ["-e", app.executablePath]
            )
            DispatchQueue.main.async {
                if result.success, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(.success(result.output))
                } else if !result.output.isEmpty {
                    completion(.success(result.output))
                } else {
                    completion(.failure(AppManagerError.operationFailed("Could not dump entitlements.")))
                }
            }
        }
    }

    public func loadIcon(for app: InstalledAppInfo) -> UIImage? {
        let infoPath = app.bundlePath + "/Info.plist"
        guard let data = fm.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        var iconNames: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: files)
        }
        if let files = plist["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: files)
        }
        if let name = plist["CFBundleIconFile"] as? String {
            iconNames.append(name)
        }
        iconNames.append("AppIcon")

        for name in iconNames {
            let candidates = [
                app.bundlePath + "/" + name,
                app.bundlePath + "/" + name + ".png",
                app.bundlePath + "/" + name + "@2x.png",
                app.bundlePath + "/" + name + "@3x.png"
            ]
            for path in candidates {
                if let img = UIImage(contentsOfFile: path) { return img }
            }
        }
        return nil
    }

    private func directorySize(at path: String) -> Int64 {
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            let full = path + "/" + relative
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}
