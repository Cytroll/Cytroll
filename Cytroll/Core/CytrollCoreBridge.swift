import Foundation

public final class CytrollCoreBridge {
    public static let shared = CytrollCoreBridge()

    private let console = ConsoleManager.shared

    public init() {}

    /// Makes sure `helperPath` is executable without ever *lowering* its
    /// current permissions. Blindly forcing `0o755` here would silently
    /// strip an existing setuid bit (`0o4000`) on the one install path
    /// where it's actually meaningful — the `.deb`/`postinst` route, which
    /// runs with real dpkg-level root and can legitimately `chown root` +
    /// `chmod 4755` this file (see `packaging/debian/postinst`). The
    /// primary TrollStore `.tipa` path never has that bit set in the first
    /// place, so this is a no-op there either way.
    private func ensureHelperExecutable(at path: String, fm: FileManager) {
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let existing = attrs[.posixPermissions] as? Int {
            let hasSetuid = (existing & 0o4000) != 0
            let hasOwnerExec = (existing & 0o100) != 0
            guard !hasOwnerExec else { return } // already executable — leave setuid/group/other bits exactly as-is
            let target = hasSetuid ? 0o4755 : 0o755
            try? fm.setAttributes([.posixPermissions: target], ofItemAtPath: path)
        } else {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func resolveLaunch(
        executable: String,
        arguments: [String]
    ) -> (path: String, args: [String]) {
        let helperPath = RootlessPaths.rootHelperPath
        let fm = FileManager.default

        if fm.fileExists(atPath: helperPath) {
            ensureHelperExecutable(at: helperPath, fm: fm)
            return (helperPath, [executable] + arguments)
        }

        console.log("WARNING: cytrollhelper not found — direct execution fallback.")
        return (executable, arguments)
    }

    private func logLines(_ data: Data, prefix: String = "") {
        guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
        str.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .forEach { console.log(prefix.isEmpty ? $0 : "\(prefix)\($0)") }
    }

    /// Executes a command via cytrollhelper (TrollStore root proxy).
    ///
    /// Uses `posix_spawn` — `Foundation.Process` is macOS-only and will not
    /// compile against the iOS SDK.
    @discardableResult
    public func executeCommand(executable: String, arguments: [String]) -> Bool {
        console.log("Executing: \(executable) \(arguments.joined(separator: " "))")

        let launch = resolveLaunch(executable: executable, arguments: arguments)
        do {
            let result = try POSIXProcessRunner.run(
                executable: launch.path,
                arguments: launch.args,
                environment: RootlessEnvironment.make()
            )
            logLines(result.stdout)
            logLines(result.stderr, prefix: "ERROR: ")
            if result.exitStatus != 0 {
                console.log("Process exited with status code: \(result.exitStatus)")
                return false
            }
            return true
        } catch {
            console.log("EXCEPTION: Failed to launch \(executable): \(error.localizedDescription)")
            return false
        }
    }

    /// Like `executeCommand`, but also returns captured stdout as a string.
    /// Used for commands whose *output* matters, not just their exit code
    /// (e.g. `ldid -e <binary>` to dump entitlements XML before re-signing).
    public func executeCommandCapturingOutput(executable: String, arguments: [String]) -> (success: Bool, output: String) {
        console.log("Executing (capture): \(executable) \(arguments.joined(separator: " "))")

        let launch = resolveLaunch(executable: executable, arguments: arguments)
        do {
            let result = try POSIXProcessRunner.run(
                executable: launch.path,
                arguments: launch.args,
                environment: RootlessEnvironment.make()
            )
            logLines(result.stderr, prefix: "ERROR: ")
            let output = String(data: result.stdout, encoding: .utf8) ?? ""
            if result.exitStatus != 0 {
                console.log("Process exited with status code: \(result.exitStatus)")
                return (false, output)
            }
            return (true, output)
        } catch {
            console.log("EXCEPTION: Failed to launch \(executable): \(error.localizedDescription)")
            return (false, "")
        }
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
