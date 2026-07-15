import Foundation

public final class CytrollCoreBridge {
    public static let shared = CytrollCoreBridge()
    
    private let console = ConsoleManager.shared
    
    public init() {}
    
    /// Executes a system command via the embedded Root Helper to bypass AMFI restrictions.
    /// - Parameters:
    ///   - executable: The absolute path to the binary (e.g., "/usr/bin/tar", "/var/jb/usr/bin/dpkg")
    ///   - arguments: The arguments to pass to the binary
    /// - Returns: True if exit code is 0, false otherwise
    @discardableResult
    public func executeCommand(executable: String, arguments: [String]) -> Bool {
        console.log("Executing: \(executable) \(arguments.joined(separator: " "))")
        
        let process = Process()
        
        // 🚨 Root Helper Injection (Sileo/TrollStore Standard)
        // Look for the root helper binary inside the App Bundle's Binaries folder
        let helperPath = Bundle.main.bundlePath + "/Binaries/cytrollhelper"
        
        let fm = FileManager.default
        if fm.fileExists(atPath: helperPath) {
            // التأكد من إعطائها صلاحية التنفيذ (chmod +x)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
            
            process.executableURL = URL(fileURLWithPath: helperPath)
            // We pass the actual target executable and its arguments to our helper
            process.arguments = [executable] + arguments
        } else {
            // Fallback (Direct Execution) if helper is not found
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        
        // لمنع توقف الـ APT أو DPKG في انتظار تفاعل المستخدم
        var env = ProcessInfo.processInfo.environment
        env["DEBIAN_FRONTEND"] = "noninteractive"
        env["APT_LISTCHANGES_FRONTEND"] = "none"
        process.environment = env
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Asynchronously read standard output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lines.forEach { self?.console.log($0) }
            }
        }
        
        // Asynchronously read standard error
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lines.forEach { self?.console.log("ERROR: \($0)") }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            console.log("EXCEPTION: Failed to launch \(executable): \(error.localizedDescription)")
            return false
        }
        
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        
        let success = process.terminationStatus == 0
        if !success {
            console.log("Process exited with status code: \(process.terminationStatus)")
        }
        return success
    }
    
    public func executeDpkg(arguments: [String]) -> Bool {
        // dpkg path in rootless environments
        return executeCommand(executable: "/var/jb/usr/bin/dpkg", arguments: arguments)
    }
}
