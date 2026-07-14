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
    
    /// Execute the entire queue by handing it off to the TransactionManager
    public func confirmAndExecute(completion: @escaping (Bool) -> Void) {
        guard !queue.isEmpty, !isProcessing else { return }
        
        isProcessing = true
        console.clear() // Clear logs from previous runs
        
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
