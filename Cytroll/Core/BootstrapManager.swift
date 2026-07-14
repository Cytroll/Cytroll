import Foundation
import Combine
import UIKit

public enum BootstrapVersion: String, CaseIterable, Identifiable {
    case ios15_16 = "iOS 15.0 - 16.6 (1800)"
    case ios17 = "iOS 17.0+ (1900)"
    
    public var id: String { self.rawValue }
    
    public var downloadURL: URL {
        switch self {
        case .ios15_16:
            // Placeholder URL, replace with your actual server link
            return URL(string: "https://example.com/bootstrap-1800.tar")!
        case .ios17:
            // Placeholder URL, replace with your actual server link
            return URL(string: "https://example.com/bootstrap-1900.tar")!
        }
    }
}

public final class BootstrapManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = BootstrapManager()
    
    @Published public private(set) var isBootstrapInstalled: Bool = false
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []
    
    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    private var downloadSession: URLSession!
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    private override init() {
        super.init()
        checkBootstrapStatus()
        
        // Initialize secure download session
        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Subscribe to console logs to update the local logs array for the UI dynamically
        console.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLogs in
                self?.logs = newLogs
            }
            .store(in: &cancellables)
    }
    
    public func checkBootstrapStatus() {
        let jbPath = "/var/jb"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: jbPath, isDirectory: &isDir), isDir.boolValue {
            isBootstrapInstalled = true
        } else {
            isBootstrapInstalled = false
        }
    }
    
    public func setupBootstrap(version: BootstrapVersion) {
        guard !isInstalling else { return }
        
        // 🚨 CRITICAL: Request Background Task Immunity from iOS
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            self.console.log("WARNING: iOS forced background termination!")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        }
        
        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
            self.console.clear()
        }
        
        console.log("Preparing to download Bootstrap for \(version.rawValue)...")
        
        // Start Background Download
        let task = downloadSession.downloadTask(with: version.downloadURL)
        task.resume()
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progressVal = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        // Dedicate 70% of the progress bar to downloading
        let downloadPhaseProgress = progressVal * 0.7
        
        DispatchQueue.main.async {
            self.progress = downloadPhaseProgress
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        DispatchQueue.main.async { self.progress = 0.75 }
        console.log("Download completed. Processing securely...")
        
        let tempDir = FileManager.default.temporaryDirectory
        let tarPath = tempDir.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "bootstrap.tar")
        
        do {
            if FileManager.default.fileExists(atPath: tarPath.path) {
                try FileManager.default.removeItem(at: tarPath)
            }
            try FileManager.default.moveItem(at: location, to: tarPath)
            console.log("Archive saved to temporary storage.")
            
            // Execute heavy extraction in background
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.extractAndCleanup(tarPath: tarPath.path)
            }
        } catch {
            failBootstrap(reason: "Failed to move downloaded file: \(error.localizedDescription)")
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            failBootstrap(reason: "Network Download failed: \(error.localizedDescription)")
        }
    }
    
    private func endBackgroundImmunity() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    // MARK: - Extraction Engine
    
    /// Helper to find bundled binaries
    private func getBundledBinary(name: String) -> String? {
        return Bundle.main.url(forAuxiliaryExecutable: name)?.path ?? Bundle.main.url(forResource: name, withExtension: nil)?.path
    }
    
    private func extractAndCleanup(tarPath: String) {
        console.log("Preparing rootless environment...")
        let fm = FileManager.default
        
        // 1. Ensure /var/jb is completely clean before moving
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", "/var/jb"])
        
        DispatchQueue.main.async { self.progress = 0.80 }
        console.log("Extracting bootstrap to secure temporary container...")
        
        let tempExtractPath = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap_extract").path
        do {
            if fm.fileExists(atPath: tempExtractPath) {
                try fm.removeItem(atPath: tempExtractPath)
            }
            try fm.createDirectory(atPath: tempExtractPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            failBootstrap(reason: "Failed to create temp extraction dir: \(error.localizedDescription)")
            return
        }
        
        var finalTarPath = tarPath
        
        // 2. ZSTD Decompression (if needed)
        if tarPath.hasSuffix(".zst") {
            guard let zstdPath = getBundledBinary(name: "zstd") else {
                failBootstrap(reason: "zstd binary not found in App Bundle. Cannot decompress .zst archive.")
                return
            }
            
            console.log("Decompressing ZStandard archive using bundled zstd...")
            let decompressedTarPath = tarPath.replacingOccurrences(of: ".zst", with: "")
            
            // Execute: zstd -d archive.tar.zst -o archive.tar
            let zstdSuccess = coreBridge.executeCommand(executable: zstdPath, arguments: ["-d", tarPath, "-o", decompressedTarPath])
            
            guard zstdSuccess else {
                failBootstrap(reason: "Failed to decompress .zst archive using bundled zstd.")
                return
            }
            
            finalTarPath = decompressedTarPath
            try? fm.removeItem(atPath: tarPath) // Free space
        }
        
        // 3. Tar Extraction using bundled tar
        guard let tarBinPath = getBundledBinary(name: "tar") ?? getBundledBinary(name: "gnutar") else {
            failBootstrap(reason: "tar binary not found in App Bundle. Please bundle a static tar.")
            return
        }
        
        console.log("Extracting TAR archive using bundled tar...")
        let extractSuccess = coreBridge.executeCommand(executable: tarBinPath, arguments: ["-xf", finalTarPath, "-C", tempExtractPath])
        
        guard extractSuccess else {
            failBootstrap(reason: "Tar extraction failed using bundled tar.")
            return
        }
        
        DispatchQueue.main.async { self.progress = 0.88 }
        console.log("Locating 'jb' folder within payload...")
        
        // 4. Find the 'jb' folder dynamically
        var sourceJbPath = ""
        if fm.fileExists(atPath: "\(tempExtractPath)/jb") {
            sourceJbPath = "\(tempExtractPath)/jb"
        } else if fm.fileExists(atPath: "\(tempExtractPath)/var/jb") {
            sourceJbPath = "\(tempExtractPath)/var/jb"
        } else if fm.fileExists(atPath: "\(tempExtractPath)/private/var/jb") {
            sourceJbPath = "\(tempExtractPath)/private/var/jb"
        }
        
        guard !sourceJbPath.isEmpty else {
            failBootstrap(reason: "Could not find 'jb' directory inside the downloaded archive.")
            return
        }
        
        console.log("Injecting 'jb' folder directly into system /var...")
        
        // 5. Move it directly to /var/jb
        let moveSuccess = coreBridge.executeCommand(executable: "/bin/mv", arguments: [sourceJbPath, "/var/jb"])
        
        guard moveSuccess else {
            failBootstrap(reason: "Failed to inject jb folder into /var.")
            return
        }
        
        // Clean up temp extraction folder
        try? fm.removeItem(atPath: tempExtractPath)
        
        DispatchQueue.main.async { self.progress = 0.92 }
        console.log("Bootstrap injected. Pseudo-signing prep_bootstrap.sh with ldid...")
        
        // 6. Code Sign using bundled ldid
        if let ldidPath = getBundledBinary(name: "ldid") {
            let ldidSuccess = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", "/var/jb/prep_bootstrap.sh"])
            if !ldidSuccess {
                console.log("WARNING: ldid failed to sign prep_bootstrap.sh.")
            }
        } else {
            console.log("WARNING: ldid binary not found in App Bundle. Skipping pseudo-signing.")
        }
        
        // Ensure the prep script is executable
        _ = coreBridge.executeCommand(executable: "/bin/chmod", arguments: ["755", "/var/jb/prep_bootstrap.sh"])
        
        DispatchQueue.main.async { self.progress = 0.95 }
        console.log("Executing prep_bootstrap.sh with elevated root privileges...")
        
        // 7. Run the prep script
        let scriptSuccess = coreBridge.executeCommand(executable: "/var/jb/usr/bin/sh", arguments: ["/var/jb/prep_bootstrap.sh"])
        
        if scriptSuccess {
            console.log("prep_bootstrap.sh executed successfully!")
            
            try? fm.removeItem(atPath: finalTarPath)
            
            DispatchQueue.main.async {
                self.progress = 1.0
                self.isInstalling = false
                self.isBootstrapInstalled = true
                self.checkBootstrapStatus()
                self.endBackgroundImmunity()
            }
        } else {
            try? fm.removeItem(atPath: finalTarPath)
            failBootstrap(reason: "Execution of prep_bootstrap.sh failed. Check TrollStore root entitlements.")
        }
    }
    
    private func failBootstrap(reason: String) {
        console.log("BOOTSTRAP ERROR: \(reason)")
        DispatchQueue.main.async {
            self.isInstalling = false
            self.progress = 0.0
            self.isBootstrapInstalled = false
            self.endBackgroundImmunity()
        }
    }
}
