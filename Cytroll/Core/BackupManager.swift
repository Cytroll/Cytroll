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
    
    /// Generates a backup document containing all currently installed tweaks (Real Implementation).
    public func createBackup() -> BackupDocument {
        // نقرأ من المخزن المشترك بدل تحليل dpkg status من جديد كل مرة
        PackageIndexStore.shared.ensureLoadedBlocking()
        let installedPackages = PackageIndexStore.shared.installedPackagesSnapshot()
        
        // نستخرج فقط الـ IDs الخاصة بالحزم
        let installedIDs = installedPackages.map { $0.id }
        
        let backup = CytrollBackup(
            version: "1.0",
            packageIDs: installedIDs,
            date: Date()
        )
        return BackupDocument(backup: backup)
    }
    
    /// Parses a backup document and adds all missing tweaks to the Queue for installation.
    public func restoreFromBackup(_ backup: CytrollBackup) {
        let queueManager = QueueManager.shared
        
        // جلب الحزم المتوفرة في السورسات من المخزن المشترك (أحدث نسخة لكل حزمة)
        PackageIndexStore.shared.ensureLoadedBlocking()
        let repoDict = PackageIndexStore.shared.bestRepoByIDSnapshot()
        
        var count = 0
        for id in backup.packageIDs {
            if let realPkg = repoDict[id] {
                // الحزمة موجودة في السورسات، نضيفها للطابور
                queueManager.addOrUpdate(package: realPkg, action: .install)
                count += 1
            } else {
                // الحزمة غير موجودة في السورسات (مجهولة)، نقوم بإنشاء هيكل مبدئي لها
                let fallbackPkg = Package(
                    id: id, 
                    name: id, 
                    version: "Latest", 
                    author: "Unknown (Missing Source)", 
                    architecture: "iphoneos-arm64", 
                    description: "Restored from Backup but source is missing.",
                    isInstalled: false,
                    isBroken: false,
                    action: .install
                )
                queueManager.addOrUpdate(package: fallbackPkg, action: .install)
                count += 1
            }
        }
        
        ConsoleManager.shared.log("Restored \(count) tweaks to the Queue.")
    }
}
