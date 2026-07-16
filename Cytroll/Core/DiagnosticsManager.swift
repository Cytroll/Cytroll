import Foundation
import Combine

public final class DiagnosticsManager: ObservableObject {
    public static let shared = DiagnosticsManager()

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared

    @Published public private(set) var isRepairing: Bool = false

    private init() {}

    public func configureDpkg(completion: @escaping (Bool) -> Void) {
        guard !isRepairing else { return }
        isRepairing = true
        console.log("Starting dpkg --configure -a")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.coreBridge.executeDpkg(arguments: ["--configure", "-a"])

            DispatchQueue.main.async {
                self.console.log(success ? "dpkg configured successfully." : "dpkg configure failed.")
                self.isRepairing = false
                completion(success)
            }
        }
    }

    public func fixBrokenPackages(completion: @escaping (Bool) -> Void) {
        guard !isRepairing else { return }
        isRepairing = true
        console.log("Running apt --fix-broken install")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.coreBridge.executeAptGet(arguments: ["--fix-broken", "install", "-y"])

            DispatchQueue.main.async {
                self.console.log(success ? "Broken packages fixed." : "Fix broken packages failed.")
                self.isRepairing = false
                completion(success)
            }
        }
    }

    public func runFullDiagnostics(completion: @escaping (Bool) -> Void) {
        console.log("Initiating full repair protocol...")

        configureDpkg { [weak self] dpkgSuccess in
            guard let self = self else { return }
            self.fixBrokenPackages { aptSuccess in
                self.console.log("Full repair finished.")
                completion(dpkgSuccess && aptSuccess)
            }
        }
    }
}
