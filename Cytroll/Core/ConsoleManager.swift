import Foundation
import Combine

public final class ConsoleManager: ObservableObject {
    public static let shared = ConsoleManager()
    
    @Published public private(set) var logs: [String] = []
    
    // Serial queue to ensure thread-safe log appending
    private let queue = DispatchQueue(label: "com.cytroll.console", qos: .userInteractive)
    
    private init() {}
    
    public func log(_ message: String) {
        queue.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let formattedMessage = "[\(timestamp)] \(message)"
            
            DispatchQueue.main.async {
                self.logs.append(formattedMessage)
                // Keep the log size manageable to prevent memory bloat
                if self.logs.count > 1000 {
                    self.logs.removeFirst(100)
                }
            }
        }
    }
    
    public func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}
