import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot of every file under `sources.list.d` (and optional top-level
/// `sources.list`) so a user can restore their APT repos after a reinstall.
public nonisolated struct AptSourcesBackup: Codable, Sendable {
    public let version: String
    public let kind: String
    public let date: Date
    public let files: [AptSourcesBackupFile]

    public static let kindIdentifier = "apt-sources"

    public init(version: String = "1.0", date: Date = Date(), files: [AptSourcesBackupFile]) {
        self.version = version
        self.kind = Self.kindIdentifier
        self.date = date
        self.files = files
    }
}

public nonisolated struct AptSourcesBackupFile: Codable, Sendable {
    /// Basename only, e.g. `cytroll.list` or `sources.list` (top-level).
    public let name: String
    /// True when this is `/etc/apt/sources.list` instead of `sources.list.d/`.
    public let isTopLevel: Bool
    public let content: String

    public init(name: String, isTopLevel: Bool, content: String) {
        self.name = name
        self.isTopLevel = isTopLevel
        self.content = content
    }
}

public struct AptSourcesBackupDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }

    public var backup: AptSourcesBackup

    public init(backup: AptSourcesBackup) {
        self.backup = backup
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.backup = try decoder.decode(AptSourcesBackup.self, from: data)
        guard backup.kind == AptSourcesBackup.kindIdentifier else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        return .init(regularFileWithContents: data)
    }
}

public struct AptSourcesRestoreSummary: Sendable {
    public let writtenFiles: Int
    public let skippedInvalid: Int
}

public final class AptSourcesBackupManager {
    public static let shared = AptSourcesBackupManager()

    private init() {}

    private var sourcesDir: String { RootlessPaths.sourcesListDir }
    private var topLevelSources: String { RootlessPaths.jb("etc", "apt", "sources.list") }

    public func createBackup(completion: @escaping (AptSourcesBackupDocument) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let files = self.collectSourceFiles()
            let backup = AptSourcesBackup(files: files)
            let document = AptSourcesBackupDocument(backup: backup)
            DispatchQueue.main.async { completion(document) }
        }
    }

    /// Writes backup files into the APT sources directories (safe basenames only),
    /// then refreshes APT indices. Does not delete unrelated `.list` files
    /// that were not in the backup.
    @discardableResult
    public func restore(_ backup: AptSourcesBackup, runAptUpdate: Bool = true) -> AptSourcesRestoreSummary {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sourcesDir) {
            try? fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)
        }

        var written = 0
        var skipped = 0

        for file in backup.files {
            guard let safeName = Self.sanitizeFileName(file.name) else {
                skipped += 1
                ConsoleManager.shared.log("APT sources restore skipped invalid name: \(file.name)")
                continue
            }

            let dest: String
            if file.isTopLevel || safeName == "sources.list" {
                dest = topLevelSources
            } else {
                dest = sourcesDir + "/" + safeName
            }

            do {
                try file.content.write(toFile: dest, atomically: true, encoding: .utf8)
                written += 1
                ConsoleManager.shared.log("Restored APT source file: \(safeName)")
            } catch {
                skipped += 1
                ConsoleManager.shared.log("Failed to write \(safeName): \(error.localizedDescription)")
            }
        }

        if runAptUpdate && written > 0 {
            ConsoleManager.shared.log("APT sources restored (\(written) file(s)). Updating APT…")
            _ = CytrollCoreBridge.shared.executeAptGet(arguments: ["update", "--allow-insecure-repositories"])
            PackageIndexStore.shared.refresh {
                RepositoryManager.shared.loadSources()
            }
        } else {
            RepositoryManager.shared.loadSources()
        }

        return AptSourcesRestoreSummary(writtenFiles: written, skippedInvalid: skipped)
    }

    private func collectSourceFiles() -> [AptSourcesBackupFile] {
        let fm = FileManager.default
        var result: [AptSourcesBackupFile] = []

        if let content = try? String(contentsOfFile: topLevelSources, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(AptSourcesBackupFile(name: "sources.list", isTopLevel: true, content: content))
        }

        guard let names = try? fm.contentsOfDirectory(atPath: sourcesDir) else {
            return result
        }

        for name in names.sorted() {
            guard name.hasSuffix(".list") || name.hasSuffix(".sources") else { continue }
            guard Self.sanitizeFileName(name) != nil else { continue }
            let path = sourcesDir + "/" + name
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            result.append(AptSourcesBackupFile(name: name, isTopLevel: false, content: content))
        }

        return result
    }

    /// Only allow simple APT source basenames — no path separators.
    private static func sanitizeFileName(_ name: String) -> String? {
        let base = (name as NSString).lastPathComponent
        guard !base.isEmpty, base != ".", base != ".." else { return nil }
        guard !base.contains("/") && !base.contains("\\") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard base.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard base.hasSuffix(".list") || base.hasSuffix(".sources") || base == "sources.list" else { return nil }
        return base
    }
}
