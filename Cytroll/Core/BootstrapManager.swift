import Foundation
import Combine
import UIKit
import CryptoKit

public final class BootstrapManager: NSObject, ObservableObject {
    public static let shared = BootstrapManager()

    /// `/var/jb` is the shared rootless prefix (also used by Dopamine and
    /// other modern jailbreaks). `health` distinguishes "no environment",
    /// "a real working one already there — just use it" and "present but
    /// missing pieces — needs repair, not a destructive reinstall".
    @Published public private(set) var health: RootlessPaths.BootstrapHealth = .missing
    @Published public private(set) var isInstalling: Bool = false
    /// True while a download-only (no extract) job is running.
    @Published public private(set) var isDownloading: Bool = false
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []
    /// Bumped whenever the on-disk cache changes so the gatekeeper CTA refreshes.
    @Published public private(set) var localArchiveRevision: Int = 0

    /// Kept for existing call sites — `true` for both `.healthy` and
    /// `.broken` (a directory is present either way); use `health` directly
    /// when the distinction matters.
    public var isBootstrapInstalled: Bool { health != .missing }

    public var isBusy: Bool { isInstalling || isDownloading }

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        checkBootstrapStatus()

        console.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLogs in
                self?.logs = newLogs
            }
            .store(in: &cancellables)
    }

    public func checkBootstrapStatus() {
        health = RootlessPaths.bootstrapHealth
    }

    // MARK: - Local archive (cache + bundled)

    public func hasLocalArchive(for version: BootstrapVersion) -> Bool {
        if FileManager.default.fileExists(atPath: cachedArchiveURL(for: version).path) {
            return true
        }
        return BootstrapConfig.bundledBootstrapURL(for: version) != nil
    }

    public func refreshLocalArchiveAvailability() {
        localArchiveRevision += 1
    }

    /// Application Support cache for a previously downloaded bootstrap tarball.
    public func cachedArchiveURL(for version: BootstrapVersion) -> URL {
        Self.bootstrapCacheDirectory().appendingPathComponent(version.fileName)
    }

    private static func bootstrapCacheDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Cytroll/Bootstrap", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolves a local archive without touching the network: persistent
    /// cache first, then any copy bundled inside the app.
    public func resolveLocalArchiveURL(for version: BootstrapVersion) -> URL? {
        let cached = cachedArchiveURL(for: version)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return BootstrapConfig.bundledBootstrapURL(for: version)
    }

    // MARK: - Public actions

    /// Downloads the bootstrap archive into the persistent cache only —
    /// does not extract or touch `/var/jb`.
    public func downloadBootstrapOnly(version: BootstrapVersion) {
        guard !isBusy else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        DispatchQueue.main.async {
            self.isDownloading = true
            self.progress = 0.0
            self.console.clear()
        }

        Task {
            await performDownloadOnly(version: version)
        }
    }

    /// Extracts from cache/bundled archive with no network. Use for fresh
    /// bootstrap when `health == .missing`.
    public func installFromLocalArchive(version: BootstrapVersion) {
        beginLocalInstall(version: version, preserveExisting: false)
    }

    /// Re-extracts over an incomplete environment from cache/bundled only.
    public func repairFromLocalArchive(version: BootstrapVersion = BootstrapVersion.forCurrentOS()) {
        beginLocalInstall(version: version, preserveExisting: true)
    }

    /// Fresh install — legacy entry that still prefers local then falls back
    /// to download+extract. Prefer the split download/install APIs for UI.
    public func setupBootstrap(version: BootstrapVersion) {
        if hasLocalArchive(for: version) {
            installFromLocalArchive(version: version)
        } else {
            beginInstallWithNetworkFallback(version: version, preserveExisting: false)
        }
    }

    public func repairBootstrap(version: BootstrapVersion = BootstrapVersion.forCurrentOS()) {
        if hasLocalArchive(for: version) {
            repairFromLocalArchive(version: version)
        } else {
            beginInstallWithNetworkFallback(version: version, preserveExisting: true)
        }
    }

    public func autoSetupBootstrap() {
        setupBootstrap(version: BootstrapVersion.forCurrentOS())
    }

    // MARK: - Download only

    private func performDownloadOnly(version: BootstrapVersion) async {
        console.log("Downloading bootstrap (\(version.displayName))...")
        DispatchQueue.main.async { self.progress = 0.05 }

        guard let entry = BootstrapConfig.manifestEntry(for: version),
              let remoteURL = URL(string: entry.url) else {
            finishDownload(success: false, reason: "No download URL in bootstrap manifest for \(version.fileName).")
            return
        }

        console.log("Fetching \(entry.url)...")
        guard let downloaded = await downloadBootstrap(
            from: remoteURL,
            fileName: version.fileName,
            expectedSHA256: entry.sha256
        ) else {
            finishDownload(success: false, reason: "Download failed for \(version.fileName).")
            return
        }

        do {
            let dest = cachedArchiveURL(for: version)
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: downloaded, to: dest)
            if downloaded.path != dest.path {
                try? fm.removeItem(at: downloaded)
            }
            console.log("Bootstrap archive saved — ready to Bootstrap.")
            DispatchQueue.main.async {
                self.progress = 1.0
                self.isDownloading = false
                self.refreshLocalArchiveAvailability()
                self.endBackgroundImmunity()
            }
        } catch {
            finishDownload(success: false, reason: "Could not save archive: \(error.localizedDescription)")
        }
    }

    private func finishDownload(success: Bool, reason: String) {
        if !success {
            console.log("DOWNLOAD ERROR: \(reason)")
        }
        DispatchQueue.main.async {
            self.isDownloading = false
            if !success { self.progress = 0.0 }
            self.refreshLocalArchiveAvailability()
            self.endBackgroundImmunity()
        }
    }

    // MARK: - Local install / repair

    private func beginLocalInstall(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
            self.console.clear()
        }

        Task {
            await installFromLocal(version: version, preserveExisting: preserveExisting)
        }
    }

    private func installFromLocal(version: BootstrapVersion, preserveExisting: Bool) async {
        console.log(preserveExisting
            ? "Repairing rootless environment (\(version.displayName)) from local archive..."
            : "Bootstrapping Procursus (\(version.displayName)) from local archive...")

        DispatchQueue.main.async { self.progress = 0.1 }

        guard let archiveURL = resolveLocalArchiveURL(for: version) else {
            failBootstrap(reason: "No local bootstrap archive for \(version.fileName). Download it first.")
            return
        }

        if archiveURL.path.contains("Application Support") || archiveURL.path.contains("Cytroll/Bootstrap") {
            console.log("Using cached \(version.fileName)")
        } else {
            console.log("Using bundled \(version.fileName)")
        }

        await extractBootstrap(from: archiveURL, version: version, preserveExisting: preserveExisting)
    }

    /// Legacy combined path: try local, else download into cache then extract.
    private func beginInstallWithNetworkFallback(version: BootstrapVersion, preserveExisting: Bool) {
        guard !isBusy else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }

        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
            self.console.clear()
        }

        Task {
            if let local = resolveLocalArchiveURL(for: version) {
                await extractBootstrap(from: local, version: version, preserveExisting: preserveExisting)
                return
            }

            console.log(preserveExisting
                ? "Repairing — downloading bootstrap first..."
                : "Starting Procursus rootless bootstrap (\(version.displayName))...")

            guard let entry = BootstrapConfig.manifestEntry(for: version),
                  let remoteURL = URL(string: entry.url),
                  let downloaded = await downloadBootstrap(
                    from: remoteURL,
                    fileName: version.fileName,
                    expectedSHA256: entry.sha256
                  ) else {
                failBootstrap(reason: "Could not obtain bootstrap archive for \(version.fileName).")
                return
            }

            // Persist for next launch.
            let dest = cachedArchiveURL(for: version)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: downloaded, to: dest)
            DispatchQueue.main.async { self.refreshLocalArchiveAvailability() }

            let archive = FileManager.default.fileExists(atPath: dest.path) ? dest : downloaded
            await extractBootstrap(from: archive, version: version, preserveExisting: preserveExisting)
        }
    }

    private func downloadBootstrap(from url: URL, fileName: String, expectedSHA256: String?) async -> URL? {
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)

            if let expected = expectedSHA256, !expected.isEmpty {
                let data = try Data(contentsOf: dest)
                let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                guard hash.lowercased() == expected.lowercased() else {
                    console.log("SHA256 mismatch for downloaded bootstrap.")
                    try? FileManager.default.removeItem(at: dest)
                    return nil
                }
            }

            DispatchQueue.main.async { self.progress = 0.2 }
            return dest
        } catch {
            console.log("Download error: \(error.localizedDescription)")
            return nil
        }
    }

    private func extractBootstrap(from archiveURL: URL, version: BootstrapVersion, preserveExisting: Bool) async {
        let fm = FileManager.default

        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archiveURL.path)

        if !preserveExisting, fm.fileExists(atPath: RootlessPaths.prefix) {
            console.log("Removing existing \(RootlessPaths.prefix)...")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", RootlessPaths.prefix])
        }

        DispatchQueue.main.async { self.progress = 0.3 }

        guard let zstdPath = BootstrapConfig.bundledToolPath("zstd"),
              let tarPath = BootstrapConfig.bundledToolPath("tar") else {
            failBootstrap(reason: "Missing zstd or tar in app Binaries/.")
            return
        }

        let tarFileName = version.fileName.replacingOccurrences(of: ".zst", with: "")
        let tempTarPath = fm.temporaryDirectory.appendingPathComponent(tarFileName).path

        console.log("Decompressing \(version.fileName)...")
        let zstdOK = coreBridge.executeCommand(executable: zstdPath, arguments: [
            "-d", archiveURL.path, "-o", tempTarPath, "-f"
        ])

        guard zstdOK, fm.fileExists(atPath: tempTarPath) else {
            failBootstrap(reason: "Failed to decompress bootstrap archive.")
            return
        }

        DispatchQueue.main.async { self.progress = 0.5 }
        console.log("Extracting Procursus tree to / (creates \(RootlessPaths.prefix))...")

        let extractOK = coreBridge.executeCommand(executable: tarPath, arguments: [
            "-xpf", tempTarPath, "-C", "/"
        ])
        try? fm.removeItem(atPath: tempTarPath)

        guard extractOK else {
            failBootstrap(reason: "Failed to extract bootstrap tar archive.")
            return
        }

        DispatchQueue.main.async { self.progress = 0.7 }

        _ = coreBridge.executeCommand(
            executable: RootlessPaths.chmod,
            arguments: ["-R", "755", RootlessPaths.prefix]
        )

        runPrepBootstrapScript()
        seedDefaultSources(version: version)

        if fm.fileExists(atPath: RootlessPaths.uicache) {
            console.log("Running uicache...")
            _ = coreBridge.executeCommand(executable: RootlessPaths.uicache, arguments: ["-a"])
        }

        // Bootstrap just laid down a fresh dpkg database and seeded sources —
        // make sure the shared package cache reflects that instead of
        // whatever (empty) state it held before the rootless env existed.
        PackageIndexStore.shared.refresh()

        DispatchQueue.main.async {
            self.progress = 1.0
            self.console.log("Bootstrap ready at \(RootlessPaths.effectivePrefix)")
            self.isInstalling = false
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
        }
    }

    private func runPrepBootstrapScript() {
        let fm = FileManager.default
        let script = RootlessPaths.prepBootstrapScript
        guard fm.fileExists(atPath: script) else { return }

        console.log("Signing and running prep_bootstrap.sh...")
        let ldidPath = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
        _ = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", script])

        if !coreBridge.executeCommand(executable: RootlessPaths.sh, arguments: [script]) {
            console.log("WARNING: prep_bootstrap.sh returned non-zero.")
        }
    }

    /// Seeds / merges essential APT sources (Procursus, ElleKit, Havoc,
    /// Chariz). Idempotent — never wipes an existing `cytroll.list`; only
    /// appends hosts that are still missing.
    private func seedDefaultSources(version: BootstrapVersion) {
        console.log("Ensuring essential APT sources (suite \(version.aptSuite))...")
        let semaphore = DispatchSemaphore(value: 0)
        RepositoryManager.shared.ensureEssentialSources {
            semaphore.signal()
        }
        // Bootstrap runs on a background queue; wait so apt update finishes
        // before we mark install complete.
        _ = semaphore.wait(timeout: .now() + 180)
    }

    private func failBootstrap(reason: String) {
        console.log("BOOTSTRAP ERROR: \(reason)")
        DispatchQueue.main.async {
            self.isInstalling = false
            self.isDownloading = false
            self.progress = 0.0
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
        }
    }

    private func endBackgroundImmunity() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
