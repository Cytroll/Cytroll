import Foundation
import Combine
import UIKit

public final class QueueManager: ObservableObject {
    public static let shared = QueueManager()
    
    @Published public private(set) var queue: [Package] = []
    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var processLogs: [String] = []
    
    private let transactionManager = TransactionManager.shared
    private let console = ConsoleManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Sync console logs to the local property for the UI overlay processing view
        console.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLogs in
                self?.processLogs = newLogs
            }
            .store(in: &cancellables)
    }
    
    /// Add or update a package in the queue safely
    public func addOrUpdate(package: Package, action: QueueAction) {
        var mutablePkg = package
        mutablePkg.action = action
        
        if let index = queue.firstIndex(where: { $0.id == package.id }) {
            queue[index] = mutablePkg
        } else {
            queue.append(mutablePkg)
        }
    }
    
    /// Remove a package from the queue safely
    public func remove(package: Package) {
        queue.removeAll { $0.id == package.id }
    }
    
    /// Execute the entire queue by handing it off to the TransactionManager.
    /// Runs a dependency/conflict pre-flight check first — hard conflicts
    /// abort before dpkg/apt is ever touched.
    public func confirmAndExecute(completion: @escaping (Bool) -> Void) {
        guard !queue.isEmpty, !isProcessing else { return }
        
        isProcessing = true
        console.clear() // Clear logs from previous runs

        let issues = DependencyResolver.shared.resolve(queue: queue)
        let blockingIssues = issues.filter { $0.isBlocking }

        if !blockingIssues.isEmpty {
            console.log("Transaction blocked — resolve these conflicts first:")
            for issue in blockingIssues {
                console.log("CONFLICT: \(issue.message)")
            }
            isProcessing = false
            completion(false)
            return
        }

        for issue in issues where !issue.isBlocking {
            console.log("NOTICE: \(issue.message)")
        }
        
        // 🚨 CRITICAL: Request Background Task Immunity from iOS
        // This ensures iOS doesn't kill the app if the user goes to the Home Screen,
        // preventing catastrophic dpkg database corruption.
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            // This closure is called if time expires (rare, iOS gives ~3 mins).
            self.console.log("WARNING: iOS forced background termination! Database state unknown.")
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        
        transactionManager.executeTransaction(queue: queue) { [weak self] success in
            guard let self = self else { return }

            // dpkg status just changed on disk (installs/removes/upgrades) —
            // invalidate the shared cache so Packages/Changes/Sources reflect
            // reality on next read instead of the pre-transaction snapshot.
            PackageIndexStore.shared.refresh()

            // A removed/purged tweak package deletes its .dylib/.plist from
            // disk; refreshing here lets TweakInjectionManager notice it's
            // gone and auto-restore any app it was injected into.
            if success {
                TweakInjectionManager.shared.refreshTweaks()
            }

            // Delay clearing the UI state so the user can see the final status
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if success {
                    self.queue.removeAll()
                }
                self.isProcessing = false
                completion(success)
                
                // End immunity after everything is safely completed
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
    }
}
