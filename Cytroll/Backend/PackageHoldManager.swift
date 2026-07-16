import Foundation
import Combine

/// Tracks packages "held" via `apt-mark hold` — mirrors Cydia/Sileo's
/// "pin version" concept. A held package's `dpkg status` want-state
/// flips from `install` to `hold`, which stops `apt-get upgrade` from ever
/// touching it (it stays fully installed, just excluded from the Changes
/// tab's automatic-upgrade list) until explicitly unheld.
public final class PackageHoldManager: ObservableObject {
    public static let shared = PackageHoldManager()

    @Published public private(set) var heldPackageIDs: Set<String> = []

    private let coreBridge = CytrollCoreBridge.shared
    private var aptMarkPath: String { RootlessPaths.aptMark }

    private init() {
        refresh()
    }

    public func isHeld(_ packageID: String) -> Bool {
        heldPackageIDs.contains(packageID)
    }

    /// Re-reads `apt-mark showhold` — the source of truth lives in dpkg's
    /// selections database, not anything Cytroll persists itself.
    public func refresh(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion?(); return }
            let (_, output) = self.coreBridge.executeCommandCapturingOutput(executable: self.aptMarkPath, arguments: ["showhold"])
            let ids = Set(
                output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            DispatchQueue.main.async {
                self.heldPackageIDs = ids
                completion?()
            }
        }
    }

    /// Toggles hold state for a single package, then refreshes the cached
    /// set from the real dpkg selections database (never assumes success).
    public func setHeld(_ packageID: String, held: Bool, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion?(false); return }
            let success = self.coreBridge.executeCommand(executable: self.aptMarkPath, arguments: [held ? "hold" : "unhold", packageID])
            self.refresh {
                completion?(success)
            }
        }
    }
}
