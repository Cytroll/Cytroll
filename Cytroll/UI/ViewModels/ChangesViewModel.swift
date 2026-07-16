import Foundation
import Combine

/// A single available update: the installed version paired with the newest
/// candidate version found across all configured APT sources.
public struct PackageUpdate: Identifiable {
    public let id: String
    public let name: String
    public let installedVersion: String
    public let candidateVersion: String
    public let repoPackage: Package
}

/// Computes real available updates by diffing `dpkg status` against the
/// parsed APT repo indices using dpkg's own version-ordering rules —
/// no mock data, mirrors what `apt list --upgradable` would report.
///
/// Reads exclusively from `PackageIndexStore` — no parsing happens here.
public final class ChangesViewModel: ObservableObject {
    @Published public private(set) var updates: [PackageUpdate] = []
    @Published public private(set) var isRefreshing: Bool = false

    private var cancellable: AnyCancellable?

    public init() {
        let store = PackageIndexStore.shared
        cancellable = store.$installedPackages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeUpdates() }

        store.ensureLoaded { [weak self] in
            DispatchQueue.main.async { self?.recomputeUpdates() }
        }
    }

    /// Pull-to-refresh: forces a fresh re-parse via the shared store, then
    /// recomputes the diff from the refreshed snapshot.
    public func loadUpdates(completion: (() -> Void)? = nil) {
        guard !isRefreshing else { completion?(); return }
        isRefreshing = true

        PackageIndexStore.shared.refresh { [weak self] in
            DispatchQueue.main.async {
                self?.recomputeUpdates()
                self?.isRefreshing = false
                completion?()
            }
        }
    }

    /// Cheap: just diffs the already-parsed snapshot, no file IO/parsing.
    private func recomputeUpdates() {
        let installed = PackageIndexStore.shared.installedPackagesSnapshot()
        let bestRepoByID = PackageIndexStore.shared.bestRepoByIDSnapshot()

        var found: [PackageUpdate] = []
        for installedPkg in installed where !installedPkg.isBroken {
            guard let candidate = bestRepoByID[installedPkg.id] else { continue }
            guard DpkgVersionComparator.isNewer(candidate.version, than: installedPkg.version) else { continue }

            found.append(PackageUpdate(
                id: installedPkg.id,
                name: installedPkg.name,
                installedVersion: installedPkg.version,
                candidateVersion: candidate.version,
                repoPackage: candidate
            ))
        }

        updates = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
