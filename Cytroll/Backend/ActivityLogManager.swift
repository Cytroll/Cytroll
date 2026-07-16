import Foundation
import Combine

/// A single real package-transaction event, replacing the Home tab's old
/// hardcoded `com.example.tweak` placeholder rows.
public struct ActivityLogEntry: Identifiable, Codable, Equatable {
    public let id: String
    public let action: String
    public let packageName: String
    public let packageID: String
    public let timestamp: Date
    public let success: Bool

    public init(action: String, packageName: String, packageID: String, success: Bool, timestamp: Date = Date()) {
        self.id = UUID().uuidString
        self.action = action
        self.packageName = packageName
        self.packageID = packageID
        self.success = success
        self.timestamp = timestamp
    }
}

/// Small JSON-backed log of real install/remove/upgrade/reinstall actions,
/// appended to by `QueueManager` right after each transaction finishes.
/// Capped at `maxEntries` so it never grows unbounded on disk.
public final class ActivityLogManager: ObservableObject {
    public static let shared = ActivityLogManager()

    @Published public private(set) var entries: [ActivityLogEntry] = []

    private let ioQueue = DispatchQueue(label: "com.cytroll.activityLog")
    private let fm = FileManager.default
    private var logFile: String { RootlessPaths.activityLogFile }
    private let maxEntries = 200

    private init() {
        load()
    }

    private func load() {
        ioQueue.sync {
            guard let data = fm.contents(atPath: logFile),
                  let decoded = try? JSONDecoder().decode([ActivityLogEntry].self, from: data) else { return }
            DispatchQueue.main.async { self.entries = decoded }
        }
    }

    private func persist(_ entries: [ActivityLogEntry]) {
        let dir = RootlessPaths.cytrollStateDir
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: logFile), options: .atomic)
    }

    /// Appends one entry (newest-first) and persists immediately. Safe to
    /// call from a background thread — the `@Published` mirror update is
    /// always dispatched to main.
    public func log(action: String, packageName: String, packageID: String, success: Bool) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            var current = self.entries
            current.insert(ActivityLogEntry(action: action, packageName: packageName, packageID: packageID, success: success), at: 0)
            if current.count > self.maxEntries {
                current = Array(current.prefix(self.maxEntries))
            }
            self.persist(current)
            DispatchQueue.main.async { self.entries = current }
        }
    }

    public func clear() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.persist([])
            DispatchQueue.main.async { self.entries = [] }
        }
    }
}
