import Foundation
import Combine

public struct AppSafeModeEntry: Codable, Equatable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let appDisplayName: String
    /// Tweak IDs that were active when Pause was taken — used by Resume.
    public var pausedTweakIDs: [String]
    public var isPaused: Bool
}

/// Per-app Safe Mode: Pause strips injections while remembering which
/// tweaks to put back; Resume rebuilds the app with that exact set.
public final class AppSafeModeManager: ObservableObject {
    public static let shared = AppSafeModeManager()

    @Published public private(set) var entries: [AppSafeModeEntry] = []
    @Published public private(set) var isProcessing = false

    private let ioQueue = DispatchQueue(label: "com.cytroll.appSafeMode")
    private let console = ConsoleManager.shared
    private let recordStore = InjectionRecordStore.shared
    private let injectionManager = AppInjectionManager.shared

    private init() { load() }

    public func isPaused(bundleID: String) -> Bool {
        entries.first(where: { $0.bundleID == bundleID })?.isPaused == true
    }

    public func entry(for bundleID: String) -> AppSafeModeEntry? {
        entries.first { $0.bundleID == bundleID }
    }

    public func pause(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isProcessing else {
            completion(.failure(SafeModeError.busy))
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.safeMode) else {
            completion(.failure(SafeModeError.busy))
            return
        }

        let records = recordStore.records(forBundleID: bundleID).filter { $0.status != .failed }
        guard !records.isEmpty else {
            CytrollOperationGate.shared.release(.safeMode)
            completion(.failure(SafeModeError.nothingToPause))
            return
        }
        if recordStore.records(forBundleID: bundleID).contains(where: { $0.status == .failed }) {
            CytrollOperationGate.shared.release(.safeMode)
            completion(.failure(SafeModeError.needsRestoreFirst))
            return
        }

        isProcessing = true
        let displayName = records.first?.appDisplayName ?? bundleID
        let tweakIDs = records.map(\.tweakID)
        console.log("Per-app Safe Mode: pausing \(displayName)...")

        injectionManager.applyDesiredTweaks(bundleID: bundleID, displayName: displayName, tweaks: [], allowCareOwner: true) { [weak self] result in
            guard let self = self else { return }
            self.isProcessing = false
            CytrollOperationGate.shared.release(.safeMode)
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                let entry = AppSafeModeEntry(
                    bundleID: bundleID,
                    appDisplayName: displayName,
                    pausedTweakIDs: tweakIDs,
                    isPaused: true
                )
                self.upsert(entry)
                self.console.log("Safe Mode ON for \(displayName).")
                completion(.success(()))
            }
        }
    }

    public func resume(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isProcessing else {
            completion(.failure(SafeModeError.busy))
            return
        }
        guard let entry = entry(for: bundleID), entry.isPaused else {
            completion(.failure(SafeModeError.notPaused))
            return
        }
        guard CytrollOperationGate.shared.tryAcquire(.safeMode) else {
            completion(.failure(SafeModeError.busy))
            return
        }

        let tweaks = entry.pausedTweakIDs.compactMap { id -> TweakInfo? in
            if let apt = TweakInjectionManager.shared.installedTweaks.first(where: { $0.id == id }) {
                return apt
            }
            return SideloadedDylibStore.shared.item(withID: id)?.asTweakInfo
        }
        guard !tweaks.isEmpty else {
            CytrollOperationGate.shared.release(.safeMode)
            completion(.failure(SafeModeError.tweaksMissing))
            return
        }

        isProcessing = true
        console.log("Per-app Safe Mode: resuming \(entry.appDisplayName)...")

        injectionManager.applyDesiredTweaks(
            bundleID: bundleID,
            displayName: entry.appDisplayName,
            tweaks: tweaks,
            allowCareOwner: true
        ) { [weak self] result in
            guard let self = self else { return }
            self.isProcessing = false
            CytrollOperationGate.shared.release(.safeMode)
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.removeEntry(bundleID: bundleID)
                self.console.log("Safe Mode OFF for \(entry.appDisplayName).")
                completion(.success(()))
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        ioQueue.sync {
            guard let data = FileManager.default.contents(atPath: RootlessPaths.appSafeModeFile),
                  let decoded = try? JSONDecoder().decode([AppSafeModeEntry].self, from: data) else {
                return
            }
            DispatchQueue.main.async { self.entries = decoded }
        }
    }

    private func persist(_ entries: [AppSafeModeEntry]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: RootlessPaths.cytrollStateDir) {
            try? fm.createDirectory(atPath: RootlessPaths.cytrollStateDir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: RootlessPaths.appSafeModeFile), options: .atomic)
    }

    private func upsert(_ entry: AppSafeModeEntry) {
        ioQueue.sync {
            var current = self.entries
            if let idx = current.firstIndex(where: { $0.bundleID == entry.bundleID }) {
                current[idx] = entry
            } else {
                current.append(entry)
            }
            self.persist(current)
            DispatchQueue.main.async { self.entries = current }
        }
    }

    private func removeEntry(bundleID: String) {
        ioQueue.sync {
            let current = self.entries.filter { $0.bundleID != bundleID }
            self.persist(current)
            DispatchQueue.main.async { self.entries = current }
        }
    }
}

public enum SafeModeError: Error, LocalizedError {
    case busy
    case nothingToPause
    case notPaused
    case tweaksMissing
    case needsRestoreFirst

    public var errorDescription: String? {
        switch self {
        case .busy: return "Another operation is already running."
        case .nothingToPause: return "No active tweaks on this app."
        case .notPaused: return "This app is not in Safe Mode."
        case .tweaksMissing: return "Paused tweaks are no longer available on disk."
        case .needsRestoreFirst: return "This app needs Restore Original before Safe Mode can pause it."
        }
    }
}
