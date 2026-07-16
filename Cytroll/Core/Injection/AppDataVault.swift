import Foundation
import Combine

/// nonisolated so background encode/decode works under Xcode 26 / Swift 6
/// default MainActor isolation (same pattern as `CytrollBackup`).
public nonisolated struct AppDataBackup: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(bundleID)::\(timestamp)" }
    public let bundleID: String
    public let appDisplayName: String
    public let timestamp: TimeInterval
    public let path: String
    public let sizeBytes: Int64

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
}

/// Backs up / restores an app's *data* container (Documents + Preferences),
/// never the `.app` bundle. Uses cytrollhelper `cp`/`rm` under the
/// allowlisted `/private/var/mobile` prefix.
public final class AppDataVault: ObservableObject {
    public static let shared = AppDataVault()

    @Published public private(set) var isProcessing = false
    @Published public private(set) var backups: [AppDataBackup] = []

    private let console = ConsoleManager.shared
    private let bridge = CytrollCoreBridge.shared
    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.cytroll.appDataVault")

    private init() { reload() }

    public func reload() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let root = RootlessPaths.appDataVaultDir
            var found: [AppDataBackup] = []
            guard let bundleDirs = try? self.fm.contentsOfDirectory(atPath: root) else {
                DispatchQueue.main.async { self.backups = [] }
                return
            }
            for bundleID in bundleDirs {
                let dir = root + "/" + bundleID
                guard let stamps = try? self.fm.contentsOfDirectory(atPath: dir) else { continue }
                for stamp in stamps {
                    let path = dir + "/" + stamp
                    let metaPath = path + "/meta.json"
                    if let data = self.fm.contents(atPath: metaPath),
                       let decoded = try? JSONDecoder().decode(AppDataBackup.self, from: data) {
                        found.append(decoded)
                        continue
                    }
                    let size = self.directorySize(at: path)
                    found.append(AppDataBackup(
                        bundleID: bundleID,
                        appDisplayName: bundleID,
                        timestamp: TimeInterval(stamp) ?? 0,
                        path: path,
                        sizeBytes: size
                    ))
                }
            }
            found.sort { $0.timestamp > $1.timestamp }
            DispatchQueue.main.async { self.backups = found }
        }
    }

    public func backups(for bundleID: String) -> [AppDataBackup] {
        backups.filter { $0.bundleID == bundleID }
    }

    public func backup(bundleID: String, displayName: String, completion: @escaping (Result<AppDataBackup, Error>) -> Void) {
        guard !isProcessing else { return }
        guard CytrollOperationGate.shared.tryAcquire(.dataVault) else {
            completion(.failure(VaultError.busy))
            return
        }
        isProcessing = true
        console.log("Data Vault: backing up \(displayName)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    CytrollOperationGate.shared.release(.dataVault)
                }
            }

            guard let dataPath = DataContainerLocator.dataContainerPath(forBundleID: bundleID) else {
                DispatchQueue.main.async { completion(.failure(VaultError.containerNotFound)) }
                return
            }

            let stamp = String(Int(Date().timeIntervalSince1970))
            let dest = RootlessPaths.appDataVaultDir + "/" + bundleID + "/" + stamp
            _ = self.bridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", RootlessPaths.appDataVaultDir])
            _ = self.bridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", dest])

            // Copy Documents + Library/Preferences; skip Caches/tmp.
            let documents = dataPath + "/Documents"
            let prefs = dataPath + "/Library/Preferences"
            if self.fm.fileExists(atPath: documents) {
                guard self.bridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", documents, dest + "/Documents"]) else {
                    _ = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", dest])
                    DispatchQueue.main.async { completion(.failure(VaultError.copyFailed)) }
                    return
                }
            }
            if self.fm.fileExists(atPath: prefs) {
                _ = self.bridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", dest + "/Library"])
                guard self.bridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", prefs, dest + "/Library/Preferences"]) else {
                    _ = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", dest])
                    DispatchQueue.main.async { completion(.failure(VaultError.copyFailed)) }
                    return
                }
            }

            let size = self.directorySize(at: dest)
            let record = AppDataBackup(
                bundleID: bundleID,
                appDisplayName: displayName,
                timestamp: TimeInterval(stamp) ?? Date().timeIntervalSince1970,
                path: dest,
                sizeBytes: size
            )
            if let data = try? JSONEncoder().encode(record) {
                try? data.write(to: URL(fileURLWithPath: dest + "/meta.json"), options: .atomic)
            }

            self.console.log("Data Vault: saved \(displayName) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))).")
            DispatchQueue.main.async {
                self.reload()
                completion(.success(record))
            }
        }
    }

    public func restore(_ backup: AppDataBackup, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isProcessing else { return }
        guard CytrollOperationGate.shared.tryAcquire(.dataVault) else {
            completion(.failure(VaultError.busy))
            return
        }
        isProcessing = true
        console.log("Data Vault: restoring \(backup.appDisplayName)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    CytrollOperationGate.shared.release(.dataVault)
                }
            }

            guard let dataPath = DataContainerLocator.dataContainerPath(forBundleID: backup.bundleID) else {
                DispatchQueue.main.async { completion(.failure(VaultError.containerNotFound)) }
                return
            }
            guard self.fm.fileExists(atPath: backup.path) else {
                DispatchQueue.main.async { completion(.failure(VaultError.backupMissing)) }
                return
            }

            // Best-effort: terminate the app so files aren't open.
            if let app = InstalledAppScanner.shared.app(withBundleID: backup.bundleID) {
                let execName = (app.executablePath as NSString).lastPathComponent
                _ = self.bridge.executeCommand(executable: "/usr/bin/killall", arguments: ["-9", execName])
            }

            let docsSrc = backup.path + "/Documents"
            let prefsSrc = backup.path + "/Library/Preferences"
            if self.fm.fileExists(atPath: docsSrc) {
                let docsDst = dataPath + "/Documents"
                _ = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", docsDst])
                guard self.bridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", docsSrc, docsDst]) else {
                    DispatchQueue.main.async { completion(.failure(VaultError.copyFailed)) }
                    return
                }
            }
            if self.fm.fileExists(atPath: prefsSrc) {
                let prefsDst = dataPath + "/Library/Preferences"
                _ = self.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", prefsDst])
                _ = self.bridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", dataPath + "/Library"])
                guard self.bridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", prefsSrc, prefsDst]) else {
                    DispatchQueue.main.async { completion(.failure(VaultError.copyFailed)) }
                    return
                }
            }

            self.console.log("Data Vault: restore complete for \(backup.appDisplayName).")
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    public func delete(_ backup: AppDataBackup, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.bridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backup.path])
            DispatchQueue.main.async {
                self?.reload()
                completion?()
            }
        }
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

public enum VaultError: Error, LocalizedError {
    case busy
    case containerNotFound
    case copyFailed
    case backupMissing

    public var errorDescription: String? {
        switch self {
        case .busy: return "Another operation is already running."
        case .containerNotFound: return "Could not locate this app's data container."
        case .copyFailed: return "Copy failed — check free space and permissions."
        case .backupMissing: return "Backup folder is missing."
        }
    }
}

/// Locates `/var/mobile/Containers/Data/Application/<UUID>` for a bundle ID.
enum DataContainerLocator {
    static func dataContainerPath(forBundleID bundleID: String) -> String? {
        let roots = [
            "/private/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Data/Application"
        ]
        let fm = FileManager.default
        for root in roots {
            guard let uuids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for uuid in uuids {
                let meta = root + "/" + uuid + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let data = fm.contents(atPath: meta),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let identifier = plist["MCMMetadataIdentifier"] as? String,
                      identifier == bundleID else {
                    continue
                }
                return root + "/" + uuid
            }
        }
        return nil
    }
}
