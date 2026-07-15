import Foundation
import Combine
import UIKit

public enum BootstrapVersion: String, CaseIterable, Identifiable {
    case ios15_16 = "iOS 15.0 - 16.6 (1800)"
    case ios17 = "iOS 17.0+ (1900)"
    
    public var id: String { self.rawValue }
    
    public var fileName: String {
        switch self {
        case .ios15_16:
            return "bootstrap_1800.tar.zst"
        case .ios17:
            return "bootstrap_1900.tar.zst"
        }
    }
}

public final class BootstrapManager: NSObject, ObservableObject {
    public static let shared = BootstrapManager()
    
    @Published public private(set) var isBootstrapInstalled: Bool = false
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []
    
    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    private override init() {
        super.init()
        checkBootstrapStatus()
        
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
        
        let fileName = version.fileName
        console.log("Preparing to install Bundled Bootstrap: \(fileName)...")
        
        // Execute extraction in background Task
        Task {
            await extractBundledBootstrap(fileName: fileName)
        }
    }
    
    private func extractBundledBootstrap(fileName: String) async {
        let fm = FileManager.default
        
        // 1. Locate the .tar.zst file in Binaries folder
        guard let bootstrapZstURL = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Binaries") ?? Bundle.main.url(forResource: fileName, withExtension: nil) else {
            failBootstrap(reason: "Could not find \(fileName) in Binaries folder. Please make sure it is added to the Xcode project.")
            return
        }
        
        // الحماية والأمان: التأكد من صلاحية القراءة فقط للملف المضغوط (Read-only)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bootstrapZstURL.path)
        
        DispatchQueue.main.async { self.progress = 0.2 }
        
        // 2. Ensure /var/jb is clean before installing
        if fm.fileExists(atPath: "/var/jb") {
            console.log("Removing existing /var/jb directory...")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", "/var/jb"])
        }
        
        DispatchQueue.main.async { self.progress = 0.3 }
        
        // تجهيز المسارات والأدوات
        guard let zstdPath = getBundledTool(name: "zstd"),
              let tarPath = getBundledTool(name: "tar") else {
            failBootstrap(reason: "Missing zstd or tar in Binaries folder.")
            return
        }
        
        let tarFileName = fileName.replacingOccurrences(of: ".zst", with: "")
        let tempTarPath = fm.temporaryDirectory.appendingPathComponent(tarFileName).path
        
        // 3. Decompress ZST to TAR باستخدام zstd المدمج
        console.log("Decompressing \(fileName) using bundled zstd...")
        let zstdSuccess = coreBridge.executeCommand(executable: zstdPath, arguments: [
            "-d", bootstrapZstURL.path,
            "-o", tempTarPath,
            "-f" // Force overwrite
        ])
        
        guard zstdSuccess, fm.fileExists(atPath: tempTarPath) else {
            failBootstrap(reason: "Failed to decompress ZST archive.")
            return
        }
        
        DispatchQueue.main.async { self.progress = 0.5 }
        console.log("Extracting Tar archive to system root (/)....")
        
        // 4. Extract the TAR archive باستخدام tar المدمج
        let extractSuccess = coreBridge.executeCommand(executable: tarPath, arguments: [
            "-xpf", tempTarPath,
            "-C", "/"
        ])
        
        // تنظيف الذاكرة: حذف الملف الوسيط (.tar) فوراً
        try? fm.removeItem(atPath: tempTarPath)
        
        guard extractSuccess else {
            failBootstrap(reason: "Failed to extract tar archive.")
            return
        }
        
        DispatchQueue.main.async { self.progress = 0.7 }
        console.log("Setting correct permissions for /var/jb...")
        
        // 5. Set permissions using the extracted chmod
        _ = coreBridge.executeCommand(executable: "/var/jb/usr/bin/chmod", arguments: ["-R", "755", "/var/jb"])
        
        // 6. Sign prep_bootstrap.sh if it exists
        let prepScript = "/var/jb/prep_bootstrap.sh"
        if fm.fileExists(atPath: prepScript) {
            console.log("Pseudo-signing prep_bootstrap.sh with bundled ldid...")
            let ldidPath = getBundledTool(name: "ldid") ?? "/var/jb/usr/bin/ldid"
            _ = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", prepScript])
            
            console.log("Executing prep_bootstrap.sh...")
            let scriptSuccess = coreBridge.executeCommand(executable: "/var/jb/usr/bin/sh", arguments: [prepScript])
            if !scriptSuccess {
                console.log("WARNING: prep_bootstrap.sh executed with non-zero exit status.")
            }
        }
        
        // 7. Run uicache if available
        if fm.fileExists(atPath: "/var/jb/usr/bin/uicache") {
            console.log("Running uicache to refresh app icons...")
            _ = coreBridge.executeCommand(executable: "/var/jb/usr/bin/uicache", arguments: ["-a"])
        }
        
        DispatchQueue.main.async {
            self.progress = 1.0
            self.console.log("Bootstrap installation completed successfully!")
            self.isInstalling = false
            self.isBootstrapInstalled = true
            self.checkBootstrapStatus()
            self.endBackgroundImmunity()
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
    
    private func endBackgroundImmunity() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func getBundledTool(name: String) -> String? {
        let path = Bundle.main.bundlePath + "/Binaries/\(name)"
        if FileManager.default.fileExists(atPath: path) {
            // إعطاء صلاحية التنفيذ (chmod +x) للأدوات التنفيذية
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        return nil
    }
    
    /// Auto-detects iOS version and sets up the correct bootstrap
    public func autoSetupBootstrap() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let version: BootstrapVersion = (major >= 17) ? .ios17 : .ios15_16
        setupBootstrap(version: version)
    }
}
