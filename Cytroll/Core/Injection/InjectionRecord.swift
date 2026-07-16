import Foundation

public enum InjectionStatus: String, Codable {
    /// Dylib load command present, signature valid, app version unchanged
    /// since injection.
    case active
    /// The target app was updated since injection — App Store/TrollStore
    /// updates replace the executable wholesale, silently reverting the
    /// patch. Needs one tap to re-inject.
    case needsReapply
    /// An inject attempt failed AND the automatic rollback it triggered
    /// didn't fully complete (e.g. a filesystem op mid-rollback also
    /// failed) — the app may be left inconsistent. `backupPath` still
    /// points at the verified pre-injection backup; the only allowed next
    /// step is restoring from it (re-inject is blocked until then, see
    /// `AppInjectionManager.performInject`).
    case failed
}

/// Persisted record of one tweak-into-app injection, so the Tweaks UI can
/// show "Injected Apps" and detect drift (target app updated) across
/// launches without re-scanning every app's Mach-O load commands.
public struct InjectionRecord: Identifiable, Codable, Hashable {
    public var id: String { "\(tweakID)::\(bundleID)" }

    public let tweakID: String
    public let tweakName: String
    public let bundleID: String
    public let appDisplayName: String
    /// Full path to the backed-up `.app` bundle copy, e.g.
    /// `/var/jb/var/cytroll/backups/<bundleID>/<timestamp>/<Name>.app`.
    public let backupPath: String
    /// `CFBundleShortVersionString` of the target app at injection time —
    /// compared against its current version to flag `.needsReapply`.
    public let injectedAppVersion: String
    /// Where the tweak's dylib was copied to inside the target bundle.
    public let dylibDestinationPath: String
    public var status: InjectionStatus
    public let injectedAt: Date

    public init(
        tweakID: String,
        tweakName: String,
        bundleID: String,
        appDisplayName: String,
        backupPath: String,
        injectedAppVersion: String,
        dylibDestinationPath: String,
        status: InjectionStatus = .active,
        injectedAt: Date = Date()
    ) {
        self.tweakID = tweakID
        self.tweakName = tweakName
        self.bundleID = bundleID
        self.appDisplayName = appDisplayName
        self.backupPath = backupPath
        self.injectedAppVersion = injectedAppVersion
        self.dylibDestinationPath = dylibDestinationPath
        self.status = status
        self.injectedAt = injectedAt
    }
}

/// JSON-backed store for `InjectionRecord`s at
/// `RootlessPaths.injectionRecordsFile`. All reads/writes go through a
/// private serial queue so concurrent inject/restore calls never race on
/// the underlying file.
public final class InjectionRecordStore: ObservableObject {
    public static let shared = InjectionRecordStore()

    @Published public private(set) var records: [InjectionRecord] = []

    private let ioQueue = DispatchQueue(label: "com.cytroll.injectionRecordStore")

    private init() {
        load()
    }

    private func load() {
        ioQueue.sync {
            guard let data = FileManager.default.contents(atPath: RootlessPaths.injectionRecordsFile),
                  let decoded = try? JSONDecoder().decode([InjectionRecord].self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.records = decoded }
        }
    }

    private func persist(_ records: [InjectionRecord]) {
        let dir = RootlessPaths.cytrollStateDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: RootlessPaths.injectionRecordsFile), options: .atomic)
    }

    public func upsert(_ record: InjectionRecord) {
        ioQueue.sync {
            var current = self.records
            if let idx = current.firstIndex(where: { $0.id == record.id }) {
                current[idx] = record
            } else {
                current.append(record)
            }
            self.persist(current)
            DispatchQueue.main.async { self.records = current }
        }
    }

    public func remove(id: String) {
        ioQueue.sync {
            let current = self.records.filter { $0.id != id }
            self.persist(current)
            DispatchQueue.main.async { self.records = current }
        }
    }

    public func records(forTweakID tweakID: String) -> [InjectionRecord] {
        records.filter { $0.tweakID == tweakID }
    }

    /// Re-checks every record's target app version against what's
    /// currently installed, flipping `.active` records to
    /// `.needsReapply` when the app was updated since injection. Call
    /// when the Tweaks tab appears — cheap relative to a full app scan
    /// since it reuses one `InstalledAppScanner` pass for every record.
    public func refreshNeedsReapplyFlags() {
        ioQueue.async {
            let installedApps = InstalledAppScanner.shared.scanInstalledApps()
            let versionByBundleID = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleID, $0.version) })

            var current = self.records
            var changed = false

            for i in current.indices {
                guard current[i].status != .failed else { continue }
                guard let currentVersion = versionByBundleID[current[i].bundleID] else { continue }
                let shouldNeedReapply = currentVersion != current[i].injectedAppVersion
                let newStatus: InjectionStatus = shouldNeedReapply ? .needsReapply : .active
                if current[i].status != newStatus {
                    current[i].status = newStatus
                    changed = true
                }
            }

            if changed {
                self.persist(current)
                DispatchQueue.main.async { self.records = current }
            }
        }
    }
}
