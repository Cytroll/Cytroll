import Foundation
import Combine

public final class TransactionManager: ObservableObject {
    public static let shared = TransactionManager()
    
    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    
    private init() {}
    
    /// Executes a batch of packages via apt.
    /// Uses background threads (userInitiated) to prevent UI freezing during heavy dpkg operations.
    public func executeTransaction(queue: [Package], completion: @escaping (Bool) -> Void) {
        guard !queue.isEmpty else {
            completion(true)
            return
        }
        
        console.log("Preparing Transaction of \(queue.count) items...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var installs = [String]()
            var removes = [String]()
            var upgrades = [String]()
            var reinstalls = [String]()
            
            // Distribute queue items into operations. When a package carries
            // a `pinnedVersion` (set from Package Details' "Other Versions"
            // picker), request that *exact* version via apt's native
            // `name=version` syntax instead of whatever apt would otherwise
            // pick as the candidate.
            for pkg in queue {
                let target = pkg.pinnedVersion.map { "\(pkg.id)=\($0)" } ?? pkg.id
                switch pkg.action {
                case .install: installs.append(target)
                case .remove: removes.append(pkg.id)
                case .upgrade: upgrades.append(target)
                case .reinstall: reinstalls.append(target)
                case .none: break
                }
            }
            
            var overallSuccess = true
            
            // 1. Removals
            if !removes.isEmpty {
                self.console.log("Executing Removals via APT...")
                var args = ["remove", "-y", "--allow-unauthenticated"]
                args.append(contentsOf: removes)
                // Assuming apt-get is available in the rootless bin path
                let success = self.coreBridge.executeAptGet(arguments: args)
                if !success { overallSuccess = false }
            }
            
            // 2. Installations & Upgrades
            let installList = installs + upgrades
            if !installList.isEmpty {
                self.console.log("Executing Installations/Upgrades via APT...")
                var args = ["install", "-y", "--allow-unauthenticated"]
                args.append(contentsOf: installList)
                let success = self.coreBridge.executeAptGet(arguments: args)
                if !success { overallSuccess = false }
            }
            
            // 3. Reinstallations
            if !reinstalls.isEmpty {
                self.console.log("Executing Reinstallations via APT...")
                var args = ["install", "--reinstall", "-y", "--allow-unauthenticated"]
                args.append(contentsOf: reinstalls)
                let success = self.coreBridge.executeAptGet(arguments: args)
                if !success { overallSuccess = false }
            }
            
            DispatchQueue.main.async {
                self.console.log(overallSuccess ? "Transaction completed successfully." : "Transaction finished with errors. Check console logs.")
                completion(overallSuccess)
            }
        }
    }
}
