import Foundation
import Combine

/// Thin presentation layer over `PackageIndexStore` — search filtering only.
/// No parsing happens here anymore: the merged installed+repo list is
/// computed once in the shared store and simply mirrored via Combine, so
/// opening this tab never re-parses `dpkg status`/`_Packages` on its own.
public final class PackagesViewModel: ObservableObject {
    @Published public private(set) var packages: [Package] = []
    @Published public var searchQuery: String = ""

    private var cancellable: AnyCancellable?

    public init() {
        let store = PackageIndexStore.shared
        packages = store.mergedPackages

        cancellable = store.$mergedPackages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.packages = $0 }

        store.ensureLoaded()
    }

    public var filteredPackages: [Package] {
        let settings = PackageManagerSettings.shared
        let compatible = settings.filterIncompatiblePackages
            ? packages.filter { settings.isCompatible($0) }
            : packages

        if searchQuery.isEmpty {
            return compatible
        } else {
            return compatible.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.id.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    /// Pull-to-refresh: forces a fresh re-parse of both `dpkg status` and
    /// the repo indices.
    public func refresh(completion: (() -> Void)? = nil) {
        PackageIndexStore.shared.refresh {
            DispatchQueue.main.async { completion?() }
        }
    }
}
