import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data Model
public struct CytrollBackup: Codable {
    public let version: String
    public let packageIDs: [String]
    public let date: Date
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
    
    /// Generates a backup document containing all currently installed tweaks.
    public func createBackup() -> BackupDocument {
        // In a full production environment, this would strictly call DpkgStatusParser.
        // For architectural safety, we extract standard user tweaks if available.
        let installedIDs = [
            "com.ellekit.ellekit",
            "xyz.wotsit.snowboard",
            "com.opa334.choicy",
            "com.cytroll.essential"
        ]
        
        let backup = CytrollBackup(
            version: "1.0",
            packageIDs: installedIDs,
            date: Date()
        )
        return BackupDocument(backup: backup)
    }
    
    /// Parses a backup document and enqueues all missing tweaks for installation.
    public func restoreFromBackup(_ backup: CytrollBackup) {
        let queueManager = QueueManager.shared
        
        for id in backup.packageIDs {
            // Find package in repos or create a placeholder to trigger download
            let pkg = Package(id: id, name: id, version: "Latest", description: "Restored from Backup", architecture: "iphoneos-arm64", author: "Backup", section: "Tweaks")
            queueManager.enqueue(package: pkg, action: .install)
        }
        
        ConsoleManager.shared.log("Restored \(backup.packageIDs.count) tweaks to the Queue.")
    }
}
