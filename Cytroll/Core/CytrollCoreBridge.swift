import Foundation

public final class CytrollCoreBridge {
    public static let shared = CytrollCoreBridge()

    private let console = ConsoleManager.shared

    public init() {}

    /// Executes a command via cytrollhelper (TrollStore root proxy).
    @discardableResult
    public func executeCommand(executable: String, arguments: [String]) -> Bool {
        console.log("Executing: \(executable) \(arguments.joined(separator: " "))")

        let process = Process()
        let helperPath = RootlessPaths.rootHelperPath
        let fm = FileManager.default

        if fm.fileExists(atPath: helperPath) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath)
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [executable] + arguments
        } else {
            console.log("WARNING: cytrollhelper not found — direct execution fallback.")
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }

        process.environment = RootlessEnvironment.make()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                str.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .forEach { self?.console.log($0) }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0, let str = String(data: data, encoding: .utf8) {
                str.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .forEach { self?.console.log("ERROR: \($0)") }
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

    @discardableResult
    public func executeDpkg(arguments: [String]) -> Bool {
        executeCommand(executable: RootlessPaths.dpkg, arguments: arguments)
    }

    @discardableResult
    public func executeAptGet(arguments: [String]) -> Bool {
        executeCommand(executable: RootlessPaths.aptGet, arguments: arguments)
    }
}
