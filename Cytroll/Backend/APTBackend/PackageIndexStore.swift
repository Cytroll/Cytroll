import Foundation
import Combine

/// Single in-memory cache for parsed package data (`dpkg status` + APT
/// `_Packages` indices).
///
/// Before this store existed, `PackagesViewModel`, `ChangesViewModel`,
/// `RepositoryManager`, `BackupManager` and `DependencyResolver` each called
/// `DpkgStatusParser`/`AptIndexParser` independently and rebuilt their own
/// id-keyed dictionaries. On a device with a few large repos (Procursus,
/// Chariz, Havoc) that meant the *same* multi-MB files were read and parsed
/// from scratch — sometimes several times concurrently — every time a tab
/// was opened or a transaction confirmed. `DependencyResolver` was the
/// worst offender: it re-parsed `dpkg status` synchronously on the main
/// thread on every single "Confirm" tap.
///
/// Now everything reads from here. The data is parsed once, cached, and
/// only re-parsed when something explicitly invalidates it (bootstrap
/// install, `apt-get update`, or a completed install/remove transaction).
public final class PackageIndexStore: ObservableObject {
    public static let shared = PackageIndexStore()

    // MARK: - Published mirrors (main thread, for SwiftUI consumers)

    @Published public private(set) var installedPackages: [Package] = []
    @Published public private(set) var repoPackages: [Package] = []
    @Published public private(set) var mergedPackages: [Package] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastRefreshed: Date?

    // MARK: - Thread-safe snapshot (any thread, for synchronous logic like
    // DependencyResolver / BackupManager / RepositoryManager's package counts)

    private struct Snapshot {
        var installed: [Package] = []
        var repo: [Package] = []
        var installedByID: [String: Package] = [:]
        /// Highest version offered across all sources, keyed by package id.
        var bestRepoByID: [String: Package] = [:]
    }

    private let stateQueue = DispatchQueue(label: "com.cytroll.packageindexstore.state")
    private var snapshot = Snapshot()
    private var hasLoadedOnce = false

    /// Serial on purpose: concurrent refreshes would duplicate the parse
    /// work and its peak memory for no benefit, so they're coalesced by
    /// simply running one after another instead.
    private let refreshQueue = DispatchQueue(label: "com.cytroll.packageindexstore.refresh", qos: .userInitiated)

    private init() {}

    // MARK: - Loading

    /// Parses on first call only; a cheap no-op afterwards until `refresh()`
    /// is explicitly requested. Safe to call repeatedly (e.g. from every
    /// tab's `init`/`onAppear`) — only the first caller actually pays for it.
    public func ensureLoaded(completion: (() -> Void)? = nil) {
        var alreadyLoaded = false
        stateQueue.sync { alreadyLoaded = hasLoadedOnce }
        guard !alreadyLoaded else {
            completion?()
            return
        }
        refresh(completion: completion)
    }

    /// Same as `ensureLoaded`, but blocks the calling thread until the first
    /// load completes instead of taking a completion handler. Intended for
    /// call sites that currently have a synchronous API (e.g. `BackupManager`)
    /// and only pay the blocking cost on a cold cache — every subsequent call
    /// is instant since `hasLoadedOnce` is already true.
    public func ensureLoadedBlocking() {
        var alreadyLoaded = false
        stateQueue.sync { alreadyLoaded = hasLoadedOnce }
        guard !alreadyLoaded else { return }

        let semaphore = DispatchSemaphore(value: 0)
        refresh { semaphore.signal() }
        semaphore.wait()
    }

    /// Forces a full re-parse. Call after anything that changes what's on
    /// disk: bootstrap install, `apt-get update`, or a finished transaction.
    /// `completion` fires on a background queue right after the thread-safe
    /// snapshot is updated (before the main-thread `@Published` mirrors are
    /// necessarily updated), so logic-only callers never need to hop to main.
    public func refresh(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { self.isLoading = true }

        refreshQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            let installed = DpkgStatusParser.shared.parseInstalledPackages()
            let repo = AptIndexParser.shared.parseRepoPackages()

            var bestRepoByID = [String: Package]()
            for pkg in repo {
                if let existing = bestRepoByID[pkg.id], !DpkgVersionComparator.isNewer(pkg.version, than: existing.version) {
                    continue
                }
                bestRepoByID[pkg.id] = pkg
            }

            var installedByID = [String: Package]()
            var mergedByID = bestRepoByID
            for installedPkg in installed {
                var pkg = installedPkg
                if let repoPkg = bestRepoByID[pkg.id] { pkg.sourceURL = repoPkg.sourceURL }
                installedByID[pkg.id] = pkg
                mergedByID[pkg.id] = pkg
            }
            let merged = Array(mergedByID.values).sorted { $0.name.lowercased() < $1.name.lowercased() }

            var newSnapshot = Snapshot()
            newSnapshot.installed = installed
            newSnapshot.repo = repo
            newSnapshot.installedByID = installedByID
            newSnapshot.bestRepoByID = bestRepoByID

            self.stateQueue.sync {
                self.snapshot = newSnapshot
                self.hasLoadedOnce = true
            }

            DispatchQueue.main.async {
                self.installedPackages = installed
                self.repoPackages = repo
                self.mergedPackages = merged
                self.lastRefreshed = Date()
                self.isLoading = false
            }

            completion?()
        }
    }

    // MARK: - Thread-safe synchronous access

    public func installedPackagesSnapshot() -> [Package] {
        stateQueue.sync { snapshot.installed }
    }

    public func repoPackagesSnapshot() -> [Package] {
        stateQueue.sync { snapshot.repo }
    }

    public func installedPackage(id: String) -> Package? {
        stateQueue.sync { snapshot.installedByID[id] }
    }

    public func bestRepoPackage(id: String) -> Package? {
        stateQueue.sync { snapshot.bestRepoByID[id] }
    }

    public func installedByIDSnapshot() -> [String: Package] {
        stateQueue.sync { snapshot.installedByID }
    }

    public func bestRepoByIDSnapshot() -> [String: Package] {
        stateQueue.sync { snapshot.bestRepoByID }
    }
}
