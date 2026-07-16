import Foundation

/// A single dependency/conflict finding surfaced to the user before a
/// transaction runs. Blocking issues stop the transaction (real conflicts);
/// non-blocking issues are just logged as a heads-up since `apt-get` will
/// normally fetch missing dependencies automatically.
public struct DependencyIssue {
    public let packageID: String
    public let message: String
    public let isBlocking: Bool
}

public final class DependencyResolver {
    public static let shared = DependencyResolver()

    private init() {}

    /// Validates a queue of pending actions against currently installed
    /// packages and against each other. This mirrors the friendly
    /// "conflicts" pre-flight screen classic package managers (Sileo/Zebra)
    /// show before touching dpkg — the real dependency *resolution* and
    /// download-what's-missing behavior is still delegated to `apt-get`
    /// itself in `TransactionManager`.
    public func resolve(queue: [Package]) -> [DependencyIssue] {
        guard !queue.isEmpty else { return [] }

        var issues: [DependencyIssue] = []

        // Reads the already-parsed shared cache instead of re-parsing
        // `dpkg status` on the main thread on every single "Confirm" tap —
        // this used to be the single most expensive call in the app.
        PackageIndexStore.shared.ensureLoadedBlocking()
        let installedByID = PackageIndexStore.shared.installedByIDSnapshot()
        let queuedByID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })

        // The resulting package-id set once this transaction completes:
        // removals leave it, installs/upgrades/reinstalls enter it.
        var resultingIDs = Set(installedByID.keys)
        for pkg in queue {
            switch pkg.action {
            case .remove:
                resultingIDs.remove(pkg.id)
            case .install, .upgrade, .reinstall:
                resultingIDs.insert(pkg.id)
            case .none:
                break
            }
        }

        func metadata(for packageID: String) -> Package? {
            queuedByID[packageID] ?? installedByID[packageID]
        }

        // 1. Conflicts declared by a package we are installing/upgrading/reinstalling.
        for pkg in queue where pkg.action == .install || pkg.action == .upgrade || pkg.action == .reinstall {
            for conflictID in pkg.conflicts where conflictID != pkg.id {
                if resultingIDs.contains(conflictID) {
                    let otherName = metadata(for: conflictID)?.name ?? conflictID
                    issues.append(DependencyIssue(
                        packageID: pkg.id,
                        message: "\(pkg.name) conflicts with \(otherName). Remove \(otherName) first or drop it from the queue.",
                        isBlocking: true
                    ))
                }
            }
        }

        // 2. Conflicts declared by an already-resulting package against something we're adding now.
        for resultingID in resultingIDs {
            guard let owner = metadata(for: resultingID), !owner.conflicts.isEmpty else { continue }
            for pkg in queue where pkg.action == .install || pkg.action == .upgrade || pkg.action == .reinstall {
                guard owner.id != pkg.id, owner.conflicts.contains(pkg.id) else { continue }
                issues.append(DependencyIssue(
                    packageID: pkg.id,
                    message: "\(owner.name) conflicts with \(pkg.name).",
                    isBlocking: true
                ))
            }
        }

        // 3. Missing dependencies — informational only, apt-get resolves these itself.
        for pkg in queue where pkg.action == .install || pkg.action == .reinstall {
            for group in pkg.dependsGroups {
                let satisfied = group.contains { resultingIDs.contains($0) }
                guard !satisfied else { continue }
                let alternatives = group.joined(separator: " | ")
                issues.append(DependencyIssue(
                    packageID: pkg.id,
                    message: "\(pkg.name) requires \(alternatives) — apt will attempt to fetch it automatically.",
                    isBlocking: false
                ))
            }
        }

        return issues
    }
}
