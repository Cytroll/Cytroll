import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data Model
/// Opt out of the project's default MainActor isolation so FileDocument's
/// nonisolated encode/decode paths can use this type under Xcode 26 / Swift 6.
public nonisolated struct CytrollBackup: Codable, Sendable {
    public let version: String
    public let packageIDs: [String]
    public let date: Date
}

public struct BackupRestoreSummary: Sendable {
    public let queuedFromRepos: Int
    public let skippedMissingSource: Int

    public var totalRequested: Int { queuedFromRepos + skippedMissingSource }
}

// MARK: - File Document for SwiftUI Exporter
public struct BackupDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }

    public var backup: CytrollBackup

    public init(backup: CytrollBackup) {
        self.backup = backup
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.backup = try JSONDecoder().decode(CytrollBackup.self, from: data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(backup)
        return .init(regularFileWithContents: data)
    }
}

// MARK: - Backup Manager
public final class BackupManager {
    public static let shared = BackupManager()

    private init() {}

    /// Builds a backup document off the main thread so a cold package-index
    /// parse never freezes the Settings UI.
    public func createBackup(completion: @escaping (BackupDocument) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            PackageIndexStore.shared.ensureLoadedBlocking()
            let installedIDs = PackageIndexStore.shared.installedPackagesSnapshot().map(\.id)
            let backup = CytrollBackup(version: "1.0", packageIDs: installedIDs, date: Date())
            let document = BackupDocument(backup: backup)
            DispatchQueue.main.async { completion(document) }
        }
    }

    /// Queues only packages that still exist in a configured repo. Returns
    /// how many were queued vs skipped so the UI can tell the user the
    /// truth instead of claiming a silent apt failure is "restored".
    @discardableResult
    public func restoreFromBackup(_ backup: CytrollBackup) -> BackupRestoreSummary {
        let queueManager = QueueManager.shared
        PackageIndexStore.shared.ensureLoadedBlocking()
        let repoDict = PackageIndexStore.shared.bestRepoByIDSnapshot()

        var queued = 0
        var skipped = 0
        for id in backup.packageIDs {
            if let realPkg = repoDict[id] {
                queueManager.addOrUpdate(package: realPkg, action: .install)
                queued += 1
            } else {
                skipped += 1
                ConsoleManager.shared.log("Restore skipped \(id) — not found in any source.")
            }
        }

        ConsoleManager.shared.log("Restore queued \(queued) package(s); skipped \(skipped) missing from sources.")
        return BackupRestoreSummary(queuedFromRepos: queued, skippedMissingSource: skipped)
    }
}
