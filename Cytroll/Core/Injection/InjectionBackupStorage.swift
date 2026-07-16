import Foundation

public struct BackupStorageEntry: Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let displayName: String
    public let sizeBytes: Int64
}

/// Read-only inspection + cleanup helpers for
/// `RootlessPaths.injectionBackupsDir`, backing the "Backup Storage"
/// screen. Sizing/listing are plain, unprivileged `FileManager` reads
/// (Cytroll's own directory) — only the destructive cleanup step goes
/// through `cytrollhelper`, matching how every other write under this
/// directory is already handled by `AppInjectionManager`.
public enum InjectionBackupStorage {
    /// Every backup folder should correspond to exactly one
    /// `AppPristineBackup`. Anything else on disk — a leftover from an
    /// app that was uninstalled while injected, or from a version of
    /// Cytroll before this cleanup existed — is reported as orphaned so
    /// the user can reclaim the space with one tap instead of it growing
    /// forever silently.
    public static func scan() -> (entries: [BackupStorageEntry], orphanedDirs: [String]) {
        let fm = FileManager.default
        let root = RootlessPaths.injectionBackupsDir
        guard let dirNames = try? fm.contentsOfDirectory(atPath: root) else {
            return ([], [])
        }

        let pristineBackups = AppPristineBackupStore.shared.all
        var entries: [BackupStorageEntry] = []
        var orphaned: [String] = []

        for dirName in dirNames {
            let dirPath = root + "/" + dirName
            if let pristine = pristineBackups.first(where: { sanitizedDirName(for: $0.bundleID) == dirName }) {
                let displayName = InstalledAppScanner.shared.app(withBundleID: pristine.bundleID)?.displayName ?? pristine.bundleID
                entries.append(BackupStorageEntry(bundleID: pristine.bundleID, displayName: displayName, sizeBytes: directorySize(at: dirPath)))
            } else {
                orphaned.append(dirPath)
            }
        }

        return (entries.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }, orphaned)
    }

    public static func removeOrphaned(_ dirs: [String]) {
        for dir in dirs {
            _ = CytrollCoreBridge.shared.executeCommand(executable: "/bin/rm", arguments: ["-rf", dir])
        }
    }

    private static func sanitizedDirName(for bundleID: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return String(bundleID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for item in enumerator {
            guard let relativePath = item as? String else { continue }
            let fullPath = path + "/" + relativePath
            if let attrs = try? fm.attributesOfItem(atPath: fullPath), let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
